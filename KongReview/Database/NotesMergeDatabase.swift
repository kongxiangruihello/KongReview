import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.4.0：问题簿、专题笔记本并入札记
//
// 作者要求把札记、问题簿、专题笔记本合并为札记，连数据一起合并。做法：
// - 一个问题 → 一条札记：题目是问题本身；正文依次是状态、说明、解答、材料说明、原先的归属；挂着的摘录成为札记引用的摘录，
//   挂着的札记写成 [[链接]]。
// - 一本笔记本 → 没有小标题的，整本一条札记；有小标题的，每个小标题下的内容一条札记（题目“笔记本名·小标题”），
//   另有一条以笔记本名为题的“目次”札记，按原来的顺序链接各节。摘录块写成引文并成为札记引用的摘录，札记块写成 [[链接]]。
// - 重温的排程带过来：问题沿用进展题或解答题的到期日，各节沿用其中段落最早的到期日；搁置的问题与目次不排进日课。
// - 原来的行先原样抄进 merged_* 各表，再从 question、notebook 等表里删去；idea_note_origin 记下每条札记的来历。
//   数据不丢：要改合并的办法，可以凭这两处重做。
//
// mergeIntoIdeaNotes 可以反复调用：没有待并入的问题、笔记本时什么也不做。

/// 一次合并的结果
struct NotesMergeResult: Equatable, Sendable {
    var questions = 0
    var notebooks = 0
    /// 新生成的札记条数（含目次）
    var notes = 0
    var isEmpty: Bool { questions == 0 && notebooks == 0 }
}

extension AppDatabase {
    /// 归档用的表：原表名 → 归档表名
    static let notesMergeArchives: [(source: String, archive: String)] = [
        ("question", "merged_question"), ("question_material", "merged_question_material"),
        ("question_scope", "merged_question_scope"), ("question_review", "merged_question_review"),
        ("question_answer_review", "merged_question_answer_review"),
        ("notebook", "merged_notebook"), ("notebook_block", "merged_notebook_block"),
        ("notebook_block_review", "merged_notebook_block_review"),
    ]

    /// v30：来历表，并把现有的问题、笔记本并入札记
    static func installNotesMerge(in db: Database, now: Date = Date()) throws {
        try db.create(table: "idea_note_origin", ifNotExists: true) { t in
            t.column("noteId", .integer).notNull().references("idea_note", onDelete: .cascade)
            // question、notebook、block
            t.column("kind", .text).notNull()
            t.column("originId", .integer).notNull()
            t.column("mergedAt", .datetime).notNull()
            t.primaryKey(["kind", "originId"])
        }
        try db.create(index: "idea_note_origin_note", on: "idea_note_origin", columns: ["noteId"], ifNotExists: true)
        _ = try mergeIntoIdeaNotes(db, now: now)
    }

    /// 应用启动时再看一遍（别处万一又写进了问题或笔记本）
    @discardableResult
    func mergeIntoIdeaNotes(now: Date = Date()) throws -> NotesMergeResult {
        try writer.write { db in try Self.mergeIntoIdeaNotes(db, now: now) }
    }

    /// 已并入的条数（来历表里的）：问题、笔记本
    func notesMergeTotals() throws -> (questions: Int, notebooks: Int) {
        try writer.read { db in
            guard try db.tableExists("idea_note_origin") else { return (0, 0) }
            let q = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note_origin WHERE kind = 'question'") ?? 0
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note_origin WHERE kind = 'notebook'") ?? 0
            return (q, n)
        }
    }

    /// 札记的来历（札记页上注一句）：question、notebook、block
    func ideaNoteOriginKind(noteId: Int64) throws -> String? {
        try writer.read { db in
            guard try db.tableExists("idea_note_origin") else { return nil }
            return try String.fetchOne(db, sql: """
                SELECT kind FROM idea_note_origin WHERE noteId = ?
                ORDER BY CASE kind WHEN 'question' THEN 0 WHEN 'notebook' THEN 1 ELSE 2 END LIMIT 1
                """, arguments: [noteId])
        }
    }

