import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.7：错题回炉与每天的时长
//
// 卷尾再考：今天卷面上答“忘了”的摘录题、论证题，判“需重读”的复述题，在常规的题答完后再出一次，答“记得”（复述题“记起来了”）才算过关；
// 每道至多再考两轮，仍没过的照旧两天后补考（摘录）或按各自的间隔回来。依据：连续再学习（successive relearning）——
// 每轮提取到答对为止，再隔几天重复几轮（Rawson、Dunlosky 等，2013）。卷尾再考不记入掌握度，掌握度只看第一次作答。
// 每天的时长：设了“每天约多少分钟”（0 为不限）时，当天第一次组卷按优先次序分配各类题数——
// 补考的摘录 → 到期的记忆卡 → 札记 → 笔记 → 问题 → 其余摘录；超出的顺延到明天，可以“再考 10 分钟”。

/// 卷尾再考的一道
struct ExamRelearnItem: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case highlight, note, block }
    var kind: Kind
    var id: Int64
    /// 已再考了几轮
    var rounds = 0
}

/// 今天的卷尾再考
struct ExamRelearnState: Codable, Equatable, Sendable {
    var day = ""
    var items: [ExamRelearnItem] = []
    var passed = 0
    var failed = 0
    static let maxRounds = 2

    mutating func add(_ kind: ExamRelearnItem.Kind, _ id: Int64) {
        guard !items.contains(where: { $0.kind == kind && $0.id == id }) else { return }
        items.append(ExamRelearnItem(kind: kind, id: id))
    }

    /// 再考一轮的结果：过了就移出；没过就排到队尾，满两轮也移出
    mutating func answer(_ item: ExamRelearnItem, passed ok: Bool) {
        guard let i = items.firstIndex(where: { $0.kind == item.kind && $0.id == item.id }) else { return }
        var it = items.remove(at: i)
        if ok { passed += 1; return }
        it.rounds += 1
        if it.rounds >= Self.maxRounds { failed += 1 } else { items.append(it) }
    }
}

/// 每天的时长与各类题数
struct ExamBudget: Codable, Equatable, Sendable {
    var day = ""
    var minutes = 0
    /// 各类当天至多几道（含已答）
    var caps: [String: Int] = [:]

    func cap(_ kind: ExamKind) -> Int? { caps[kind.rawValue] }

    /// 每道大约几秒
    static func seconds(_ kind: ExamKind) -> Int {
        switch kind {
        case .card: 20
        case .highlight: 30
        case .note: 60
        case .block: 60
        case .question: 120
        }
    }

    /// 按优先次序把时长分给各类：补考的摘录、记忆卡、札记、笔记、问题、其余摘录
    static func plan(minutes: Int, totals: [ExamKind: Int], retests: Int, day: String) -> ExamBudget {
        var left = minutes * 60
        var caps: [ExamKind: Int] = [:]
        func take(_ kind: ExamKind, _ n: Int) {
            guard n > 0 else { return }
            let fit = min(n, max(0, left / seconds(kind)))
            caps[kind, default: 0] += fit
            left -= fit * seconds(kind)
        }
        let highlights = totals[.highlight] ?? 0
        let r = min(retests, highlights)
        take(.highlight, r)
        for k in [ExamKind.card, .note, .block, .question] { take(k, totals[k] ?? 0) }
        take(.highlight, highlights - r)
        var out = ExamBudget(day: day, minutes: minutes)
        for k in ExamKind.allCases { out.caps[k.rawValue] = caps[k] ?? 0 }
        return out
    }
}

enum ExamSettings {
    static let minutesKey = "exam.minutesPerDay"
    /// 每天约多少分钟（0 为不限，默认不限）
    static func minutes(_ defaults: UserDefaults = .standard) -> Int {
        max(0, min(240, defaults.object(forKey: minutesKey) as? Int ?? 0))
    }
}

extension LibraryStore {
    static let examRelearnKey = "exam.relearn"
    static func examBudgetKey(_ day: String) -> String { "exam.budget." + day }

    // MARK: 卷尾再考

