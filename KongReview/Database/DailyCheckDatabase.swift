import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.2.0：今日检查与笔记重温
//
// 笔记重温：专题笔记本里自己写的“文字”块（纯文字至少 20 字）也按间隔回来，与札记重温同一机制。
// 回来时只显示笔记本、所在小标题与开头几个字，先回想这一段说了什么，再展开对照：
//   已吸收→间隔加长（7、21、60、180、365 天）；需重读→间隔从头算、3 天后再来；待整理→一周后再来，并列入“待整理”。
// 改过这一段的文字，就不再算“待整理”。重温记在 revisit_log（kind = 'block'），每天至多 2 段（设置可改）。
//
// 今日检查：把今天的回顾、记忆卡、重温、自测放在一页，各组显示“已做 / 应做”。
// “应做”取当天第一次统计时各组的待办（已做 + 未做），之后不再追加，当天新到期的不算进去；做得比应做多时按已做显示。
// 每天一行记在 daily_checkin（plan 为各组应做数与跳过的组）；日评、打卡字段在 5.2.1、5.2.2 使用。

/// 今日检查的一组
enum DailyCheckGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case review, cards, revisit, selfTest, annotate
    var id: String { rawValue }
    /// 6.0.3：今日试卷上的三组（每周自测已并入摘录题与论证题）；6.0.4 加“标注文章”
    static let exam: [DailyCheckGroup] = [.review, .cards, .revisit, .annotate]
    /// 5.2 起的四组（旧接口的默认值）
    static let legacy: [DailyCheckGroup] = [.review, .cards, .revisit, .selfTest]
    var title: String {
        switch self {
        case .review: "摘录"
        case .cards: "记忆卡"
        case .revisit: "札记 · 笔记 · 问题"
        case .selfTest: "自测"
        case .annotate: "标注文章"
        }
    }
    var unit: String {
        switch self {
        case .review: "题"
        case .cards: "题"
        case .revisit: "题"
        case .selfTest: "题"
        case .annotate: "篇"
        }
    }
    var symbol: String {
        switch self {
        case .review: "sun.max"
        case .cards: "brain"
        case .revisit: "arrow.counterclockwise.circle"
        case .selfTest: "checklist"
        case .annotate: "highlighter"
        }
    }
}

/// 某一组此刻的进度
struct DailyCheckCount: Codable, Equatable, Sendable {
    var done = 0
    var left = 0
    var total: Int { done + left }
}

/// 当天的计划：各组应做数（第一次统计时定下）与今天跳过的组
struct DailyCheckPlan: Codable, Equatable, Sendable {
    var due: [String: Int] = [:]
    var skipped: [String] = []
    /// 5.2.2：今天已有一组做完（应做为 0 的组做了任意 1 条也算）；一旦做到就不再撤销
    var groupDone: Bool?
    /// 6.3.4：今天的日课做完了（摘录、记忆卡、札记·笔记·问题各组都做完，或至少答了一道后点了“收工”）；
    /// 一旦做到就不再撤销。旧版存下的没有这一项（nil），打卡仍按 groupDone 看
    var lessonDone: Bool?
}

/// 6.3.4：打卡条件里“做了功课”怎么算
enum DailyCheckinRule: Equatable, Sendable {
    /// 5.2.2 的算法：任意一组做完
    case anyGroup
    /// 日课做完：除“标注文章”外未跳过的各组都做完，或至少答了一道题后点了“收工”。
    /// 这几组今天都没有应做、也没答题时（或都跳过了），退回任意一组做完
    case lesson(handedIn: Bool)
}

/// 今日检查页的一行
struct DailyCheckRow: Identifiable, Equatable, Sendable {
    var group: DailyCheckGroup
    var done: Int
    var due: Int
    var skipped: Bool
    var id: String { group.rawValue }
    var left: Int { max(0, due - done) }
    var isComplete: Bool { due > 0 && done >= due }
    /// 5.2.2：打卡条件里的“做完一组”：应做都做了；应做为 0 时做了任意 1 条也算。跳过的组不算。
    var countsForCheckin: Bool { !skipped && (isComplete || (due == 0 && done > 0)) }
}