    // MARK: 合并

    static func mergeIntoIdeaNotes(_ db: Database, now: Date) throws -> NotesMergeResult {
        guard try db.tableExists("idea_note_origin"), try db.tableExists("idea_note"),
              try db.tableExists("question"), try db.tableExists("notebook") else { return NotesMergeResult() }
        let questionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question") ?? 0
        let notebookCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notebook") ?? 0
        guard questionCount + notebookCount > 0 else { return NotesMergeResult() }

        var merge = NotesMerger(now: now)
        try merge.loadTitles(db)
        try merge.mergeNotebooks(db)
        try merge.mergeQuestions(db)

        // 原样归档，再从原表删去（先删从属的表：迁移时外键是关着的，不会自动级联）
        for (source, archive) in notesMergeArchives {
            guard try db.tableExists(source) else { continue }
            if try !db.tableExists(archive) {
                try db.execute(sql: "CREATE TABLE \(archive) AS SELECT * FROM \(source) WHERE 0")
            }
            try db.execute(sql: "INSERT INTO \(archive) SELECT * FROM \(source)")
        }
        if try db.tableExists("writing_log") {
            // 笔记本的写作量记到它的札记名下（目次或整本的那一条）
            for (notebookId, noteId) in merge.notebookNotes {
                try db.execute(sql: "UPDATE writing_log SET noteId = COALESCE(noteId, ?), notebookId = NULL WHERE notebookId = ?",
                               arguments: [noteId, notebookId])
            }
            try db.execute(sql: "UPDATE writing_log SET notebookId = NULL WHERE notebookId IS NOT NULL")
        }
        for table in ["notebook_block_review", "question_answer_review", "question_review", "question_scope", "question_material",
                      "notebook_block", "question", "notebook"] {
            guard try db.tableExists(table) else { continue }
            try db.execute(sql: "DELETE FROM \(table)")
        }

        try rebuildAllIdeaNoteLinks(db)
        if try db.tableExists("idea_note_review") { try ensureRevisitSchedules(db, now: now) }
        return NotesMergeResult(questions: merge.questions, notebooks: merge.notebooks, notes: merge.notes)
    }
}

/// 合并的过程（只在 mergeIntoIdeaNotes 的事务里用）
private struct NotesMerger {
    let now: Date
    var usedTitles = Set<String>()
    /// 笔记本 → 它的札记（目次，或整本的那一条）的编号与题目
    var notebookNotes: [Int64: Int64] = [:]
    var notebookTitles: [Int64: String] = [:]
    /// 笔记本里的块 → 所在札记的题目
    var blockTitles: [Int64: String] = [:]
    var questions = 0
    var notebooks = 0
    var notes = 0

    static let farDay = "9999-12-31"

    init(now: Date) { self.now = now }

    mutating func loadTitles(_ db: Database) throws {
        for title in try String.fetchAll(db, sql: "SELECT title FROM idea_note WHERE deletedAt IS NULL") {
            usedTitles.insert(WikiLinks.key(title))
        }
    }

    // MARK: 题目与文字

