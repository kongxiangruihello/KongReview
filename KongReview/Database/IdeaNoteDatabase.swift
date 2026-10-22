import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.1：札记
//
// 一条札记只写一个观点，用自己的话写，题目就是这个观点本身。札记不依附任何摘录：
// 可以引用任意多条摘录（idea_note_highlight），正文里用 [[题目]] 链接其他札记（idea_note_link，保存时重建）。
// 删除先进入“已删除”，可恢复；彻底删除才去掉引用与链接。

struct IdeaNote: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var title: String
    var body: String = ""
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?

    static let databaseTableName = "idea_note"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 只要编号与题目的札记引用（链接、反向链接、回顾卡片提示）
struct IdeaNoteRef: Identifiable, Hashable, Sendable {
    var id: Int64
    var title: String
}

/// 札记列表的一行
struct IdeaNoteSummary: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var preview: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var highlightCount: Int
    var backlinkCount: Int
}

/// 札记页一次读取的内容
struct IdeaNoteDetail: Sendable {
    var note: IdeaNote
    var highlights: [Highlight] = []
    /// 正文 [[ ]] 指向的札记（按出现顺序）与尚未建立的题目
    var outgoing: [IdeaNoteRef] = []
    var unresolved: [String] = []
    /// 链接到本札记的札记
    var backlinks: [IdeaNoteRef] = []
}

enum IdeaNoteError: LocalizedError {
    case emptyTitle, missing
    var errorDescription: String? {
        switch self {
        case .emptyTitle: "请写下札记的题目——一句话的观点。"
        case .missing: "这条札记已被彻底删除。"
        }
    }
}

extension AppDatabase {
    // MARK: 迁移

    /// v17：札记、札记引用的摘录、札记之间的链接；写作量加札记来源
    static func installIdeaNotes(in db: Database) throws {
        try db.create(table: "idea_note") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull()
            t.column("body", .text).notNull().defaults(to: "")
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        try db.create(table: "idea_note_highlight") { t in
            t.column("noteId", .integer).notNull().references("idea_note", onDelete: .cascade)
            t.column("highlightId", .integer).notNull().references("highlight", onDelete: .cascade)
            t.column("position", .double).notNull()
            t.column("addedAt", .datetime).notNull()
            t.primaryKey(["noteId", "highlightId"])
        }
        try db.create(index: "idea_note_highlight_highlight", on: "idea_note_highlight", columns: ["highlightId"])
        try db.create(table: "idea_note_link") { t in
            t.column("fromId", .integer).notNull().references("idea_note", onDelete: .cascade)
            t.column("toId", .integer).notNull().references("idea_note", onDelete: .cascade)
            t.primaryKey(["fromId", "toId"])
        }
        try db.create(index: "idea_note_link_to", on: "idea_note_link", columns: ["toId"])
        try db.alter(table: "writing_log") { t in t.add(column: "noteId", .integer).references("idea_note", onDelete: .setNull) }
        try db.execute(sql: """
            CREATE TRIGGER research_project_link_note_deleted AFTER DELETE ON idea_note BEGIN
                DELETE FROM research_project_link WHERE kind = 'note' AND recordId = OLD.id;
            END;
            """)
    }

    // MARK: 链接解析

    /// 按题目找札记（归一后完全相同；有几条同名时取最近改过的）
    static func resolveIdeaNoteID(_ db: Database, title: String, excluding: Int64? = nil) throws -> Int64? {
        let key = WikiLinks.key(title)
        guard !key.isEmpty else { return nil }
        return try Row.fetchAll(db, sql: "SELECT id, title FROM idea_note WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id DESC")
            .first { (row: Row) -> Bool in
                let id: Int64 = row["id"]
                return id != excluding && WikiLinks.key(row["title"]) == key
            }?["id"]
    }

    /// 按正文重建一条札记的出链
    static func rebuildIdeaNoteLinks(_ db: Database, noteId: Int64, body: String) throws {
        try db.execute(sql: "DELETE FROM idea_note_link WHERE fromId = ?", arguments: [noteId])
        for title in WikiLinks.titles(in: body) {
            guard let to = try resolveIdeaNoteID(db, title: title), to != noteId else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO idea_note_link(fromId, toId) VALUES (?, ?)", arguments: [noteId, to])
        }
    }

