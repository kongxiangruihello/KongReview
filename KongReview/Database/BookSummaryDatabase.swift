import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.1：精简提要——读完的书，一句话加一栏正文；读完后 1 个月、半年、一年回来问“一句话还成立吗”
//
// 提要挂在出处上（book_summary，一本书一份）。标为读完后排第一次重温（读完后 30 天），
// 之后 182 天、365 天各一次，三次之后不再来。重温记在 revisit_log（kind = 'book'），每天至多 1 本（设置可改）。
// 读完记为小胜（同一本只记一次）。

struct BookSummary: Equatable, Sendable {
    var sourceId: Int64
    var oneLine = ""
    var body = ""
    var finishedAt: Date?
    var createdAt = Date()
    var updatedAt = Date()
    /// 已重温到第几次（0–3）；3 表示三次都过了
    var stage = 0
    var dueDay: String?
    var lastReviewedAt: Date?
    var isEmpty: Bool {
        oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Markdown.plainText(fromHTML: body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 今天要重温的一本书
struct RevisitBookItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var author: String
    var oneLine: String
    var body: String
    var finishedAt: Date
    var stage: Int
    var highlightCount: Int
}

/// 某一期读完的书（复盘、年度导出）
struct FinishedBook: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var author: String
    var oneLine: String
    var finishedAt: Date
}

extension AppDatabase {
    /// 读完后第几天重温：1 个月、半年、一年
    static let bookRevisitDays = [30, 182, 365]

    // MARK: 迁移

    /// v22：精简提要
    static func installBookSummary(in db: Database) throws {
        try db.create(table: "book_summary") { t in
            t.primaryKey("sourceId", .integer).references("source", onDelete: .cascade)
            t.column("oneLine", .text).notNull().defaults(to: "")
            t.column("body", .text).notNull().defaults(to: "")
            t.column("finishedAt", .datetime)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("stage", .integer).notNull().defaults(to: 0)
            t.column("dueDay", .text)
            t.column("lastReviewedAt", .datetime)
        }
        try db.create(index: "book_summary_due", on: "book_summary", columns: ["dueDay"])
    }

    // MARK: 读写

    func bookSummary(sourceId: Int64) throws -> BookSummary? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM book_summary WHERE sourceId = ?", arguments: [sourceId]).map(Self.summary)
        }
    }

    private static func summary(_ row: Row) -> BookSummary {
        BookSummary(sourceId: row["sourceId"], oneLine: row["oneLine"], body: row["body"], finishedAt: row["finishedAt"],
                    createdAt: row["createdAt"], updatedAt: row["updatedAt"], stage: row["stage"], dueDay: row["dueDay"],
                    lastReviewedAt: row["lastReviewedAt"])
    }

    /// 保存提要；finishedAt 由 nil 变为某日（标为读完）时排第一次重温、记一件小胜；改读完日期时按新日期重排；取消读完则不再重温
    func saveBookSummary(sourceId: Int64, oneLine: String, body: String, finishedAt: Date?, now: Date = Date()) throws {
        try writer.write { db in
            let old = try Row.fetchOne(db, sql: "SELECT * FROM book_summary WHERE sourceId = ?", arguments: [sourceId]).map(Self.summary)
            let line = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
            var stage = old?.stage ?? 0
            var due = old?.dueDay
            let oldDay = old?.finishedAt.map { Self.revisitDay($0) }
            let newDay = finishedAt.map { Self.revisitDay($0) }
            if oldDay != newDay {
                if let finishedAt {
                    stage = 0
                    due = Self.revisitDay(finishedAt, plus: Self.bookRevisitDays[0])
                } else {
                    stage = 0; due = nil
                }
            }
            try db.execute(sql: """
                INSERT INTO book_summary(sourceId, oneLine, body, finishedAt, createdAt, updatedAt, stage, dueDay) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceId) DO UPDATE SET oneLine = excluded.oneLine, body = excluded.body, finishedAt = excluded.finishedAt,
                    updatedAt = excluded.updatedAt, stage = excluded.stage, dueDay = excluded.dueDay
                """, arguments: [sourceId, line, body, finishedAt, now, now, stage, due])
            if old?.finishedAt == nil, finishedAt != nil {
                let title = try String.fetchOne(db, sql: "SELECT title FROM source WHERE id = ?", arguments: [sourceId]) ?? ""
                try Self.recordProgress(db, .bookFinished, recordId: sourceId, detail: title, now: now, once: true)
            }
        }
    }

    /// 今天到期的书
    static func dueBooks(_ db: Database, today: String, limit: Int) throws -> [RevisitBookItem] {
        guard limit > 0 else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT b.*, s.title, s.author,
                   (SELECT COUNT(*) FROM highlight h WHERE h.sourceId = s.id AND h.deletedAt IS NULL) AS hc
            FROM book_summary b JOIN source s ON s.id = b.sourceId
            WHERE b.finishedAt IS NOT NULL AND b.stage < 3 AND b.dueDay IS NOT NULL AND b.dueDay <= ?
            ORDER BY b.dueDay, b.sourceId LIMIT ?
            """, arguments: [today, limit]).map { row in
                RevisitBookItem(id: row["sourceId"], title: row["title"], author: row["author"] ?? "", oneLine: row["oneLine"], body: row["body"],
                                finishedAt: row["finishedAt"], stage: row["stage"], highlightCount: row["hc"])
            }
    }

    /// 记一次书的重温：仍然成立、要修订都算这一次重温过（排下一次，三次后不再来）；以后再说→一周后再来
    func recordBookRevisit(sourceId: Int64, outcome: RevisitOutcome, now: Date = Date()) throws {
        try writer.write { db in
            guard let b = try Row.fetchOne(db, sql: "SELECT * FROM book_summary WHERE sourceId = ?", arguments: [sourceId]).map(Self.summary),
                  let finished = b.finishedAt else { return }
            if outcome == .later {
                try db.execute(sql: "UPDATE book_summary SET dueDay = ?, lastReviewedAt = ? WHERE sourceId = ?",
                               arguments: [Self.revisitDay(now, plus: 7), now, sourceId])
            } else {
                let next = b.stage + 1
                let due: String? = next < Self.bookRevisitDays.count
                    ? max(Self.revisitDay(finished, plus: Self.bookRevisitDays[next]), Self.revisitDay(now, plus: 1)) : nil
                try db.execute(sql: "UPDATE book_summary SET stage = ?, dueDay = ?, lastReviewedAt = ? WHERE sourceId = ?",
                               arguments: [next, due, now, sourceId])
            }
            try db.execute(sql: "INSERT INTO revisit_log(kind, recordId, outcome, at) VALUES ('book', ?, ?, ?)", arguments: [sourceId, outcome.rawValue, now])
        }
    }

    /// 某一期读完的书（读完日期在期内）
    func finishedBooks(start: Date, end: Date) throws -> [FinishedBook] {
        try writer.read { db in
            guard try db.tableExists("book_summary") else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT b.sourceId, b.oneLine, b.finishedAt, s.title, s.author FROM book_summary b JOIN source s ON s.id = b.sourceId
                WHERE b.finishedAt >= ? AND b.finishedAt < ? ORDER BY b.finishedAt
                """, arguments: [start, end]).map {
                    FinishedBook(id: $0["sourceId"], title: $0["title"], author: $0["author"] ?? "", oneLine: $0["oneLine"], finishedAt: $0["finishedAt"])
                }
        }
    }
}
