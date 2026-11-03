import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.6：导入 KongFolio 的阅读材料（数据层）
//
// kongfolio_item：KongFolio 的来源键 → KongReview 里的摘录或札记，记下 KongFolio 那边的修改时间。
// 同一来源键再导入：没变就跳过；KongFolio 里改过（修改时间更晚）就更新原文、按语、出处、页码、标签或札记的题目与正文；
// 在 KongReview 里删去（移到最近删除）的不再加回来。只增不删：KongFolio 里删掉的，KongReview 这边保留。

/// 一次导入的结果
struct KongFolioReport: Equatable, Sendable {
    var newHighlights = 0
    var newNotes = 0
    var updated = 0
    var unchanged = 0
    /// 在 KongReview 里删去的，不再加回来
    var skippedDeleted = 0
    /// 没有文字的图片摘录、空记录
    var skippedEmpty = 0
    /// KongFolio 里移到“最近删除”的
    var skippedRemoved = 0
    var sources: [String] = []
    var added: Int { newHighlights + newNotes }

    /// 给人看的一段
    var summary: String {
        var parts: [String] = []
        if added > 0 {
            var s = "从 KongFolio 导入" + [(newHighlights, "条摘录"), (newNotes, "条札记")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: "、")
            if !sources.isEmpty { s += "（" + sources.prefix(5).map { "《\($0)》" }.joined(separator: "、") + (sources.count > 5 ? "等" : "") + "）" }
            parts.append(s + "，以后在今日试卷上出题。")
        }
        if updated > 0 { parts.append("KongFolio 里改过的 \(updated) 条已更新。") }
        if added == 0 && updated == 0 { parts.append("KongFolio 的阅读记录没有新内容（\(unchanged) 条已导入过）。") }
        var skipped: [String] = []
        if skippedEmpty > 0 { skipped.append("\(skippedEmpty) 条没有文字（如只有图片）") }
        if skippedDeleted > 0 { skipped.append("\(skippedDeleted) 条已在 KongReview 里删去") }
        if skippedRemoved > 0 { skipped.append("\(skippedRemoved) 条在 KongFolio 的最近删除里") }
        if !skipped.isEmpty { parts.append("跳过：" + skipped.joined(separator: "，") + "。") }
        return parts.joined(separator: "\n")
    }
}

extension AppDatabase {
    /// v27：来源键对照
    static func installKongFolio(in db: Database) throws {
        try db.create(table: "kongfolio_item", ifNotExists: true) { t in
            t.column("key", .text).primaryKey()
            t.column("targetKind", .text).notNull()
            t.column("targetId", .integer).notNull()
            t.column("modifiedAt", .datetime)
            t.column("importedAt", .datetime).notNull()
        }
    }

    /// 导入（一个事务：要么全成，要么不改）
    func importKongFolio(_ result: KongFolioConverter.Result, now: Date = Date()) throws -> KongFolioReport {
        try writer.write { db in
            var r = KongFolioReport(skippedEmpty: result.skippedEmpty, skippedRemoved: result.skippedRemoved)
            var sources: [String] = []
            for e in result.entries {
                switch e.kind {
                case .highlight:
                    _ = try Self.kongFolioHighlight(db, e, report: &r, sources: &sources, now: now)
                case .note:
                    var ids: [Int64] = []
                    for q in e.quotes {
                        var quiet = KongFolioReport()
                        if let id = try Self.kongFolioHighlight(db, q, report: &quiet, sources: &sources, now: now) { ids.append(id) }
                        r.newHighlights += quiet.newHighlights
                        r.updated += quiet.updated
                    }
                    try Self.kongFolioNote(db, e, quoteIDs: ids, report: &r, now: now)
                }
            }
            r.sources = sources
            return r
        }
    }