    var examRelearn: ExamRelearnState {
        get {
            let today = AppDatabase.revisitDay(Date())
            guard let data = UserDefaults.standard.data(forKey: Self.examRelearnKey),
                  let s = try? JSONDecoder().decode(ExamRelearnState.self, from: data), s.day == today else {
                return ExamRelearnState(day: today)
            }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.examRelearnKey) }
            dailyCheckRevision += 1
        }
    }

    /// 放进今天的卷尾再考
    func examRelearnAdd(_ kind: ExamRelearnItem.Kind, _ id: Int64) {
        var s = examRelearn
        s.add(kind, id)
        examRelearn = s
    }

    /// 卷尾再考答了一道（不记入掌握度）
    func examRelearnAnswer(_ item: ExamRelearnItem, passed: Bool) {
        var s = examRelearn
        s.answer(item, passed: passed)
        examRelearn = s
    }

    /// 卷尾再考的下一道题（摘录在今天已删去或弃置的跳过）
    func examRelearnNext(now: Date = Date()) -> (ExamRelearnItem, ExamQuestion)? {
        var s = examRelearn
        var dropped = false
        defer { if dropped { examRelearn = s } }
        while let item = s.items.first {
            switch item.kind {
            case .highlight:
                if let h = try? db.highlights(ids: [item.id]).first, h.deletedAt == nil, !h.isDiscarded {
                    return (item, .highlight(h, ExamHighlightMode.pick(for: h, day: now)))
                }
            case .note:
                if let n = try? db.revisitNoteItem(id: item.id) { return (item, .note(n)) }
            case .block:
                if let b = try? db.revisitBlockItem(id: item.id) { return (item, .block(b)) }
            }
            s.items.removeFirst()
            dropped = true
        }
        return nil
    }

    // MARK: 每天的时长

    /// 今天的分配（没设时长为 nil）；当天第一次组卷时定下，改了设置或“再考 10 分钟”时重算
    func examBudget(now: Date = Date()) -> ExamBudget? {
        let minutes = ExamSettings.minutes()
        guard minutes > 0 else { return nil }
        let day = AppDatabase.revisitDay(now)
        if let saved = try? db.progressValue(ExamBudget.self, key: Self.examBudgetKey(day)), saved.minutes >= minutes { return saved }
        let plan = ExamBudget.plan(minutes: minutes, totals: examTotals(now: now), retests: examRetestsToday(now: now), day: day)
        try? db.saveProgress(plan, key: Self.examBudgetKey(day))
        return plan
    }

    /// 今天再考 10 分钟
    func examExtendBudget(by extra: Int = 10, now: Date = Date()) {
        let day = AppDatabase.revisitDay(now)
        let current = examBudget(now: now)?.minutes ?? ExamSettings.minutes()
        guard current > 0 else { return }
        let plan = ExamBudget.plan(minutes: current + extra, totals: examTotals(now: now), retests: examRetestsToday(now: now), day: day)
        try? db.saveProgress(plan, key: Self.examBudgetKey(day))
        refreshDailyCheck()
    }

    /// 改了“每天约多少分钟”：今天重新分配
    func examResetBudget(now: Date = Date()) {
        try? db.deleteProgress(key: Self.examBudgetKey(AppDatabase.revisitDay(now)))
        refreshDailyCheck()
    }

    /// 今天各类一共多少道（已答 + 还没答，不算时长限制）
    func examTotals(now: Date = Date()) -> [ExamKind: Int] {
        var t: [ExamKind: Int] = [:]
        if let record = try? todayReviewSession(now: now) { t[.highlight] = record.regularIds.count + record.masteryIds.count }
        let rated = (try? db.cardsRatedToday(now: now)) ?? 0
        t[.card] = rated + todayCardPending.total
        let q = (try? db.revisitQueue(now: now)) ?? .empty
        t[.note] = q.notesDone + q.notes.count
        t[.block] = q.blocksDone + q.blocks.count
        t[.question] = q.questionsDone + q.questions.count
        return t
    }

    /// 今天这一组摘录里补考的条数（排在最前）
    func examRetestsToday(now: Date = Date()) -> Int {
        guard let record = try? todayReviewSession(now: now) else { return 0 }
        let retests = Set((try? db.examRetestHighlightIDs(now: now, limit: AppDatabase.examRetestPerDay)) ?? [])
        return record.regularIds.prefix { retests.contains($0) }.count
    }
}

extension AppDatabase {
    /// 今天评过分的记忆卡张数
    func cardsRatedToday(now: Date = Date()) throws -> Int {
        let (start, end) = Self.dayBounds(now)
        return try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT cardId) FROM review_event WHERE kind = 'card' AND answer IS NOT NULL AND at >= ? AND at < ?",
                             arguments: [start, end]) ?? 0
        }
    }
}

extension AppDatabase {
    /// 一条札记（卷尾再考用，不看是否到期）
    func revisitNoteItem(id: Int64) throws -> RevisitNoteItem? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT n.id, n.title, n.body, n.createdAt, n.updatedAt, r.intervalDays, r.reviewCount, r.lastReviewedAt
                FROM idea_note n LEFT JOIN idea_note_review r ON r.noteId = n.id WHERE n.id = ? AND n.deletedAt IS NULL
                """, arguments: [id]) else { return nil }
            let hs = try Highlight.fetchAll(db, sql: """
                SELECT h.* FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId
                WHERE x.noteId = ? AND h.deletedAt IS NULL ORDER BY x.position, x.addedAt
                """, arguments: [id])
            return RevisitNoteItem(id: id, title: row["title"], body: row["body"], highlights: hs,
                                   intervalDays: row["intervalDays"] ?? 0, reviewCount: row["reviewCount"] ?? 0,
                                   lastReviewedAt: row["lastReviewedAt"], createdAt: row["createdAt"], updatedAt: row["updatedAt"])
        }
    }

    /// 一段笔记（卷尾再考用，不看是否到期）
    func revisitBlockItem(id: Int64) throws -> RevisitBlockItem? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.id, b.notebookId, b.position, b.text, b.createdAt, n.title AS notebookTitle,
                       r.intervalDays, r.reviewCount, r.lastReviewedAt
                FROM notebook_block b JOIN notebook n ON n.id = b.notebookId
                LEFT JOIN notebook_block_review r ON r.blockId = b.id
                WHERE b.id = ?
                """, arguments: [id]) else { return nil }
            let text: String = row["text"]
            guard !Self.blockPlain(text).isEmpty else { return nil }
            let nid: Int64 = row["notebookId"]
            return RevisitBlockItem(id: id, notebookId: nid, notebookTitle: row["notebookTitle"],
                                    heading: try Self.headingBefore(db, notebookId: nid, position: row["position"]),
                                    text: text, intervalDays: row["intervalDays"] ?? 0, reviewCount: row["reviewCount"] ?? 0,
                                    lastReviewedAt: row["lastReviewedAt"], createdAt: row["createdAt"])
        }
    }
}