    /// 题目新增或改变后，原先“未建”的链接可能已能解析：重建所有含 [[ 的札记的出链
    static func rebuildAllIdeaNoteLinks(_ db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, body FROM idea_note WHERE body LIKE '%[[%'") {
            try rebuildIdeaNoteLinks(db, noteId: row["id"], body: row["body"])
        }
    }

    // MARK: 写入

    @discardableResult
    func createIdeaNote(title: String, body: String = "", highlightIDs: [Int64] = [], now: Date = Date()) throws -> IdeaNote {
        try writer.write { db in try Self.insertIdeaNote(db, title: title, body: body, highlightIDs: highlightIDs, now: now) }
    }

    /// 在已有事务里新建札记（问题簿“写成札记”也用它）
    static func insertIdeaNote(_ db: Database, title: String, body: String, highlightIDs: [Int64], now: Date) throws -> IdeaNote {
        let clean = WikiLinks.normalize(title)
        guard !clean.isEmpty else { throw IdeaNoteError.emptyTitle }
        var note = IdeaNote(title: clean, body: body, createdAt: now, updatedAt: now)
        try note.insert(db)
        guard let id = note.id else { return note }
        // 5.0.0：第一次重温在 7 天后（v20 之前的结构里没有排程表，如完整备份恢复的中途）
        if try db.tableExists("idea_note_review") { try scheduleNewIdeaNote(db, id: id, now: now) }
        for (i, h) in highlightIDs.enumerated() {
            try db.execute(sql: "INSERT OR IGNORE INTO idea_note_highlight(noteId, highlightId, position, addedAt) VALUES (?, ?, ?, ?)",
                           arguments: [id, h, Double(i + 1), now])
        }
        try logWriting(db, noteId: id, added: WritingCount.count(html: body), removed: 0, now: now)
        try rebuildAllIdeaNoteLinks(db)
        return note
    }

    /// 保存题目与正文。改题目时，把其他札记里指向它的 [[旧题目]] 一并改写；按正文前后字数记入写作量
    @discardableResult
    func saveIdeaNote(id: Int64, title: String, body: String, now: Date = Date()) throws -> IdeaNote {
        let clean = WikiLinks.normalize(title)
        guard !clean.isEmpty else { throw IdeaNoteError.emptyTitle }
        return try writer.write { db in
            guard var note = try IdeaNote.fetchOne(db, key: id) else { throw IdeaNoteError.missing }
            let oldTitle = note.title
            // 5.0.0：改了题目或正文就记下上一版，重温从头算
            try Self.noteIdeaNoteRevised(db, before: note, title: clean, body: body, now: now)
            let d = WritingCount.delta(from: WritingCount.count(html: note.body), to: WritingCount.count(html: body))
            note.title = clean
            note.body = body
            note.updatedAt = now
            try note.update(db)
            if WikiLinks.key(oldTitle) != WikiLinks.key(clean) || oldTitle != clean {
                let sources = try Row.fetchAll(db, sql: "SELECT n.id, n.body FROM idea_note n JOIN idea_note_link l ON l.fromId = n.id WHERE l.toId = ?", arguments: [id])
                for row in sources {
                    let rewritten = WikiLinks.rename(row["body"], from: oldTitle, to: clean)
                    try db.execute(sql: "UPDATE idea_note SET body = ? WHERE id = ?", arguments: [rewritten, row["id"] as Int64])
                }
            }
            try Self.logWriting(db, noteId: id, added: d.added, removed: d.removed, now: now)
            try Self.rebuildAllIdeaNoteLinks(db)
            try Self.rebuildIdeaNoteLinks(db, noteId: id, body: body)
            return note
        }
    }

    /// 删除进入“已删除”；彻底删除去掉引用、链接与项目关联
    func setIdeaNoteDeleted(_ id: Int64, deleted: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE idea_note SET deletedAt = ? WHERE id = ?", arguments: [deleted ? now : nil, id])
        }
    }

    func purgeIdeaNote(_ id: Int64) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM idea_note WHERE id = ?", arguments: [id]) }
    }

    /// 引用摘录：加到末尾，已引用的不重复
    func addHighlights(_ highlightIDs: [Int64], toIdeaNote noteId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            var next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM idea_note_highlight WHERE noteId = ?", arguments: [noteId]) ?? 0) + 1
            for h in highlightIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO idea_note_highlight(noteId, highlightId, position, addedAt) VALUES (?, ?, ?, ?)",
                               arguments: [noteId, h, next, now])
                if db.changesCount > 0 { next += 1 }
            }
            try db.execute(sql: "UPDATE idea_note SET updatedAt = ? WHERE id = ?", arguments: [now, noteId])
        }
    }

    func removeHighlight(_ highlightId: Int64, fromIdeaNote noteId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM idea_note_highlight WHERE noteId = ? AND highlightId = ?", arguments: [noteId, highlightId])
            try db.execute(sql: "UPDATE idea_note SET updatedAt = ? WHERE id = ?", arguments: [now, noteId])
        }
    }

    /// 引用顺序：按给定次序重新编号
    func reorderHighlights(_ orderedIDs: [Int64], inIdeaNote noteId: Int64) throws {
        try writer.write { db in
            for (i, h) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE idea_note_highlight SET position = ? WHERE noteId = ? AND highlightId = ?", arguments: [Double(i + 1), noteId, h])
            }
        }
    }

    // MARK: 读取

    func ideaNote(id: Int64) throws -> IdeaNote? {
        try writer.read { db in try IdeaNote.fetchOne(db, key: id) }
    }

    func ideaNoteCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note WHERE deletedAt IS NULL") ?? 0 }
    }

    /// 札记列表：按最近修改；query 在题目与正文中繁简通搜
    func ideaNoteSummaries(query: String = "", deleted: Bool = false) async throws -> [IdeaNoteSummary] {
        let key = ChineseFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.body, n.createdAt, n.updatedAt, n.deletedAt,
                       (SELECT COUNT(*) FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId AND h.deletedAt IS NULL WHERE x.noteId = n.id) AS hc,
                       (SELECT COUNT(*) FROM idea_note_link l JOIN idea_note f ON f.id = l.fromId AND f.deletedAt IS NULL WHERE l.toId = n.id) AS bc
                FROM idea_note n WHERE n.deletedAt IS \(deleted ? "NOT NULL" : "NULL")
                ORDER BY n.updatedAt DESC, n.id DESC
                """).compactMap { row -> IdeaNoteSummary? in
                    let plain = Markdown.plainText(fromHTML: row["body"] ?? "")
                    let title: String = row["title"]
                    if !key.isEmpty, !ChineseFold.fold(title + "\n" + plain).contains(key) { return nil }
                    return IdeaNoteSummary(id: row["id"], title: title,
                                           preview: String(plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120)),
                                           createdAt: row["createdAt"], updatedAt: row["updatedAt"], deletedAt: row["deletedAt"],
                                           highlightCount: row["hc"], backlinkCount: row["bc"])
                }
        }
    }

    /// 最近修改的札记（项目页“归入”菜单、回顾时“加入已有札记”）
    func recentIdeaNotes(limit: Int = 40) throws -> [IdeaNoteRef] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title FROM idea_note WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id DESC LIMIT ?", arguments: [limit])
                .map { IdeaNoteRef(id: $0["id"], title: $0["title"]) }
        }
    }

    func ideaNoteDetail(id: Int64) async throws -> IdeaNoteDetail {
        try await writer.read { db in
            guard let note = try IdeaNote.fetchOne(db, key: id) else { throw IdeaNoteError.missing }
            var d = IdeaNoteDetail(note: note)
            d.highlights = try Highlight.fetchAll(db, sql: """
                SELECT h.* FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId
                WHERE x.noteId = ? AND h.deletedAt IS NULL ORDER BY x.position, x.addedAt
                """, arguments: [id])
            for title in WikiLinks.titles(in: note.body) {
                if let to = try Self.resolveIdeaNoteID(db, title: title), to != id,
                   let t = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [to]) {
                    if !d.outgoing.contains(where: { $0.id == to }) { d.outgoing.append(IdeaNoteRef(id: to, title: t)) }
                } else if WikiLinks.key(title) != WikiLinks.key(note.title) {
                    d.unresolved.append(title)
                }
            }
            d.backlinks = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title FROM idea_note_link l JOIN idea_note n ON n.id = l.fromId
                WHERE l.toId = ? AND n.deletedAt IS NULL ORDER BY n.updatedAt DESC
                """, arguments: [id]).map { IdeaNoteRef(id: $0["id"], title: $0["title"]) }
            return d
        }
    }

    /// 解析题目（札记页渲染链接用）
    func resolveIdeaNoteID(title: String) throws -> Int64? {
        try writer.read { db in try Self.resolveIdeaNoteID(db, title: title) }
    }

    /// 引用了这些摘录的札记（回顾卡片、编辑面板）
    func ideaNotesCiting(highlightIDs ids: [Int64]) throws -> [Int64: [IdeaNoteRef]] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try writer.read { db in
            var out: [Int64: [IdeaNoteRef]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT x.highlightId AS hid, n.id, n.title FROM idea_note_highlight x JOIN idea_note n ON n.id = x.noteId
                WHERE n.deletedAt IS NULL AND x.highlightId IN (\(marks)) ORDER BY n.updatedAt DESC
                """, arguments: StatementArguments(ids)) {
                out[row["hid"], default: []].append(IdeaNoteRef(id: row["id"], title: row["title"]))
            }
            return out
        }
    }

    /// 本期新写的札记（学习小结）
    func ideaNotesCreated(start: Date, end: Date) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note WHERE deletedAt IS NULL AND createdAt >= ? AND createdAt < ?", arguments: [start, end]) ?? 0
        }
    }
}