    /// 能放进 [[ ]] 的题目：去掉方括号、竖线与换行，过长的截短；与已有札记同名的加序号
    mutating func uniqueTitle(_ raw: String, fallback: String) -> String {
        var base = WikiLinks.normalize(raw
            .replacingOccurrences(of: "[", with: "［").replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "|", with: "｜"))
        if base.isEmpty { base = fallback }
        if base.count > 120 { base = String(base.prefix(119)) + "…" }
        var title = base
        var n = 2
        while usedTitles.contains(WikiLinks.key(title)) {
            title = "\(base)（\(n)）"
            n += 1
        }
        usedTitles.insert(WikiLinks.key(title))
        return title
    }

    static func link(_ title: String) -> String { "[[" + Markdown.escape(title) + "]]" }

    static func plain(_ text: String) -> String {
        Markdown.plainText(fromHTML: Markdown.richHTML(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 整段只是一个标题（<h1>…<h6>）时，取标题文字
    static func soleHeading(_ text: String) -> String? {
        let html = Markdown.richHTML(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"^<h[1-6][^>]*>(.*)</h[1-6]>$"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let inner = ns.substring(with: m.range(at: 1))
        guard inner.range(of: #"</h[1-6]>|<p[ >]|<ul|<ol|<blockquote"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let title = plain(inner)
        return title.isEmpty ? nil : title
    }

    static func short(_ text: String, _ limit: Int) -> String {
        let t = plain(text).replacingOccurrences(of: "\n", with: " ")
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    static func cite(_ db: Database, highlight row: Row) throws -> String {
        var parts: [String] = []
        if let sid = row["sourceId"] as Int64?,
           let s = try Row.fetchOne(db, sql: "SELECT title, author FROM source WHERE id = ?", arguments: [sid]) {
            let author: String = (s["author"] as String?) ?? ""
            let title: String = (s["title"] as String?) ?? ""
            if !author.isEmpty { parts.append(author) }
            if !title.isEmpty { parts.append("《\(title)》") }
        }
        if let location = row["location"] as String?, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " ")
    }

    // MARK: 写入

    mutating func insertNote(_ db: Database, title: String, body: String, createdAt: Date, updatedAt: Date,
                             highlightIDs: [Int64]) throws -> Int64 {
        try db.execute(sql: "INSERT INTO idea_note(title, body, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                       arguments: [title, body, createdAt, updatedAt])
        let id = db.lastInsertedRowID
        var seen = Set<Int64>()
        var position = 1.0
        for h in highlightIDs where seen.insert(h).inserted {
            try db.execute(sql: "INSERT OR IGNORE INTO idea_note_highlight(noteId, highlightId, position, addedAt) VALUES (?, ?, ?, ?)",
                           arguments: [id, h, position, now])
            position += 1
        }
        notes += 1
        return id
    }

    func recordOrigin(_ db: Database, noteId: Int64, kind: String, originId: Int64) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO idea_note_origin(noteId, kind, originId, mergedAt) VALUES (?, ?, ?, ?)",
                       arguments: [noteId, kind, originId, now])
    }

    func schedule(_ db: Database, noteId: Int64, dueDay: String, interval: Int, lastReviewedAt: Date?, reviewCount: Int) throws {
        guard try db.tableExists("idea_note_review") else { return }
        try db.execute(sql: """
            INSERT INTO idea_note_review(noteId, dueDay, intervalDays, lastReviewedAt, reviewCount) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(noteId) DO UPDATE SET dueDay = excluded.dueDay, intervalDays = excluded.intervalDays,
                lastReviewedAt = excluded.lastReviewedAt, reviewCount = excluded.reviewCount
            """, arguments: [noteId, dueDay, max(1, interval), lastReviewedAt, reviewCount])
    }

    // MARK: 笔记本

    /// 一节：小标题（没有则为 nil）与其下的块
    private struct Section {
        var heading: String?
        var blocks: [Row] = []
    }

    mutating func mergeNotebooks(_ db: Database) throws {
        let hasBlockReview = try db.tableExists("notebook_block_review")
        let hasBlockNote = try db.columns(in: "notebook_block").contains { $0.name == "note" }
        let hasBlockNoteId = try db.columns(in: "notebook_block").contains { $0.name == "noteId" }
        for notebook in try Row.fetchAll(db, sql: "SELECT * FROM notebook ORDER BY createdAt, id") {
            let notebookId: Int64 = notebook["id"]
            let rawTitle: String = notebook["title"]
            let created: Date = notebook["createdAt"]
            let updated: Date = notebook["updatedAt"]
            let blocks = try Row.fetchAll(db, sql: "SELECT * FROM notebook_block WHERE notebookId = ? ORDER BY position, id", arguments: [notebookId])

            // 按小标题分节；第一个小标题之前的算“前言”
            var sections: [Section] = [Section(heading: nil)]
            for block in blocks {
                let kind: String = block["kind"]
                let text: String = block["text"]
                if kind == "heading" {
                    sections.append(Section(heading: Self.plain(text)))
                } else if kind == "text", let heading = Self.soleHeading(text) {
                    // 文字块里只写了一个标题（## 一、…）的，也当小标题
                    sections.append(Section(heading: heading))
                } else {
                    sections[sections.count - 1].blocks.append(block)
                }
            }
            let preface = sections[0]
            let titled = Array(sections.dropFirst())
            let mainTitle = uniqueTitle(rawTitle, fallback: "未命名笔记本")

            if titled.isEmpty {
                // 没有小标题：整本一条
                let rendered = try render(db, blocks: preface.blocks, hasBlockNote: hasBlockNote, hasBlockNoteId: hasBlockNoteId)
                let id = try insertNote(db, title: mainTitle, body: rendered.html, createdAt: created, updatedAt: updated,
                                        highlightIDs: rendered.highlightIDs)
                try recordOrigin(db, noteId: id, kind: "notebook", originId: notebookId)
                for block in preface.blocks {
                    let bid: Int64 = block["id"]
                    blockTitles[bid] = mainTitle
                    try recordOrigin(db, noteId: id, kind: "block", originId: bid)
                }
                if hasBlockReview { try carryBlockSchedule(db, noteId: id, blocks: preface.blocks) }
                notebookNotes[notebookId] = id
                notebookTitles[notebookId] = mainTitle
                notebooks += 1
                continue
            }

            // 有小标题：各节各一条，再加目次
            var items: [String] = []
            var sectionNumber = 0
            for section in titled {
                sectionNumber += 1
                let heading = (section.heading ?? "").isEmpty ? "第 \(sectionNumber) 节" : (section.heading ?? "")
                guard !section.blocks.isEmpty else {
                    items.append("<li>" + Markdown.escape(heading) + "</li>")
                    continue
                }
                let title = uniqueTitle(rawTitle + "·" + heading, fallback: "未命名笔记本·第 \(sectionNumber) 节")
                let rendered = try render(db, blocks: section.blocks, hasBlockNote: hasBlockNote, hasBlockNoteId: hasBlockNoteId)
                let dates = section.blocks.map { (created: $0["createdAt"] as Date, updated: $0["updatedAt"] as Date) }
                let id = try insertNote(db, title: title, body: rendered.html,
                                        createdAt: dates.map(\.created).min() ?? created, updatedAt: dates.map(\.updated).max() ?? updated,
                                        highlightIDs: rendered.highlightIDs)
                for block in section.blocks {
                    let bid: Int64 = block["id"]
                    blockTitles[bid] = title
                    try recordOrigin(db, noteId: id, kind: "block", originId: bid)
                }
                if hasBlockReview { try carryBlockSchedule(db, noteId: id, blocks: section.blocks) }
                items.append("<li>" + Self.link(title) + "</li>")
            }
            let prefaceRendered = try render(db, blocks: preface.blocks, hasBlockNote: hasBlockNote, hasBlockNoteId: hasBlockNoteId)
            let body = prefaceRendered.html + "<h2>目次</h2><ol>" + items.joined() + "</ol>"
            let id = try insertNote(db, title: mainTitle, body: body, createdAt: created, updatedAt: updated,
                                    highlightIDs: prefaceRendered.highlightIDs)
            try recordOrigin(db, noteId: id, kind: "notebook", originId: notebookId)
            for block in preface.blocks {
                let bid: Int64 = block["id"]
                blockTitles[bid] = mainTitle
                try recordOrigin(db, noteId: id, kind: "block", originId: bid)
            }
            // 目次不出论证题
            try schedule(db, noteId: id, dueDay: Self.farDay, interval: 365, lastReviewedAt: nil, reviewCount: 0)
            notebookNotes[notebookId] = id
            notebookTitles[notebookId] = mainTitle
            notebooks += 1
        }
    }

    /// 一组块 → 正文（HTML）与引用的摘录
    func render(_ db: Database, blocks: [Row], hasBlockNote: Bool, hasBlockNoteId: Bool) throws -> (html: String, highlightIDs: [Int64]) {
        var html = ""
        var highlightIDs: [Int64] = []
        for block in blocks {
            let kind: String = block["kind"]
            let text: String = block["text"]
            switch kind {
            case "highlight":
                var quote = text
                var citation = ""
                if let hid = block["highlightId"] as Int64?,
                   let h = try Row.fetchOne(db, sql: "SELECT id, sourceId, text, location FROM highlight WHERE id = ?", arguments: [hid]) {
                    highlightIDs.append(hid)
                    let live: String = h["text"]
                    if !Self.plain(live).isEmpty { quote = live }
                    citation = try Self.cite(db, highlight: h)
                }
                html += "<blockquote>" + Markdown.richHTML(quote)
                if !citation.isEmpty { html += "<p>——" + Markdown.escape(citation) + "</p>" }
                html += "</blockquote>"
                if hasBlockNote, let note = block["note"] as String?, !Self.plain(note).isEmpty {
                    html += Markdown.richHTML(note)
                }
            case "note":
                if hasBlockNoteId, let nid = block["noteId"] as Int64?,
                   let title = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [nid]) {
                    html += "<p>" + Self.link(title) + "</p>"
                } else if !Self.plain(text).isEmpty {
                    html += Markdown.richHTML(text)
                }
            default:
                if !Self.plain(text).isEmpty { html += Markdown.richHTML(text) }
            }
        }
        return (html, highlightIDs)
    }

    /// 这一节里的段落原有的重温排程：取最早到期的那一段的
    func carryBlockSchedule(_ db: Database, noteId: Int64, blocks: [Row]) throws {
        let ids = blocks.map { $0["id"] as Int64 }
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        guard let row = try Row.fetchOne(db, sql: """
            SELECT dueDay, intervalDays, lastReviewedAt, reviewCount FROM notebook_block_review
            WHERE blockId IN (\(marks)) ORDER BY dueDay, blockId LIMIT 1
            """, arguments: StatementArguments(ids)) else { return }
        try schedule(db, noteId: noteId, dueDay: row["dueDay"], interval: (row["intervalDays"] as Int?) ?? 7,
                     lastReviewedAt: row["lastReviewedAt"], reviewCount: (row["reviewCount"] as Int?) ?? 0)
    }

    // MARK: 问题

    mutating func mergeQuestions(_ db: Database) throws {
        let hasReview = try db.tableExists("question_review")
        var reviewHasInterval = false
        if hasReview { reviewHasInterval = try db.columns(in: "question_review").contains { $0.name == "intervalDays" } }
        let hasAnswerReview = try db.tableExists("question_answer_review")
        let hasProjects = try db.tableExists("research_project")
        let hasCards = try db.tableExists("card")
        for q in try Row.fetchAll(db, sql: "SELECT * FROM question ORDER BY createdAt, id") {
            let qid: Int64 = q["id"]
            let rawTitle: String = q["title"]
            let detail: String = q["detail"]
            let answer: String = q["answer"]
            let statusRaw: String = q["status"]
            let status = Question.Status(rawValue: statusRaw) ?? .open
            let pinned: Bool = (q["pinned"] as Bool?) ?? false
            let created: Date = q["createdAt"]
            let updated: Date = q["updatedAt"]

            var body = "<p><strong>问题</strong>（原在问题簿；状态：" + status.title + (pinned ? "；常念" : "") + "）</p>"
            if !Self.plain(detail).isEmpty { body += Markdown.richHTML(detail) }

            var answerHTML = ""
            if !Self.plain(answer).isEmpty { answerHTML += Markdown.richHTML(answer) }
            if let nid = q["answerNoteId"] as Int64?,
               let title = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [nid]) {
                answerHTML += "<p>见 " + Self.link(title) + "</p>"
            }
            if !answerHTML.isEmpty { body += "<h2>解答</h2>" + answerHTML }

            // 材料：摘录成为引用的摘录；写了“为什么挂在这里”的，连同札记、记忆卡、笔记段落列在正文里
            var highlightIDs: [Int64] = []
            var lines: [String] = []
            for m in try Row.fetchAll(db, sql: "SELECT kind, recordId, reason FROM question_material WHERE questionId = ? ORDER BY position, addedAt", arguments: [qid]) {
                let kind: String = m["kind"]
                let rid: Int64 = m["recordId"]
                let reason = ((m["reason"] as String?) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = reason.isEmpty ? "" : "：" + Markdown.escape(reason)
                switch kind {
                case "highlight":
                    guard let h = try Row.fetchOne(db, sql: "SELECT id, text FROM highlight WHERE id = ?", arguments: [rid]) else { continue }
                    highlightIDs.append(rid)
                    let text: String = h["text"]
                    if !reason.isEmpty { lines.append("<li>摘录“" + Markdown.escape(Self.short(text, 30)) + "”" + tail + "</li>") }
                case "note":
                    if let title = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [rid]) {
                        lines.append("<li>" + Self.link(title) + tail + "</li>")
                    }
                case "card":
                    if hasCards, let front = try String.fetchOne(db, sql: "SELECT front FROM card WHERE id = ?", arguments: [rid]) {
                        lines.append("<li>记忆卡“" + Markdown.escape(Self.short(front, 40)) + "”" + tail + "</li>")
                    }
                case "block":
                    if let title = blockTitles[rid] { lines.append("<li>" + Self.link(title) + tail + "</li>") }
                default:
                    continue
                }
            }
            if !lines.isEmpty { body += "<h2>材料</h2><ul>" + lines.joined() + "</ul>" }

            // 原先的归属
            var homes: [String] = []
            for s in try Row.fetchAll(db, sql: "SELECT kind, recordId FROM question_scope WHERE questionId = ? ORDER BY kind, recordId", arguments: [qid]) {
                let kind: String = s["kind"]
                let rid: Int64 = s["recordId"]
                if kind == "notebook", let title = notebookTitles[rid] {
                    homes.append(Self.link(title))
                } else if kind == "project", hasProjects,
                          let title = try String.fetchOne(db, sql: "SELECT title FROM research_project WHERE id = ?", arguments: [rid]) {
                    homes.append("项目“" + Markdown.escape(title) + "”")
                }
            }
            if !homes.isEmpty { body += "<p>原归入：" + homes.joined(separator: "、") + "</p>" }

            let title = uniqueTitle(rawTitle, fallback: "未命名的问题")
            let id = try insertNote(db, title: title, body: body, createdAt: created, updatedAt: updated, highlightIDs: highlightIDs)
            try recordOrigin(db, noteId: id, kind: "question", originId: qid)
            questions += 1

            // 排程：未解决的沿用进展题，已解决的沿用解答题，搁置的一年后再说；都没有的留给 ensureRevisitSchedules
            if status == .shelved {
                try schedule(db, noteId: id, dueDay: AppDatabase.revisitDay(now, plus: 365), interval: 365, lastReviewedAt: nil, reviewCount: 0)
            } else if status == .solved, hasAnswerReview,
                      let r = try Row.fetchOne(db, sql: "SELECT * FROM question_answer_review WHERE questionId = ?", arguments: [qid]) {
                try schedule(db, noteId: id, dueDay: r["dueDay"], interval: (r["intervalDays"] as Int?) ?? 7,
                             lastReviewedAt: r["lastReviewedAt"], reviewCount: (r["reviewCount"] as Int?) ?? 0)
            } else if status.isUnsolved, hasReview,
                      let r = try Row.fetchOne(db, sql: "SELECT * FROM question_review WHERE questionId = ?", arguments: [qid]) {
                let interval = reviewHasInterval ? ((r["intervalDays"] as Int?) ?? 7) : 7
                try schedule(db, noteId: id, dueDay: r["dueDay"], interval: interval,
                             lastReviewedAt: r["lastReviewedAt"], reviewCount: (r["reviewCount"] as Int?) ?? 0)
            }
        }
    }
}
