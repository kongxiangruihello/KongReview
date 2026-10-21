import Foundation
import GRDB
import KongReviewCore

// MARK: - 3.15：回顾、记忆卡与个人成长的闭环
//
// 1. 本期焦点：在学习小结里选定一个专题笔记本或出处，回顾抽样对其中的摘录加权，记忆卡优先其卡片，小结报告焦点进展。
// 2. 分工互补：已在记忆卡中熟记（间隔 ≥ 21 天）的摘录在回顾中降权；近 7 天重来 ≥ 3 次的卡片，原摘录回到回顾“重读原文”。
// 3. 按语计入成果；4. 学习质量指标；6. 札记导出所需的查询。

/// 本期焦点：一个专题笔记本或一个出处
struct LearningFocus: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case notebook, source }
    var kind: Kind
    var id: Int64
    var title: String
    var startedAt = Date()

    static let progressKey = "learning.focus"
    var label: String { kind == .notebook ? "专题《\(title)》" : "出处《\(title)》" }
}

/// 回顾抽样的调整
struct ReviewBias: Sendable, Equatable {
    /// 摘录 id → 权重系数
    var multipliers: [Int64: Double] = [:]
    /// 需要“重读原文”的摘录：id → 近 7 天重来次数（按次数从多到少）
    var refresh: [(id: Int64, lapses: Int)] = []

    static func == (a: ReviewBias, b: ReviewBias) -> Bool {
        a.multipliers == b.multipliers && a.refresh.map(\.id) == b.refresh.map(\.id) && a.refresh.map(\.lapses) == b.refresh.map(\.lapses)
    }

    /// 焦点摘录加权倍数、熟记卡片对应摘录的降权倍数
    static let focusBoost = 3.0
    static let matureDamping = 0.3
    /// 熟记：卡片间隔 ≥ 21 天（与牌组熟练度条一致）
    static let matureDays = DeckMaturity.matureDays
    /// 重读原文：近 7 天至少 3 次重来；最近 3 天出现过的不再重复安排；每天最多 3 条
    static let refreshWindowDays = 7.0
    static let refreshMinLapses = 3
    static let refreshCooldownDays = 3.0
    static let refreshLimit = 3
}

/// 焦点进展（学习小结表 4）
struct FocusProgress: Equatable, Sendable {
    var totalHighlights = 0
    var reviewedHighlights = 0
    var newHighlights = 0
    var notes = 0
    var totalCards = 0
    var studiedCards = 0
}

/// 学习质量（学习小结表 2）
struct GrowthQuality: Equatable, Sendable {
    /// 复习卡评分中非“重来”的比例；分母为 0 时为 nil
    var retention: Double?
    var reviewRatings = 0
    /// 回顾中的收藏、弃置与写按语的摘录数，及本期回顾的摘录总数
    var favorited = 0
    var discarded = 0
    var noted = 0
    var reviewed = 0
    /// 本期回顾过、且做了收藏、弃置或写按语中至少一项的摘录（同一条只计一次）
    var curated = 0
    /// 本期新增摘录中已做成记忆卡的条数
    var newHighlights = 0
    var newHighlightsCarded = 0

    var curationRate: Double? { reviewed == 0 ? nil : Double(curated) / Double(reviewed) }
    var cardingRate: Double? { newHighlights == 0 ? nil : Double(newHighlightsCarded) / Double(newHighlights) }
}

/// 札记的一条：摘录、按语与出处
struct NotebookEntry: Equatable, Sendable {
    var highlight: Highlight
    var sourceTitle: String?
    var sourceAuthor: String?
    var favorited: Bool
    var noted: Bool
}

extension AppDatabase {
    // MARK: 焦点

    func learningFocus() throws -> LearningFocus? {
        try progressValue(LearningFocus.self, key: LearningFocus.progressKey)
    }

    func setLearningFocus(_ focus: LearningFocus?) throws {
        if let focus { try saveProgress(focus, key: LearningFocus.progressKey) }
        else { try deleteProgress(key: LearningFocus.progressKey) }
    }

