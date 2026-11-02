import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.0.0：重温——札记与常念的问题按时回到眼前
//
// 札记按间隔加长回来（7、21、60、180、365 天，之后每年一次），回来时问“现在还这么看吗？”；改过的札记从头算。
// 标了「常念」且未解决的问题轮流回来，每个约每周一次，问“有新线索吗？”。
// 每天至多 2 条札记、1 个问题（设置里可改）；处理过的（含“以后再说”）占当天名额。
// 重温不写入 review_event（上周小结、回顾统计按 kind 计数，混入会改变旧数字），另记在 revisit_log。

/// 重温的结果
enum RevisitOutcome: String, Codable, Sendable {
    /// 札记：仍然这么看（间隔加长）、要修订（从头算）、以后再说（一周后再来）
    case agree, revise, later
    /// 问题：有新线索、写解答、还没有（都是一周后再来）
    case lead, answer, notyet
    /// 5.2.0 笔记：已吸收（间隔加长）、需重读（从头算，3 天后再来）、待整理（一周后再来，列入待整理）
    case absorbed, reread, organize
}

/// 每天重温的上限
struct RevisitLimits: Equatable, Sendable {
    static let notesKey = "revisit.notesPerDay"
    static let questionsKey = "revisit.questionsPerDay"
    static let booksKey = "revisit.booksPerDay"
    static let blocksKey = "revisit.blocksPerDay"
    var notes = 2
    var questions = 1
    /// 5.1：读完的书（提要）——6.0.1 起舍弃，默认 0、设置里不再提供
    var books = 0
    /// 5.2.0：专题笔记本里的段落
    var blocks = 2

    static func saved(_ defaults: UserDefaults = .standard) -> RevisitLimits {
        RevisitLimits(notes: max(0, min(10, defaults.object(forKey: notesKey) as? Int ?? 2)),
                      questions: max(0, min(5, defaults.object(forKey: questionsKey) as? Int ?? 1)),
                      books: 0,
                      blocks: max(0, min(10, defaults.object(forKey: blocksKey) as? Int ?? 2)))
    }
}

/// 今天要重温的一条札记
struct RevisitNoteItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var body: String
    var highlights: [Highlight]
    var intervalDays: Int
    var reviewCount: Int
    var lastReviewedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// “新摘录”从这一刻算起：上次重温，从未重温过则为写成之时
    var since: Date { lastReviewedAt ?? createdAt }
}

/// 今天要重温的一个常念问题
struct RevisitQuestionItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var detail: String
    var status: Question.Status
    var materialCount: Int
    var highlightIDs: Set<Int64>
    var lastReviewedAt: Date?
    var createdAt: Date
    var since: Date { lastReviewedAt ?? createdAt }
}

/// 今天的重温：剩下的札记与问题，以及今天已处理的条数
struct RevisitQueue: Equatable, Sendable {
    var notes: [RevisitNoteItem] = []
    var questions: [RevisitQuestionItem] = []
    var notesDone = 0
    var questionsDone = 0
    /// 5.1：读完的书
    var books: [RevisitBookItem] = []
    var booksDone = 0
    /// 5.2.0：笔记段落
    var blocks: [RevisitBlockItem] = []
    var blocksDone = 0
    var total: Int { notes.count + questions.count + books.count + blocks.count }
    var done: Int { notesDone + questionsDone + booksDone + blocksDone }
    var isEmpty: Bool { total == 0 }
    static let empty = RevisitQueue()
}

/// 首页、侧栏用的计数
struct RevisitCounts: Equatable, Sendable {
    var notesLeft = 0
    var questionsLeft = 0
    var done = 0
    var booksLeft = 0
    /// 5.2.0：笔记段落
    var blocksLeft = 0
    var left: Int { notesLeft + questionsLeft + booksLeft + blocksLeft }
}

/// 札记的一次修订（保存时记下改动前的一版）
struct IdeaNoteRevision: Identifiable, Equatable, Sendable {
    var id: Int64
    var noteId: Int64
    var title: String
    var body: String
    var savedAt: Date
}

extension AppDatabase {
    /// 札记重温的间隔（天）；最后一档之后每年一次
    static let noteRevisitIntervals = [7, 21, 60, 180, 365]

    static func nextNoteInterval(after current: Int) -> Int {
        noteRevisitIntervals.first { $0 > current } ?? noteRevisitIntervals.last!
    }

    /// 常念问题约每周一次
    static let questionRevisitInterval = 7

    /// 本地日期加若干天后的“yyyy-MM-dd”
    static func revisitDay(_ date: Date, plus days: Int = 0, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        return ReminderPlan.dayKey(calendar.date(byAdding: .day, value: days, to: start) ?? start)
    }

