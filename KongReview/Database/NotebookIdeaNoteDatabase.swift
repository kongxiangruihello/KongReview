import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.1.2：专题笔记本中的札记块、札记写到 Obsidian

/// 笔记本里的札记块要显示的内容（最新题目、正文与所引摘录）
struct NotebookIdeaNote: Sendable, Equatable {
    var id: Int64
    var title: String
    var body: String
    var highlightIDs: [Int64]
    var deleted: Bool
}

extension AppDatabase {
    /// v19：notebook_block 增加 noteId（札记块）；札记被彻底删除时置空，块里保留加入时的正文
    static func installNotebookNoteBlocks(in db: Database) throws {
        try db.alter(table: "notebook_block") { t in t.add(column: "noteId", .integer).references("idea_note", onDelete: .setNull) }
        try db.create(index: "notebook_block_note", on: "notebook_block", columns: ["noteId"])
    }

    /// 札记块要用的札记：题目、正文、引用的摘录（按引用顺序，只要仍在库中的）
    func notebookIdeaNotes(ids: [Int64]) throws -> [Int64: NotebookIdeaNote] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try writer.read { db in
            var out: [Int64: NotebookIdeaNote] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, title, body, deletedAt FROM idea_note WHERE id IN (\(marks))", arguments: StatementArguments(ids)) {
                let id: Int64 = row["id"]
                let hids = try Int64.fetchAll(db, sql: """
                    SELECT x.highlightId FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId AND h.deletedAt IS NULL
                    WHERE x.noteId = ? ORDER BY x.position, x.addedAt
                    """, arguments: [id])
                out[id] = NotebookIdeaNote(id: id, title: row["title"], body: row["body"], highlightIDs: hids,
                                           deleted: (row["deletedAt"] as Date?) != nil)
            }
            return out
        }
    }

    /// 收入了这条札记的专题笔记本（札记页“收入专题”）
    func notebooksContaining(noteId: Int64) throws -> [Notebook] {
        try writer.read { db in
            try Notebook.fetchAll(db, sql: """
                SELECT DISTINCT n.* FROM notebook n JOIN notebook_block b ON b.notebookId = n.id
                WHERE b.kind = 'note' AND b.noteId = ? ORDER BY n.updatedAt DESC
                """, arguments: [noteId])
        }
    }

    /// 写到 Obsidian 的全部札记（不含已删除的），带所引摘录的原文与出处
    func ideaNotesForObsidian(style: CitationStyle) throws -> [IdeaNoteMarkdown.Note] {
        try writer.read { db in
            let sources = Dictionary(try Source.fetchAll(db).compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
            return try IdeaNote.fetchAll(db, sql: "SELECT * FROM idea_note WHERE deletedAt IS NULL ORDER BY createdAt, id").compactMap { n in
                guard let id = n.id else { return nil }
                let hs = try Highlight.fetchAll(db, sql: """
                    SELECT h.* FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId
                    WHERE x.noteId = ? AND h.deletedAt IS NULL ORDER BY x.position, x.addedAt
                    """, arguments: [id])
                let quotes = hs.map { h in
                    IdeaNoteMarkdown.Quote(text: h.text,
                                           cite: CitationFormatter.citation(for: h, source: h.sourceId.flatMap { sources[$0] }, style: style))
                }
                return IdeaNoteMarkdown.Note(id: id, title: n.title, body: n.body, createdAt: n.createdAt, updatedAt: n.updatedAt, quotes: quotes)
            }
        }
    }
}