    static func focusHighlightIDs(_ db: Database, _ focus: LearningFocus) throws -> Set<Int64> {
        switch focus.kind {
        case .notebook:
            return Set(try Int64.fetchAll(db, sql: """
                SELECT b.highlightId FROM notebook_block b JOIN highlight h ON h.id = b.highlightId
                WHERE b.notebookId = ? AND b.kind = 'highlight' AND h.deletedAt IS NULL
                """, arguments: [focus.id]))
        case .source:
            return Set(try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE sourceId = ? AND deletedAt IS NULL", arguments: [focus.id]))
        }
    }

    func focusHighlightIDs(_ focus: LearningFocus) throws -> Set<Int64> {
        try writer.read { db in try Self.focusHighlightIDs(db, focus) }
    }

    /// 焦点仍然存在（专题或出处未被删除）时返回最新标题
    func validatedLearningFocus() throws -> LearningFocus? {
        guard var focus = try learningFocus() else { return nil }
        let title: String? = try writer.read { db in
            switch focus.kind {
            case .notebook: return try String.fetchOne(db, sql: "SELECT title FROM notebook WHERE id = ?", arguments: [focus.id])
            case .source: return try String.fetchOne(db, sql: "SELECT title FROM source WHERE id = ?", arguments: [focus.id])
            }
        }
        guard let title else { return nil }
        focus.title = title
        return focus
    }

    // MARK: 回顾抽样的调整

    func reviewBias(now: Date = Date(), focus: LearningFocus? = nil) throws -> ReviewBias {
        try writer.read { db in
            var bias = ReviewBias()
            if let focus {
                for id in try Self.focusHighlightIDs(db, focus) { bias.multipliers[id] = ReviewBias.focusBoost }
            }
            let mature = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT highlightId FROM card
                WHERE highlightId IS NOT NULL AND deletedAt IS NULL AND isSuspended = 0
                  AND state = 'review' AND interval >= ?
                """, arguments: [ReviewBias.matureDays])
            for id in mature { bias.multipliers[id] = (bias.multipliers[id] ?? 1) * ReviewBias.matureDamping }
            let since = now.addingTimeInterval(-ReviewBias.refreshWindowDays * 86_400)
            let cooldown = now.addingTimeInterval(-ReviewBias.refreshCooldownDays * 86_400)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.highlightId AS id, COUNT(*) AS lapses
                FROM review_event e JOIN card c ON c.id = e.cardId
                JOIN highlight h ON h.id = c.highlightId
                WHERE e.kind = 'card' AND e.answer = 1 AND e.at >= ? AND e.at < ?
                  AND c.deletedAt IS NULL AND h.deletedAt IS NULL AND h.isDiscarded = 0
                  AND (h.lastSurfacedAt IS NULL OR h.lastSurfacedAt < ?)
                GROUP BY c.highlightId HAVING COUNT(*) >= ?
                ORDER BY lapses DESC, c.highlightId LIMIT ?
                """, arguments: [since, now, cooldown, ReviewBias.refreshMinLapses, ReviewBias.refreshLimit])
            bias.refresh = rows.map { (id: $0["id"], lapses: $0["lapses"]) }
            return bias
        }
    }