    /// 已导入过的：对应的那一条（被删去为 nil）与 KongFolio 那边的修改时间
    private static func kongFolioLink(_ db: Database, key: String) throws -> (kind: String, id: Int64, modified: Date?)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT targetKind, targetId, modifiedAt FROM kongfolio_item WHERE key = ?", arguments: [key]) else { return nil }
        let kind: String = row["targetKind"]
        let id: Int64 = row["targetId"]
        let modified: Date? = row["modifiedAt"]
        return (kind, id, modified)
    }

    private static func kongFolioRemember(_ db: Database, key: String, kind: String, id: Int64, modified: Date, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO kongfolio_item(key, targetKind, targetId, modifiedAt, importedAt) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET targetKind = excluded.targetKind, targetId = excluded.targetId, modifiedAt = excluded.modifiedAt
            """, arguments: [key, kind, id, modified, now])
    }

    /// 改过了：KongFolio 的修改时间比上次导入时晚（差不到一秒的算没改）
    private static func kongFolioChanged(_ e: KongFolioEntry, since: Date?) -> Bool {
        guard !e.appendOnly else { return false }
        guard let since else { return true }
        return e.modified.timeIntervalSince(since) > 1
    }

    private static func kongFolioSource(_ db: Database, title: String?, author: String, now: Date, sources: inout [String]) throws -> Int64? {
        guard let title, !title.isEmpty else { return nil }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE title = ? AND author = ? ORDER BY id LIMIT 1", arguments: [title, author]) { return id }
        if author.isEmpty, let id = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE title = ? ORDER BY id LIMIT 1", arguments: [title]) { return id }
        var s = Source(title: title, author: author, kind: .book, createdAt: now)
        try s.insert(db)
        if !sources.contains(title) { sources.append(title) }
        return s.id
    }

    /// 一条摘录：新的插入，改过的更新，删去的跳过。返回摘录编号（删去的为 nil）
    private static func kongFolioHighlight(_ db: Database, _ e: KongFolioEntry, report r: inout KongFolioReport,
                                           sources: inout [String], now: Date) throws -> Int64? {
        if let link = try kongFolioLink(db, key: e.key) {
            guard link.kind == "highlight", var h = try Highlight.fetchOne(db, key: link.id), h.deletedAt == nil else {
                r.skippedDeleted += 1
                return nil
            }
            guard kongFolioChanged(e, since: link.modified) else { r.unchanged += 1; return link.id }
            h.text = e.text
            h.note = e.html.isEmpty ? nil : e.html
            h.location = e.location
            h.sourceId = try kongFolioSource(db, title: e.sourceTitle, author: e.sourceAuthor, now: now, sources: &sources) ?? h.sourceId
            var tags = h.tags
            for t in e.tags where !tags.contains(t) { tags.append(t) }
            h.tags = tags
            h.updatedAt = now
            try h.update(db)
            try kongFolioRemember(db, key: e.key, kind: "highlight", id: link.id, modified: e.modified, now: now)
            r.updated += 1
            return link.id
        }
        let sourceId = try kongFolioSource(db, title: e.sourceTitle, author: e.sourceAuthor, now: now, sources: &sources)
        // 已有一模一样的（如以前手抄过）：对上即可，不重复
        if let same = try Int64.fetchOne(db, sql: """
            SELECT id FROM highlight WHERE text = ? AND sourceId IS ? AND COALESCE(location, '') = ? AND deletedAt IS NULL LIMIT 1
            """, arguments: [e.text, sourceId, e.location ?? ""]) {
            try kongFolioRemember(db, key: e.key, kind: "highlight", id: same, modified: e.modified, now: now)
            r.unchanged += 1
            return same
        }
        var h = Highlight(sourceId: sourceId, text: e.text, note: e.html.isEmpty ? nil : e.html, location: e.location,
                          tags: e.tags, createdAt: e.created, updatedAt: now)
        try h.insert(db)
        guard let id = h.id else { return nil }
        try kongFolioRemember(db, key: e.key, kind: "highlight", id: id, modified: e.modified, now: now)
        r.newHighlights += 1
        return id
    }

    /// 一条札记：新的写入（7 天后第一次出论证题），改过的更新题目与正文，删去的跳过；引用的摘录挂上
    private static func kongFolioNote(_ db: Database, _ e: KongFolioEntry, quoteIDs: [Int64], report r: inout KongFolioReport, now: Date) throws {
        let title = WikiLinks.normalize(e.title)
        guard !title.isEmpty else { r.skippedEmpty += 1; return }
        if let link = try kongFolioLink(db, key: e.key) {
            guard link.kind == "note", var note = try IdeaNote.fetchOne(db, key: link.id), note.deletedAt == nil else {
                r.skippedDeleted += 1
                return
            }
            try attach(db, noteId: link.id, quoteIDs: quoteIDs, now: now)
            guard kongFolioChanged(e, since: link.modified) else { r.unchanged += 1; return }
            try noteIdeaNoteRevised(db, before: note, title: title, body: e.html, now: now)
            note.title = title
            note.body = e.html
            note.updatedAt = now
            try note.update(db)
            try kongFolioRemember(db, key: e.key, kind: "note", id: link.id, modified: e.modified, now: now)
            r.updated += 1
            return
        }
        let note = try insertIdeaNote(db, title: title, body: e.html, highlightIDs: quoteIDs, now: now)
        guard let id = note.id else { return }
        try kongFolioRemember(db, key: e.key, kind: "note", id: id, modified: e.modified, now: now)
        r.newNotes += 1
    }

    private static func attach(_ db: Database, noteId: Int64, quoteIDs: [Int64], now: Date) throws {
        guard !quoteIDs.isEmpty else { return }
        let start = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM idea_note_highlight WHERE noteId = ?", arguments: [noteId])) ?? 0
        for (i, h) in quoteIDs.enumerated() {
            try db.execute(sql: "INSERT OR IGNORE INTO idea_note_highlight(noteId, highlightId, position, addedAt) VALUES (?, ?, ?, ?)",
                           arguments: [noteId, h, start + Double(i + 1), now])
        }
    }

    /// 已从 KongFolio 导入多少（摘录、札记）
    func kongFolioCounts() throws -> (highlights: Int, notes: Int) {
        try writer.read { db in
            guard try db.tableExists("kongfolio_item") else { return (0, 0) }
            let h = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT targetId) FROM kongfolio_item WHERE targetKind = 'highlight'") ?? 0
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT targetId) FROM kongfolio_item WHERE targetKind = 'note'") ?? 0
            return (h, n)
        }
    }
}