    static func dayBounds(_ date: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// 把 n 项分散在之后 1…span 天：第 i 项排在第 1 + i·span/n 天
    static func spreadOffsets(_ n: Int, span: Int) -> [Int] {
        guard n > 0 else { return [] }
        return (0..<n).map { 1 + $0 * span / n }
    }

    // MARK: 迁移

    /// v20：札记重温排程、札记修订历史、常念问题轮流、重温记录；给现有札记与常念问题排第一次重温
    static func installRevisit(in db: Database, now: Date = Date()) throws {
        try db.create(table: "idea_note_review") { t in
            t.primaryKey("noteId", .integer).references("idea_note", onDelete: .cascade)
            t.column("dueDay", .text).notNull()
            t.column("intervalDays", .integer).notNull().defaults(to: 7)
            t.column("lastReviewedAt", .datetime)
            t.column("reviewCount", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "idea_note_review_due", on: "idea_note_review", columns: ["dueDay"])
        try db.create(table: "idea_note_revision") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("noteId", .integer).notNull().references("idea_note", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("savedAt", .datetime).notNull()
            t.column("day", .text).notNull()
        }
        try db.create(index: "idea_note_revision_note", on: "idea_note_revision", columns: ["noteId", "day"])
        try db.create(table: "question_review") { t in
            t.primaryKey("questionId", .integer).references("question", onDelete: .cascade)
            t.column("dueDay", .text).notNull()
            t.column("lastReviewedAt", .datetime)
            t.column("reviewCount", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "revisit_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("outcome", .text).notNull()
            t.column("at", .datetime).notNull()
        }
        try db.create(index: "revisit_log_at", on: "revisit_log", columns: ["at"])
        try ensureRevisitSchedules(db, now: now)
    }

    /// 还没有排程的札记与常念问题补上第一次重温：
    /// 写成不满 7 天的札记在写成后第 7 天；更早的分散在之后 30 天内，免得一天涌来一批。常念问题分散在之后一周内。
    static func ensureRevisitSchedules(_ db: Database, now: Date) throws {
        let today = revisitDay(now)
        let notes = try Row.fetchAll(db, sql: """
            SELECT id, createdAt FROM idea_note WHERE id NOT IN (SELECT noteId FROM idea_note_review) ORDER BY createdAt, id
            """)
        var old: [Int64] = []
        for row in notes {
            let created: Date = row["createdAt"]
            let first = revisitDay(created, plus: 7)
            if first > today { try scheduleNote(db, id: row["id"], day: first) } else { old.append(row["id"]) }
        }
        for (id, offset) in zip(old, spreadOffsets(old.count, span: 30)) {
            try scheduleNote(db, id: id, day: revisitDay(now, plus: offset))
        }
        let questions = try Int64.fetchAll(db, sql: """
            SELECT id FROM question WHERE pinned = 1 AND id NOT IN (SELECT questionId FROM question_review) ORDER BY updatedAt DESC, id
            """)
        for (id, offset) in zip(questions, spreadOffsets(questions.count, span: questionRevisitInterval)) {
            try db.execute(sql: "INSERT INTO question_review(questionId, dueDay) VALUES (?, ?)", arguments: [id, revisitDay(now, plus: offset)])
        }
    }

    private static func scheduleNote(_ db: Database, id: Int64, day: String, interval: Int = 7) throws {
        try db.execute(sql: """
            INSERT INTO idea_note_review(noteId, dueDay, intervalDays) VALUES (?, ?, ?)
            ON CONFLICT(noteId) DO UPDATE SET dueDay = excluded.dueDay, intervalDays = excluded.intervalDays
            """, arguments: [id, day, interval])
    }

    /// 新写的札记：第一次重温在 7 天后（在 insertIdeaNote 的事务里调用）
    static func scheduleNewIdeaNote(_ db: Database, id: Int64, now: Date) throws {
        try scheduleNote(db, id: id, day: revisitDay(now, plus: 7))
    }

    /// 保存札记时：题目或正文（按纯文字比较）变了，就记下改动前的一版（同一天只留第一版；写成当天的修改不记），重温从头算
    static func noteIdeaNoteRevised(_ db: Database, before: IdeaNote, title: String, body: String, now: Date) throws {
        let changed = before.title != title || Markdown.plainText(fromHTML: before.body) != Markdown.plainText(fromHTML: body)
        guard changed, let id = before.id, try db.tableExists("idea_note_revision") else { return }
        let day = revisitDay(now)
        if revisitDay(before.createdAt) != day {
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note_revision WHERE noteId = ? AND day = ?", arguments: [id, day]) ?? 0
            if exists == 0 {
                try db.execute(sql: "INSERT INTO idea_note_revision(noteId, title, body, savedAt, day) VALUES (?, ?, ?, ?, ?)",
                               arguments: [id, before.title, before.body, now, day])
                // 5.0.2：修订记为小胜（同一天只一次，随修订历史）
                try recordProgress(db, .noteRevised, recordId: id, detail: title, now: now)
            }
        }
        try scheduleNote(db, id: id, day: revisitDay(now, plus: 7))
    }

    // MARK: 今天的重温

    /// 今天剩下的重温（先补排程）。到期早的在前；当天已处理的占名额。
    func revisitQueue(limits: RevisitLimits = .saved(), now: Date = Date()) throws -> RevisitQueue {
        try writer.write { db in
            try Self.ensureRevisitSchedules(db, now: now)
            let today = Self.revisitDay(now)
            let (start, end) = Self.dayBounds(now)
            func done(_ kind: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM revisit_log WHERE kind = ? AND at >= ? AND at < ?", arguments: [kind, start, end]) ?? 0
            }
            var q = try RevisitQueue(notesDone: done("note"), questionsDone: done("question"))
            if try db.tableExists("book_summary") {
                q.booksDone = try done("book")
                q.books = try Self.dueBooks(db, today: today, limit: max(0, limits.books - q.booksDone))
            }
            if try db.tableExists("notebook_block_review") {
                try Self.ensureBlockSchedules(db, now: now)
                q.blocksDone = try done("block")
                q.blocks = try Self.dueBlocks(db, today: today, limit: max(0, limits.blocks - q.blocksDone))
            }
            let noteRows = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.body, n.createdAt, n.updatedAt, r.intervalDays, r.reviewCount, r.lastReviewedAt
                FROM idea_note_review r JOIN idea_note n ON n.id = r.noteId AND n.deletedAt IS NULL
                WHERE r.dueDay <= ? ORDER BY r.dueDay, n.id LIMIT ?
                """, arguments: [today, max(0, limits.notes - q.notesDone)])
            q.notes = try noteRows.map { row in
                let id: Int64 = row["id"]
                let hs = try Highlight.fetchAll(db, sql: """
                    SELECT h.* FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId
                    WHERE x.noteId = ? AND h.deletedAt IS NULL ORDER BY x.position, x.addedAt
                    """, arguments: [id])
                return RevisitNoteItem(id: id, title: row["title"], body: row["body"], highlights: hs,
                                       intervalDays: row["intervalDays"], reviewCount: row["reviewCount"],
                                       lastReviewedAt: row["lastReviewedAt"], createdAt: row["createdAt"], updatedAt: row["updatedAt"])
            }
            let questionRows = try Row.fetchAll(db, sql: """
                SELECT q.id, q.title, q.detail, q.status, q.createdAt, r.lastReviewedAt
                FROM question_review r JOIN question q ON q.id = r.questionId
                WHERE q.pinned = 1 AND q.status IN ('open', 'lead') AND r.dueDay <= ? ORDER BY r.dueDay, q.id LIMIT ?
                """, arguments: [today, max(0, limits.questions - q.questionsDone)])
            q.questions = try questionRows.map { row in
                let id: Int64 = row["id"]
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question_material WHERE questionId = ?", arguments: [id]) ?? 0
                let hids = try Int64.fetchAll(db, sql: "SELECT recordId FROM question_material WHERE questionId = ? AND kind = 'highlight'", arguments: [id])
                return RevisitQuestionItem(id: id, title: row["title"], detail: row["detail"],
                                           status: Question.Status(rawValue: row["status"]) ?? .open, materialCount: count,
                                           highlightIDs: Set(hids), lastReviewedAt: row["lastReviewedAt"], createdAt: row["createdAt"])
            }
            return q
        }
    }

    func revisitCounts(limits: RevisitLimits = .saved(), now: Date = Date()) throws -> RevisitCounts {
        let q = try revisitQueue(limits: limits, now: now)
        return RevisitCounts(notesLeft: q.notes.count, questionsLeft: q.questions.count, done: q.done, booksLeft: q.books.count,
                             blocksLeft: q.blocks.count)
    }

    /// 记一次札记重温：仍然这么看→间隔加长；要修订→从头算；以后再说→一周后再来
    func recordNoteRevisit(noteId: Int64, outcome: RevisitOutcome, now: Date = Date()) throws {
        try writer.write { db in
            try Self.ensureRevisitSchedules(db, now: now)
            let current = try Int.fetchOne(db, sql: "SELECT intervalDays FROM idea_note_review WHERE noteId = ?", arguments: [noteId]) ?? 7
            let interval: Int, wait: Int
            switch outcome {
            case .agree: interval = Self.nextNoteInterval(after: current); wait = interval
            case .revise: interval = 7; wait = 7
            default: interval = current; wait = 7
            }
            try db.execute(sql: """
                UPDATE idea_note_review SET dueDay = ?, intervalDays = ?, lastReviewedAt = ?, reviewCount = reviewCount + 1 WHERE noteId = ?
                """, arguments: [Self.revisitDay(now, plus: wait), interval, now, noteId])
            try db.execute(sql: "INSERT INTO revisit_log(kind, recordId, outcome, at) VALUES ('note', ?, ?, ?)", arguments: [noteId, outcome.rawValue, now])
        }
    }

    /// 记一次问题重温（一周后再来）。有新线索时可挂上材料、在说明末尾记一句；待研究的改为“有线索”
    func recordQuestionRevisit(questionId: Int64, outcome: RevisitOutcome, highlightIDs: [Int64] = [], remark: String = "",
                               now: Date = Date()) throws {
        try writer.write { db in
            try Self.ensureRevisitSchedules(db, now: now)
            if outcome == .lead {
                var next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM question_material WHERE questionId = ?", arguments: [questionId]) ?? 0) + 1
                for h in highlightIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO question_material(questionId, kind, recordId, reason, position, addedAt) VALUES (?, 'highlight', ?, '', ?, ?)
                        """, arguments: [questionId, h, next, now])
                    if db.changesCount > 0 { next += 1 }
                }
                let line = remark.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    let p = "<p>" + Self.revisitDay(now) + "：" + Markdown.escape(line) + "</p>"
                    try db.execute(sql: "UPDATE question SET detail = detail || ? WHERE id = ?", arguments: [p, questionId])
                }
                try db.execute(sql: "UPDATE question SET status = 'lead' WHERE id = ? AND status = 'open'", arguments: [questionId])
                if db.changesCount > 0 { try Self.recordQuestionStatus(db, questionId: questionId, from: .open, to: .lead, now: now) }
                try db.execute(sql: "UPDATE question SET updatedAt = ? WHERE id = ?", arguments: [now, questionId])
            }
            try db.execute(sql: """
                INSERT INTO question_review(questionId, dueDay, lastReviewedAt, reviewCount) VALUES (?, ?, ?, 1)
                ON CONFLICT(questionId) DO UPDATE SET dueDay = excluded.dueDay, lastReviewedAt = excluded.lastReviewedAt, reviewCount = reviewCount + 1
                """, arguments: [questionId, Self.revisitDay(now, plus: Self.questionRevisitInterval), now])
            try db.execute(sql: "INSERT INTO revisit_log(kind, recordId, outcome, at) VALUES ('question', ?, ?, ?)", arguments: [questionId, outcome.rawValue, now])
        }
    }

    /// 某一刻之后新录、仍在库中的摘录（重温卡上“可能相关的新摘录”的候选）
    func highlightIDsCreated(after date: Date, limit: Int = 3_000) throws -> Set<Int64> {
        try writer.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE deletedAt IS NULL AND createdAt > ? ORDER BY createdAt DESC LIMIT ?",
                                   arguments: [date, limit]))
        }
    }

    // MARK: 修订历史与统计

    /// 一条札记的修订（旧的在前）
    func ideaNoteRevisions(noteId: Int64) throws -> [IdeaNoteRevision] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM idea_note_revision WHERE noteId = ? ORDER BY savedAt, id", arguments: [noteId]).map {
                IdeaNoteRevision(id: $0["id"], noteId: $0["noteId"], title: $0["title"], body: $0["body"], savedAt: $0["savedAt"])
            }
        }
    }

    /// 某一刻的札记是什么样：那之后第一次修订前的一版；之后没改过就是现在的样子（年度“观点的变化”用）
    func ideaNoteVersion(noteId: Int64, at date: Date) throws -> (title: String, body: String)? {
        try writer.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT title, body FROM idea_note_revision WHERE noteId = ? AND savedAt >= ? ORDER BY savedAt, id LIMIT 1",
                                          arguments: [noteId, date]) {
                return (row["title"], row["body"])
            }
            return try Row.fetchOne(db, sql: "SELECT title, body FROM idea_note WHERE id = ?", arguments: [noteId])
                .map { row -> (title: String, body: String) in (row["title"], row["body"]) }
        }
    }

    /// 本期重温过的札记（条，去重；学习小结表 1）
    func notesRevisited(start: Date, end: Date) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT recordId) FROM revisit_log WHERE kind = 'note' AND at >= ? AND at < ?", arguments: [start, end]) ?? 0
        }
    }
}
