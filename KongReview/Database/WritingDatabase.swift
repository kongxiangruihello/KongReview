import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.0：写作量
//
// 两种来源：
// 1. 自动：专题笔记本中“文字”“小标题”块与摘录块的“本文批注”是自己写的字；每次保存比较前后字数，
//    记入当天该笔记本的一行（新增、删减分开累计）。摘录块的原文是引文，不计。
// 2. 手记：在 Word 等处写的稿子，在项目页“记一笔”，填本次新写字数，或填当前全文字数由应用算出新增。
// 只呈现实际节奏，不设每日任务与连续天数。

/// 一段时间的写作量
struct WritingSummary: Equatable, Sendable {
    var added = 0
    var removed = 0
    /// 有新增的日子
    var days = 0
}

/// 一周的新增字数（项目页柱形）
struct WritingWeek: Identifiable, Equatable, Sendable {
    var start: Date
    var added: Int
    var id: Date { start }
}

/// 一条写作记录（项目页最近记录）
struct WritingEntry: Identifiable, Equatable, Sendable {
    var id: Int64
    var day: String
    var added: Int
    var removed: Int
    var manual: Bool
    var notebookTitle: String?
    var note: String
    /// 4.1：来自札记的写作
    var ideaNoteTitle: String? = nil
}

/// Word 等外部稿件最近一次登记的全文字数
struct ExternalWritingTotal: Codable, Equatable, Sendable {
    var total: Int
    var at: Date
    static func key(_ projectId: Int64) -> String { "writing.external-total.\(projectId)" }
}

/// 项目页“写作”一块
struct ProjectWriting: Equatable, Sendable {
    var weeks: [WritingWeek] = []
    /// 近 12 周新增与写作天数
    var recent = WritingSummary()
    /// 稿件现有字数：所归笔记本中自写的字＋外部稿件最近登记的全文字数
    var notebookWords = 0
    var external: ExternalWritingTotal?
    var entries: [WritingEntry] = []
    var manuscriptWords: Int { notebookWords + (external?.total ?? 0) }
}

extension AppDatabase {
    /// 一块中自己写的字：文字、小标题块的正文；摘录块只计“本文批注”
    static func ownWords(_ kind: NotebookBlock.Kind, text: String, note: String?) -> Int {
        switch kind {
        case .text, .heading: return WritingCount.count(html: text)
        case .highlight: return WritingCount.count(html: note ?? "")
        // 4.1.2：札记块的正文已在写札记时计入，不重复计
        case .note: return 0
        }
    }

    static func ownWords(_ block: NotebookBlock) -> Int { ownWords(block.kind, text: block.text, note: block.note) }