    /// 这些摘录做成的卡片近 7 天的重来次数（回顾卡片上的“重读原文”提示）
    func recentLapses(highlightIDs ids: [Int64], now: Date = Date()) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let since = now.addingTimeInterval(-ReviewBias.refreshWindowDays * 86_400)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.highlightId AS id, COUNT(*) AS lapses FROM review_event e JOIN card c ON c.id = e.cardId
                WHERE e.kind = 'card' AND e.answer = 1 AND e.at >= ? AND c.highlightId IN (\(marks))
                GROUP BY c.highlightId HAVING COUNT(*) >= ?
                """, arguments: StatementArguments([since] + ids + [ReviewBias.refreshMinLapses]))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], $0["lapses"]) })
        }
    }

    /// 焦点摘录做成的卡片所在牌组 → 卡片数（牌组页标记与优先）
    func focusDeckCounts(_ focus: LearningFocus) throws -> [String: Int] {
        try writer.read { db in
            let ids = try Self.focusHighlightIDs(db, focus)
            guard !ids.isEmpty else { return [:] }
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT deck, highlightId FROM card WHERE deletedAt IS NULL AND highlightId IS NOT NULL") {
                let hid: Int64 = row["highlightId"]
                if ids.contains(hid) { counts[row["deck"], default: 0] += 1 }
            }
            return counts
        }
    }

    // MARK: 焦点进展

    func focusProgress(_ focus: LearningFocus, start: Date, end: Date) async throws -> FocusProgress {
        try await writer.read { db in
            let ids = try Self.focusHighlightIDs(db, focus)
            var p = FocusProgress(totalHighlights: ids.count)
            guard !ids.isEmpty else { return p }
            let reviewed = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT highlightId FROM review_event
                WHERE at >= ? AND at < ? AND highlightId IS NOT NULL AND kind NOT IN ('card','note')
                """, arguments: [start, end]))
            p.reviewedHighlights = reviewed.intersection(ids).count
            let noted = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT highlightId FROM review_event WHERE at >= ? AND at < ? AND kind = 'note' AND highlightId IS NOT NULL
                """, arguments: [start, end]))
            p.notes = noted.intersection(ids).count
            let created = Set(try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE createdAt >= ? AND createdAt < ?", arguments: [start, end]))
            p.newHighlights = created.intersection(ids).count
            let cards = try Row.fetchAll(db, sql: "SELECT id, highlightId FROM card WHERE deletedAt IS NULL AND highlightId IS NOT NULL")
                .filter { ids.contains($0["highlightId"]) }.map { $0["id"] as Int64 }
            p.totalCards = cards.count
            if !cards.isEmpty {
                let studied = Set(try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT cardId FROM review_event WHERE kind = 'card' AND at >= ? AND at < ? AND cardId IS NOT NULL
                    """, arguments: [start, end]))
                p.studiedCards = Set(cards).intersection(studied).count
            }
            return p
        }
    }

    // MARK: 学习质量

    func growthQuality(start: Date, end: Date) async throws -> GrowthQuality {
        try await writer.read { db in
            var q = GrowthQuality()
            // 复习卡（评分前已是复习状态）的保留：非“重来”的比例；旧记录没有评分前状态的不计入
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, SUM(CASE WHEN answer > 1 THEN 1 ELSE 0 END) AS ok FROM review_event
                WHERE kind = 'card' AND cardId IS NOT NULL AND cardState = 'review' AND at >= ? AND at < ?
                """, arguments: [start, end])
            q.reviewRatings = r?["n"] ?? 0
            if q.reviewRatings > 0 { q.retention = Double(r?["ok"] ?? 0) / Double(q.reviewRatings) }
            let e = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT CASE WHEN kind NOT IN ('card','note') THEN highlightId END) AS reviewed,
                       COUNT(DISTINCT CASE WHEN kind = 'favorite' THEN highlightId END) AS fav,
                       COUNT(DISTINCT CASE WHEN kind = 'discard' THEN highlightId END) AS dis,
                       COUNT(DISTINCT CASE WHEN kind = 'note' THEN highlightId END) AS noted
                FROM review_event WHERE at >= ? AND at < ? AND highlightId IS NOT NULL
                """, arguments: [start, end])
            q.reviewed = e?["reviewed"] ?? 0
            q.favorited = e?["fav"] ?? 0
            q.discarded = e?["dis"] ?? 0
            q.noted = e?["noted"] ?? 0
            q.curated = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT highlightId) FROM review_event
                WHERE at >= ? AND at < ? AND kind IN ('favorite','discard','note') AND highlightId IN
                    (SELECT highlightId FROM review_event WHERE at >= ? AND at < ? AND kind NOT IN ('card','note') AND highlightId IS NOT NULL)
                """, arguments: [start, end, start, end]) ?? 0
            q.newHighlights = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM highlight WHERE createdAt >= ? AND createdAt < ?", arguments: [start, end]) ?? 0
            q.newHighlightsCarded = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight h WHERE h.createdAt >= ? AND h.createdAt < ?
                AND EXISTS (SELECT 1 FROM card c WHERE c.highlightId = h.id AND c.deletedAt IS NULL)
                """, arguments: [start, end]) ?? 0
            return q
        }
    }

    // MARK: 札记

    /// 本期收藏或写过按语的摘录，按出处、位置排列
    func notebookEntries(start: Date, end: Date) throws -> [NotebookEntry] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT highlightId AS id,
                       MAX(CASE WHEN kind = 'favorite' THEN 1 ELSE 0 END) AS fav,
                       MAX(CASE WHEN kind = 'note' THEN 1 ELSE 0 END) AS noted
                FROM review_event WHERE at >= ? AND at < ? AND highlightId IS NOT NULL AND kind IN ('favorite','note')
                GROUP BY highlightId
                """, arguments: [start, end])
            var flags: [Int64: (Bool, Bool)] = [:]
            for row in rows { flags[row["id"]] = ((row["fav"] as Int) == 1, (row["noted"] as Int) == 1) }
            guard !flags.isEmpty else { return [] }
            let highlights = try Highlight.filter(keys: Array(flags.keys)).filter(Column("deletedAt") == nil).fetchAll(db)
            let sources = Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).compactMap { s in s.id.map { ($0, s) } })
            return highlights.map { h in
                let s = h.sourceId.flatMap { sources[$0] }
                let f = flags[h.id ?? -1] ?? (false, false)
                return NotebookEntry(highlight: h, sourceTitle: s?.title, sourceAuthor: s?.author, favorited: f.0, noted: f.1)
            }
            .sorted { ($0.sourceTitle ?? "\u{FFFF}", $0.highlight.location ?? "", $0.highlight.id ?? 0)
                    < ($1.sourceTitle ?? "\u{FFFF}", $1.highlight.location ?? "", $1.highlight.id ?? 0) }
        }
    }
}