/// 今天的检查
struct DailyCheckState: Equatable, Sendable {
    var day = ""
    var rows: [DailyCheckRow] = []
    /// 未跳过的各组合计（已做不超过应做）
    var done: Int { rows.filter { !$0.skipped }.reduce(0) { $0 + min($1.done, $1.due) } }
    var due: Int { rows.filter { !$0.skipped }.reduce(0) { $0 + $1.due } }
    var left: Int { max(0, due - done) }
    /// 已做 / 应做；今天没有应做的为 nil
    var completion: Double? { due > 0 ? Double(done) / Double(due) : nil }
    static let empty = DailyCheckState()
}

/// 今天要重温的一段笔记
struct RevisitBlockItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var notebookId: Int64
    var notebookTitle: String
    /// 这一段之前最近的小标题
    var heading: String?
    var text: String
    var intervalDays: Int
    var reviewCount: Int
    var lastReviewedAt: Date?
    var createdAt: Date
    /// 纯文字
    var plain: String { Markdown.plainText(fromHTML: Markdown.richHTML(text)).trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 开头几个字（提示是哪一段，不泄露要点）
    var opening: String {
        let p = plain.replacingOccurrences(of: "\n", with: " ")
        return p.count > 12 ? String(p.prefix(12)) + "……" : p
    }
}

/// 标为“待整理”的一段笔记
struct OrganizeBlockItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var notebookId: Int64
    var notebookTitle: String
    var heading: String?
    var opening: String
    var markedAt: Date?
}

/// 今日检查的设置
enum DailyCheckSettings {
    static let selfTestPerDayKey = "dailyCheck.selfTestPerDay"
    /// 每天从本周自测中带几题（0 为不带）
    static func selfTestPerDay(_ defaults: UserDefaults = .standard) -> Int {
        max(0, min(5, defaults.object(forKey: selfTestPerDayKey) as? Int ?? 2))
    }
}

extension AppDatabase {
    /// 笔记一段至少多少字才排重温
    static let blockRevisitMinimumWords = 20
    /// 需重读：几天后再来
    static let blockRereadDays = 3

    // MARK: 迁移

