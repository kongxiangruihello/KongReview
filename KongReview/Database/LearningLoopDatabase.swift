import Foundation
import GRDB
import KongReviewCore

// MARK: - 3.15：回顾、记忆卡与个人成长的闭环
//
// 1. 本期焦点：在学习小结里选定一个专题笔记本或出处，回顾抽样对其中的摘录加权，记忆卡优先其卡片，小结报告焦点进展。
// 2. 分工互补：已在记忆卡中熟记（间隔 ≥ 21 天）的摘录在回顾中降权；近 7 天重来 ≥ 3 次的卡片，原摘录回到回顾“重读原文”。
// 3. 按语计入成果；4. 学习质量指标；6. 札记导出所需的查询。

/// 本期焦点：一个专题笔记本或一个出处；4.0 起为“当前项目”（kind = project，范围是项目全部材料）
struct LearningFocus: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case notebook, source, project }
    var kind: Kind
    var id: Int64
    var title: String
    var startedAt = Date()

    static let progressKey = "learning.focus"
    var label: String {
        switch kind {
        case .notebook: "专题《\(title)》"
        case .source: "出处《\(title)》"
        case .project: "项目《\(title)》"
        }
    }
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
        case .project:
            return try researchProjectHighlightIDs(db, projectId: focus.id)
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
            case .project: return try String.fetchOne(db, sql: "SELECT title FROM research_project WHERE id = ? AND archivedAt IS NULL", arguments: [focus.id])
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

}