    /// 记入写作量。笔记本自动记录按“笔记本＋日期”合并为一行；手记每次一行
    static func logWriting(_ db: Database, notebookId: Int64? = nil, noteId: Int64? = nil, projectId: Int64? = nil, manual: Bool = false,
                           added: Int, removed: Int, note: String = "", now: Date = Date(), day: Date? = nil) throws {
        guard added > 0 || removed > 0 else { return }
        let key = ReminderPlan.dayKey(day ?? now)
        // 4.1：札记的写作按“札记＋日期”合并为一行（origin = note）
        let origin = manual ? "manual" : (noteId != nil ? "note" : "notebook")
        if !manual, let recordId = noteId ?? notebookId {
            let column = noteId != nil ? "noteId" : "notebookId"
            try db.execute(sql: """
                UPDATE writing_log SET added = added + ?, removed = removed + ?
                WHERE origin = ? AND \(column) = ? AND day = ?
                """, arguments: [added, removed, origin, recordId, key])
            if db.changesCount > 0 { return }
        }
        try db.execute(sql: """
            INSERT INTO writing_log(projectId, notebookId, noteId, day, added, removed, origin, note, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [projectId, notebookId, noteId, key, added, removed, origin, note, now])
    }

    /// 某个笔记本里自己写的字数
    func notebookOwnWords(_ notebookId: Int64) throws -> Int {
        try writer.read { db in try Self.notebookOwnWords(db, notebookId) }
    }

    static func notebookOwnWords(_ db: Database, _ notebookId: Int64) throws -> Int {
        try NotebookBlock.filter(Column("notebookId") == notebookId).fetchAll(db).reduce(0) { $0 + ownWords($1) }
    }

    // MARK: 手记

    /// 记一笔：本次新写的字数
    func addManualWriting(projectId: Int64, words: Int, day: Date, note: String = "", now: Date = Date()) throws {
        guard words > 0 else { return }
        try writer.write { db in
            try Self.logWriting(db, projectId: projectId, manual: true, added: words, removed: 0,
                                note: note.trimmingCharacters(in: .whitespacesAndNewlines), now: now, day: day)
            try db.execute(sql: "UPDATE research_project SET updatedAt = ? WHERE id = ?", arguments: [now, projectId])
        }
    }

    /// 登记外部稿件当前全文字数，返回算出的新增字数。第一次登记只作为起点，不计新增；之后按与上次的差计（减少时记删减）
    @discardableResult
    func recordExternalWritingTotal(projectId: Int64, total: Int, day: Date, note: String = "", now: Date = Date()) throws -> Int {
        try writer.write { db in
            let key = ExternalWritingTotal.key(projectId)
            let previous = try Self.readProgress(ExternalWritingTotal.self, key: key, in: db)
            let value = ExternalWritingTotal(total: max(0, total), at: now)
            try db.execute(sql: "INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload, updatedAt=excluded.updatedAt",
                           arguments: [key, try JSONEncoder().encode(value), now])
            guard let previous else { return 0 }
            let d = WritingCount.delta(from: previous.total, to: value.total)
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.logWriting(db, projectId: projectId, manual: true, added: d.added, removed: d.removed,
                                note: text.isEmpty ? "外部稿件全文 \(value.total) 字" : text, now: now, day: day)
            try db.execute(sql: "UPDATE research_project SET updatedAt = ? WHERE id = ?", arguments: [now, projectId])
            return d.added
        }
    }

    func deleteWritingEntry(_ id: Int64) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM writing_log WHERE id = ?", arguments: [id]) }
    }

    // MARK: 统计

    /// 日期键的闭区间：[start 当天, end 前一刻所在的那天]
    private static func dayRange(_ start: Date, _ end: Date) -> (String, String) {
        (ReminderPlan.dayKey(start), ReminderPlan.dayKey(end.addingTimeInterval(-1)))
    }

    /// 属于某个项目的写作记录：手记直接属于项目；笔记本的自动记录按笔记本当前所归的项目计
    private static let projectFilter = """
        (w.projectId = ? OR (w.origin = 'notebook' AND w.notebookId IN
            (SELECT recordId FROM research_project_link WHERE projectId = ? AND kind = 'notebook'))
         OR (w.origin = 'note' AND w.noteId IN
            (SELECT recordId FROM research_project_link WHERE projectId = ? AND kind = 'note')))
        """

    /// 全库一段时间的写作量（学习小结表 1）
    func writingSummary(start: Date, end: Date) async throws -> WritingSummary {
        try await writer.read { db in try Self.writingSummary(db, start: start, end: end, projectId: nil) }
    }

    /// 某项目一段时间的写作量（学习小结表 4）
    func projectWritingSummary(projectId: Int64, start: Date, end: Date) async throws -> WritingSummary {
        try await writer.read { db in try Self.writingSummary(db, start: start, end: end, projectId: projectId) }
    }

    private static func writingSummary(_ db: Database, start: Date, end: Date, projectId: Int64?) throws -> WritingSummary {
        let (a, b) = dayRange(start, end)
        var sql = "SELECT COALESCE(SUM(w.added),0) AS added, COALESCE(SUM(w.removed),0) AS removed, COUNT(DISTINCT CASE WHEN w.added > 0 THEN w.day END) AS days FROM writing_log w WHERE w.day >= ? AND w.day <= ?"
        var args: [any DatabaseValueConvertible] = [a, b]
        if let projectId { sql += " AND " + projectFilter; args += [projectId, projectId, projectId] }
        let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
        return WritingSummary(added: row?["added"] ?? 0, removed: row?["removed"] ?? 0, days: row?["days"] ?? 0)
    }

    /// 项目页：近 weeks 周每周新增、稿件字数、最近记录
    func projectWriting(projectId: Int64, weeks: Int = 12, now: Date = Date(), calendar: Calendar = .current) async throws -> ProjectWriting {
        try await writer.read { db in
            var out = ProjectWriting()
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            let starts = (0..<weeks).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
            guard let first = starts.first else { return out }
            let (a, b) = Self.dayRange(first, now.addingTimeInterval(1))
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.day, SUM(w.added) AS added FROM writing_log w
                WHERE w.day >= ? AND w.day <= ? AND \(Self.projectFilter) GROUP BY w.day
                """, arguments: [a, b, projectId, projectId, projectId])
            var byWeek: [Date: Int] = [:]
            var days = 0, added = 0
            let parser = DateFormatter(); parser.calendar = calendar; parser.timeZone = calendar.timeZone; parser.dateFormat = "yyyy-MM-dd"
            for row in rows {
                let n: Int = row["added"] ?? 0
                guard n > 0, let date = parser.date(from: row["day"]),
                      let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
                byWeek[week, default: 0] += n
                days += 1; added += n
            }
            out.weeks = starts.map { WritingWeek(start: $0, added: byWeek[$0] ?? 0) }
            out.recent = WritingSummary(added: added, removed: 0, days: days)
            let notebookIDs = try Int64.fetchAll(db, sql: "SELECT recordId FROM research_project_link WHERE projectId = ? AND kind = 'notebook'", arguments: [projectId])
            out.notebookWords = try notebookIDs.reduce(0) { $0 + (try Self.notebookOwnWords(db, $1)) }
            out.external = try Self.readProgress(ExternalWritingTotal.self, key: ExternalWritingTotal.key(projectId), in: db)
            out.entries = try Row.fetchAll(db, sql: """
                SELECT w.id, w.day, w.added, w.removed, w.origin, w.note, n.title AS notebookTitle, i.title AS ideaTitle FROM writing_log w
                LEFT JOIN notebook n ON n.id = w.notebookId
                LEFT JOIN idea_note i ON i.id = w.noteId
                WHERE \(Self.projectFilter) ORDER BY w.day DESC, w.id DESC LIMIT 8
                """, arguments: [projectId, projectId, projectId]).map {
                    WritingEntry(id: $0["id"], day: $0["day"], added: $0["added"], removed: $0["removed"],
                                 manual: ($0["origin"] as String?) == "manual", notebookTitle: $0["notebookTitle"], note: $0["note"] ?? "",
                                 ideaNoteTitle: $0["ideaTitle"])
                }
            return out
        }
    }
}