    /// v23：笔记重温排程、每日检查（含日评、打卡字段）、连续中断的原因
    static func installDailyCheck(in db: Database) throws {
        try db.create(table: "notebook_block_review") { t in
            t.primaryKey("blockId", .integer).references("notebook_block", onDelete: .cascade)
            t.column("dueDay", .text).notNull()
            t.column("intervalDays", .integer).notNull().defaults(to: 7)
            t.column("lastReviewedAt", .datetime)
            t.column("reviewCount", .integer).notNull().defaults(to: 0)
            t.column("needsOrganize", .boolean).notNull().defaults(to: false)
            t.column("organizeMarkedAt", .datetime)
        }
        try db.create(index: "notebook_block_review_due", on: "notebook_block_review", columns: ["dueDay"])
        try db.create(table: "daily_checkin") { t in
            t.primaryKey("day", .text)
            // checked / makeup / legacy；未打卡为 NULL（5.2.2）
            t.column("status", .text)
            t.column("selfScore", .integer)
            t.column("note", .text).notNull().defaults(to: "")
            t.column("plan", .text).notNull().defaults(to: "{}")
            t.column("doneCount", .integer).notNull().defaults(to: 0)
            t.column("dueCount", .integer).notNull().defaults(to: 0)
            t.column("masteryGood", .integer).notNull().defaults(to: 0)
            t.column("masteryMid", .integer).notNull().defaults(to: 0)
            t.column("masteryBad", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "streak_break") { t in
            t.primaryKey("day", .text)
            t.column("reason", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
    }

    // MARK: 笔记重温：排程

    /// 还没有排程、够长的“文字”块补上第一次重温：写成不满 7 天的在第 7 天；更早的分散在之后 60 天内。
    static func ensureBlockSchedules(_ db: Database, now: Date) throws {
        guard try db.tableExists("notebook_block_review") else { return }
        let today = revisitDay(now)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, text, createdAt FROM notebook_block
            WHERE kind = 'text' AND id NOT IN (SELECT blockId FROM notebook_block_review) ORDER BY createdAt, id
            """)
        var old: [Int64] = []
        for row in rows {
            let text: String = row["text"]
            guard blockLongEnough(text) else { continue }
            let created: Date = row["createdAt"]
            let first = revisitDay(created, plus: 7)
            if first > today {
                try db.execute(sql: "INSERT INTO notebook_block_review(blockId, dueDay) VALUES (?, ?)", arguments: [row["id"], first])
            } else {
                old.append(row["id"])
            }
        }
        for (id, offset) in zip(old, spreadOffsets(old.count, span: 60)) {
            try db.execute(sql: "INSERT INTO notebook_block_review(blockId, dueDay) VALUES (?, ?)", arguments: [id, revisitDay(now, plus: offset)])
        }
    }

    static func blockPlain(_ text: String) -> String {
        Markdown.plainText(fromHTML: Markdown.richHTML(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func blockLongEnough(_ text: String) -> Bool {
        WritingCount.count(text: blockPlain(text)) >= blockRevisitMinimumWords
    }

    /// 这一段之前最近的小标题
    static func headingBefore(_ db: Database, notebookId: Int64, position: Double) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT text FROM notebook_block WHERE notebookId = ? AND kind = 'heading' AND position < ?
            ORDER BY position DESC LIMIT 1
            """, arguments: [notebookId, position])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 今天到期的笔记段落（到期早的在前）；已清空的跳过
    static func dueBlocks(_ db: Database, today: String, limit: Int) throws -> [RevisitBlockItem] {
        guard limit > 0, try db.tableExists("notebook_block_review") else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT b.id, b.notebookId, b.position, b.text, b.createdAt, n.title AS notebookTitle,
                   r.intervalDays, r.reviewCount, r.lastReviewedAt
            FROM notebook_block_review r
            JOIN notebook_block b ON b.id = r.blockId AND b.kind = 'text'
            JOIN notebook n ON n.id = b.notebookId
            WHERE r.dueDay <= ? ORDER BY r.dueDay, b.id
            """, arguments: [today])
        var out: [RevisitBlockItem] = []
        for row in rows {
            let text: String = row["text"]
            guard !blockPlain(text).isEmpty else { continue }
            let nid: Int64 = row["notebookId"]
            out.append(RevisitBlockItem(id: row["id"], notebookId: nid, notebookTitle: row["notebookTitle"],
                                        heading: try headingBefore(db, notebookId: nid, position: row["position"]),
                                        text: text, intervalDays: row["intervalDays"], reviewCount: row["reviewCount"],
                                        lastReviewedAt: row["lastReviewedAt"], createdAt: row["createdAt"]))
            if out.count >= limit { break }
        }
        return out
    }

    /// 记一次笔记重温：已吸收→间隔加长；需重读→从头算、3 天后再来；待整理→一周后再来并标为待整理
    func recordBlockRevisit(blockId: Int64, outcome: RevisitOutcome, now: Date = Date()) throws {
        try writer.write { db in
            try Self.ensureBlockSchedules(db, now: now)
            let current = try Int.fetchOne(db, sql: "SELECT intervalDays FROM notebook_block_review WHERE blockId = ?", arguments: [blockId]) ?? 7
            let interval: Int, wait: Int
            switch outcome {
            case .absorbed: interval = Self.nextNoteInterval(after: current); wait = interval
            case .reread: interval = 7; wait = Self.blockRereadDays
            default: interval = current; wait = 7
            }
            let organize = outcome == .organize
            try db.execute(sql: """
                INSERT INTO notebook_block_review(blockId, dueDay, intervalDays, lastReviewedAt, reviewCount, needsOrganize, organizeMarkedAt)
                VALUES (?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(blockId) DO UPDATE SET dueDay = excluded.dueDay, intervalDays = excluded.intervalDays,
                    lastReviewedAt = excluded.lastReviewedAt, reviewCount = reviewCount + 1,
                    needsOrganize = excluded.needsOrganize,
                    organizeMarkedAt = CASE WHEN excluded.needsOrganize THEN excluded.organizeMarkedAt ELSE NULL END
                """, arguments: [blockId, Self.revisitDay(now, plus: wait), interval, now, organize, organize ? now : nil])
            try db.execute(sql: "INSERT INTO revisit_log(kind, recordId, outcome, at) VALUES ('block', ?, ?, ?)", arguments: [blockId, outcome.rawValue, now])
        }
    }

    /// 改过一段笔记的文字：不再算“待整理”（在 updateBlockText 的事务里调用）
    static func noteBlockEdited(_ db: Database, id: Int64, before: String, after: String) throws {
        guard try db.tableExists("notebook_block_review"), blockPlain(before) != blockPlain(after) else { return }
        try db.execute(sql: "UPDATE notebook_block_review SET needsOrganize = 0, organizeMarkedAt = NULL WHERE blockId = ? AND needsOrganize = 1",
                       arguments: [id])
    }

    /// 待整理的笔记段落（标得早的在前）
    func blocksToOrganize(limit: Int = 50) throws -> [OrganizeBlockItem] {
        try writer.read { db in
            guard try db.tableExists("notebook_block_review") else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT b.id, b.notebookId, b.position, b.text, n.title AS notebookTitle, r.organizeMarkedAt
                FROM notebook_block_review r
                JOIN notebook_block b ON b.id = r.blockId
                JOIN notebook n ON n.id = b.notebookId
                WHERE r.needsOrganize = 1 ORDER BY r.organizeMarkedAt, b.id LIMIT ?
                """, arguments: [limit]).map { row in
                    let nid: Int64 = row["notebookId"]
                    let p = Self.blockPlain(row["text"]).replacingOccurrences(of: "\n", with: " ")
                    return OrganizeBlockItem(id: row["id"], notebookId: nid, notebookTitle: row["notebookTitle"],
                                             heading: try Self.headingBefore(db, notebookId: nid, position: row["position"]),
                                             opening: p.count > 30 ? String(p.prefix(30)) + "……" : p,
                                             markedAt: row["organizeMarkedAt"])
                }
        }
    }

    // MARK: 自测：每天从本周题中带几题

    /// 今天的自测：已做为今天作答的本周题；未做为本周还没作答的题，至多补足每天的题数
    func selfTestToday(perDay: Int = DailyCheckSettings.selfTestPerDay(), now: Date = Date()) throws -> DailyCheckCount {
        guard perDay > 0 else { return DailyCheckCount() }
        let week = GrowthPeriod.week.window(containing: now, now: now)
        let set = try selfTestSet(week: week, now: now)
        guard !set.items.isEmpty else { return DailyCheckCount() }
        let (start, end) = Self.dayBounds(now)
        return try writer.read { db in
            let key = SelfTestSet.key(week)
            let doneToday = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_test_log WHERE setKey = ? AND at >= ? AND at < ?",
                                             arguments: [key, start, end]) ?? 0
            var answered = Set<SelfTestItem>()
            for row in try Row.fetchAll(db, sql: "SELECT kind, recordId FROM self_test_log WHERE setKey = ?", arguments: [key]) {
                if let k = SelfTestKind(rawValue: row["kind"]) { answered.insert(SelfTestItem(kind: k, recordId: row["recordId"])) }
            }
            let untested = set.items.filter { !answered.contains($0) }.count
            return DailyCheckCount(done: doneToday, left: min(max(0, perDay - doneToday), untested))
        }
    }

    // MARK: 今日检查：应做数快照

    static func dailyPlan(_ db: Database, day: String) throws -> DailyCheckPlan? {
        guard let json = try String.fetchOne(db, sql: "SELECT plan FROM daily_checkin WHERE day = ?", arguments: [day]) else { return nil }
        return (try? JSONDecoder().decode(DailyCheckPlan.self, from: Data(json.utf8))) ?? DailyCheckPlan()
    }

    private static func saveDailyPlan(_ db: Database, day: String, plan: DailyCheckPlan, done: Int, due: Int, now: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO daily_checkin(day, plan, doneCount, dueCount, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET plan = excluded.plan, doneCount = excluded.doneCount, dueCount = excluded.dueCount, updatedAt = excluded.updatedAt
            """, arguments: [day, json, done, due, now, now])
    }

    /// 合成今天的检查。`snapshot` 为真时，还没定下应做数的组以此刻的“已做 + 未做”定下；为假时只显示、不定（统计还在加载时）。
    /// 6.0.3：`groups` 为今天卷子上的各组；每周自测并入卷子后，应用只传回顾、记忆卡、重温三组
    /// resnapshot（6.0.7）：这些组的应做每次按当前数重定（设了每天考多久时，题数按分到的算）
    func dailyCheck(current: [DailyCheckGroup: DailyCheckCount], groups: [DailyCheckGroup] = DailyCheckGroup.legacy,
                    snapshot: Bool = true, resnapshot: Set<DailyCheckGroup> = [], rule: DailyCheckinRule = .anyGroup,
                    now: Date = Date()) throws -> DailyCheckState {
        try writer.write { db in
            guard try db.tableExists("daily_checkin") else { return .empty }
            let day = Self.revisitDay(now)
            let stored = try Self.dailyPlan(db, day: day)
            var plan = stored ?? DailyCheckPlan()
            var rows: [DailyCheckRow] = []
            for g in groups {
                let c = current[g] ?? DailyCheckCount()
                if plan.due[g.rawValue] == nil && snapshot { plan.due[g.rawValue] = c.total }
                // 6.0.4：标注的篇数随设置当天改（篇目当天抽定，不会因做完而变少）
                if (g == .annotate || resnapshot.contains(g)) && snapshot { plan.due[g.rawValue] = c.total }
                let due = resnapshot.contains(g) ? c.total : max(plan.due[g.rawValue] ?? c.total, c.done)
                rows.append(DailyCheckRow(group: g, done: c.done, due: due, skipped: plan.skipped.contains(g.rawValue)))
            }
            let state = DailyCheckState(day: day, rows: rows)
            if rows.contains(where: \.countsForCheckin) { plan.groupDone = true }
            if case .lesson(let handedIn) = rule, plan.lessonDone != true {
                let lesson = rows.filter { $0.group != .annotate && !$0.skipped }
                let answered = lesson.reduce(0) { $0 + $1.done }
                let due = lesson.reduce(0) { $0 + $1.due }
                if lesson.isEmpty || (due == 0 && answered == 0) {
                    plan.lessonDone = rows.contains(where: \.countsForCheckin)
                } else {
                    plan.lessonDone = answered > 0 && (handedIn || lesson.allSatisfy { $0.done >= $0.due })
                }
            }
            if stored != plan && (snapshot || stored != nil || plan.groupDone == true || plan.lessonDone == true) {
                try Self.saveDailyPlan(db, day: day, plan: plan, done: state.done, due: state.due, now: now)
            } else if stored != nil {
                try db.execute(sql: "UPDATE daily_checkin SET doneCount = ?, dueCount = ?, updatedAt = ? WHERE day = ? AND (doneCount != ? OR dueCount != ?)",
                               arguments: [state.done, state.due, now, day, state.done, state.due])
            }
            // 5.2.2：做了功课且写了日评即打卡（6.3.4：功课按日课做完算）
            try Self.evaluateCheckin(db, day: day, now: now)
            return state
        }
    }

    /// 今天跳过或恢复一组（跳过的组不计入已做 / 应做）
    func setDailyCheckGroup(_ group: DailyCheckGroup, skipped: Bool, now: Date = Date()) throws {
        try writer.write { db in
            let day = Self.revisitDay(now)
            var plan = try Self.dailyPlan(db, day: day) ?? DailyCheckPlan()
            plan.skipped.removeAll { $0 == group.rawValue }
            if skipped { plan.skipped.append(group.rawValue) }
            let row = try Row.fetchOne(db, sql: "SELECT doneCount, dueCount FROM daily_checkin WHERE day = ?", arguments: [day])
            try Self.saveDailyPlan(db, day: day, plan: plan, done: row?["doneCount"] ?? 0, due: row?["dueCount"] ?? 0, now: now)
        }
    }
}
