import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.1.1：问题簿
//
// 一个问题可以同时归入几本专题笔记本、几个研究项目（question_scope），随时挂上摘录、札记、记忆卡等材料（question_material）。
// 状态：待研究 → 有线索 → 已解决；另有“搁置”。挂上第一条材料时，“待研究”自动变为“有线索”。
// 标为已解决前须有解答：写一段解答，或指向一条札记（沿用 3.4 的规则）。
// 3.4 的专题问题（app_progress 中的 topic-question.*）与未保存草稿（question-draft.*）在迁移 v18 中转入问题簿。

struct Question: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    enum Status: String, Codable, CaseIterable, Identifiable, Sendable {
        case open, lead, solved, shelved
        var id: String { rawValue }
        var title: String {
            switch self {
            case .open: "待研究"
            case .lead: "有线索"
            case .solved: "已解决"
            case .shelved: "搁置"
            }
        }
        var symbol: String {
            switch self {
            case .open: "questionmark.circle"
            case .lead: "magnifyingglass.circle"
            case .solved: "checkmark.circle"
            case .shelved: "pause.circle"
            }
        }
        /// 待研究、有线索：仍在心上的问题
        var isUnsolved: Bool { self == .open || self == .lead }
    }

    var id: Int64?
    /// 问题本身：一句话，纯文字
    var title: String
    /// 补充说明（富文本）
    var detail: String = ""
    var status: Status = .open
    /// 解答（富文本）；也可只指向一条札记
    var answer: String = ""
    var answerNoteId: Int64?
    /// 「常念」：常放在心里的问题，排在前面
    var pinned = false
    var createdAt = Date()
    var updatedAt = Date()
    var solvedAt: Date?
    /// 由 3.4 专题问题迁来时的原键，便于核对
    var legacyKey: String?

    static let databaseTableName = "question"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 问题下的一条材料
struct QuestionMaterial: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case highlight, note, card, block
        var id: String { rawValue }
        var title: String {
            switch self {
            case .highlight: "摘录"
            case .note: "札记"
            case .card: "记忆卡"
            case .block: "专题文字"
            }
        }
        var symbol: String {
            switch self {
            case .highlight: "text.quote"
            case .note: "lightbulb"
            case .card: "rectangle.on.rectangle"
            case .block: "doc.text"
            }
        }
    }
    var kind: Kind
    var recordId: Int64
    /// 为什么挂在这里
    var reason: String
    /// 材料内容的开头
    var title: String
    /// 出处、牌组或所在专题
    var context: String
    /// 专题文字所在的笔记本
    var parentId: Int64? = nil
    var id: String { "\(kind.rawValue).\(recordId)" }
}

/// 问题的归属：专题笔记本或研究项目
struct QuestionScope: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case notebook, project
        var title: String { self == .notebook ? "专题" : "项目" }
    }
    var kind: Kind
    var recordId: Int64
    var title: String
    var id: String { "\(kind.rawValue).\(recordId)" }
}

/// 只要编号、题目与状态的问题引用（回顾卡片提示、编辑面板、项目页）
struct QuestionRef: Identifiable, Hashable, Sendable {
    var id: Int64
    var title: String
    var status: Question.Status
    var pinned: Bool
}

/// 问题簿的一行
struct QuestionSummary: Identifiable, Equatable, Sendable {
    var id: Int64
    var title: String
    var preview: String
    var status: Question.Status
    var pinned: Bool
    var updatedAt: Date
    var solvedAt: Date?
    var materialCount: Int
    var scopes: String
    var hasAnswerNote: Bool
}

/// 问题页一次读取的内容
struct QuestionDetail: Sendable {
    var question: Question
    var materials: [QuestionMaterial] = []
    var scopes: [QuestionScope] = []
    var answerNote: IdeaNoteRef?
}

/// 问题簿的筛选（离开再回来时保留）
struct QuestionFilter: Equatable, Sendable {
    enum State: String, CaseIterable, Identifiable, Sendable {
        case unsolved, solved, shelved, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .unsolved: "未解决"
            case .solved: "已解决"
            case .shelved: "搁置"
            case .all: "全部"
            }
        }
    }
    var state: State = .unsolved
    var query = ""
    var notebookID: Int64?
    var projectID: Int64?
}

/// 问题页编辑时自动暂存的输入；3.4 的未保存草稿也迁成这种格式
struct QuestionDraft: Codable, Equatable, Identifiable, Sendable {
    /// 已有问题为 "q编号"，尚未保存的新问题为 UUID
    var id: String
    var questionId: Int64?
    var title = ""
    var detail = ""
    var answer = ""
    var notebookID: Int64?
    var projectID: Int64?
    var evidence: PlanEvidence?
    var savedAt = Date()
    var key: String { Self.prefix + id }
    static let prefix = "question-book-draft."
    static func id(questionId: Int64) -> String { "q\(questionId)" }
    var hasInput: Bool { !title.isEmpty || HTMLSourceCodec.hasContent(detail) || HTMLSourceCodec.hasContent(answer) || evidence != nil }
}

enum QuestionError: LocalizedError {
    case emptyTitle, missing, missingAnswer
    var errorDescription: String? {
        switch self {
        case .emptyTitle: "请写下问题。"
        case .missing: "这个问题已被删除。"
        case .missingAnswer: "请先写下解答，或指向一条札记，再标为已解决。"
        }
    }
}

extension AppDatabase {
    // MARK: 迁移

    /// v18：问题、问题下的材料、问题的归属；转入 3.4 的专题问题与草稿
    static func installQuestionBook(in db: Database, now: Date = Date()) throws {
        try db.create(table: "question") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull()
            t.column("detail", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull().defaults(to: Question.Status.open.rawValue)
            t.column("answer", .text).notNull().defaults(to: "")
            t.column("answerNoteId", .integer).references("idea_note", onDelete: .setNull)
            t.column("pinned", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("solvedAt", .datetime)
            t.column("legacyKey", .text)
        }
        try db.create(index: "question_status", on: "question", columns: ["status"])
        try db.create(table: "question_material") { t in
            t.column("questionId", .integer).notNull().references("question", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("reason", .text).notNull().defaults(to: "")
            t.column("position", .double).notNull()
            t.column("addedAt", .datetime).notNull()
            t.primaryKey(["questionId", "kind", "recordId"])
        }
        try db.create(index: "question_material_record", on: "question_material", columns: ["kind", "recordId"])
        try db.create(table: "question_scope") { t in
            t.column("questionId", .integer).notNull().references("question", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.primaryKey(["questionId", "kind", "recordId"])
        }
        try db.create(index: "question_scope_record", on: "question_scope", columns: ["kind", "recordId"])
        // 材料或归属对象被彻底删除时随之去掉；解答所指的札记被彻底删除时，把札记正文留作解答
        try db.execute(sql: """
            CREATE TRIGGER question_material_highlight_deleted AFTER DELETE ON highlight BEGIN
                DELETE FROM question_material WHERE kind = 'highlight' AND recordId = OLD.id;
            END;
            CREATE TRIGGER question_material_note_deleted AFTER DELETE ON idea_note BEGIN
                DELETE FROM question_material WHERE kind = 'note' AND recordId = OLD.id;
            END;
            CREATE TRIGGER question_answer_note_deleted BEFORE DELETE ON idea_note BEGIN
                UPDATE question SET answer = CASE WHEN trim(answer) = '' THEN OLD.body ELSE answer END WHERE answerNoteId = OLD.id;
            END;
            CREATE TRIGGER question_material_card_deleted AFTER DELETE ON card BEGIN
                DELETE FROM question_material WHERE kind = 'card' AND recordId = OLD.id;
            END;
            CREATE TRIGGER question_material_block_deleted AFTER DELETE ON notebook_block BEGIN
                DELETE FROM question_material WHERE kind = 'block' AND recordId = OLD.id;
            END;
            CREATE TRIGGER question_scope_notebook_deleted AFTER DELETE ON notebook BEGIN
                DELETE FROM question_scope WHERE kind = 'notebook' AND recordId = OLD.id;
            END;
            CREATE TRIGGER question_scope_project_deleted AFTER DELETE ON research_project BEGIN
                DELETE FROM question_scope WHERE kind = 'project' AND recordId = OLD.id;
            END;
            """)
        try convertLegacyTopicQuestions(db, now: now)
    }

    /// 3.4 的问题（富文本）→ 问题簿的题目（纯文字）与补充说明。原文有格式、多段或过长时，原文整段留作补充说明，不丢内容。
    static func legacyQuestionTitle(_ html: String) -> (title: String, detail: String) {
        let lines = Markdown.plainText(fromHTML: html).components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let plain = lines.joined(separator: " ")
        guard !plain.isEmpty else { return ("未命名问题", html) }
        let formatted = html.range(of: #"<(?!/?(p|br)\b)[a-zA-Z]"#, options: .regularExpression) != nil
        if plain.count > 120 { return (String(plain.prefix(120)) + "…", html) }
        return (plain, (formatted || lines.count > 1) ? html : "")
    }

    /// 把 app_progress 里的 topic-question.* 与 question-draft.* 转入问题簿；成功一条删一条旧键。
    /// 迁移时运行一次；打开数据库时也会运行（恢复的旧备份、旧版本写入的记录都能接上），已转过的按原键跳过。
    @discardableResult
    static func convertLegacyTopicQuestions(_ db: Database, now: Date = Date()) throws -> Int {
        var converted = 0
        var map: [UUID: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, payload FROM app_progress WHERE key LIKE 'topic-question.%' ORDER BY key") {
            let key: String = row["key"]
            // 解不开的记录原样保留，不删
            guard let old = try? JSONDecoder().decode(TopicQuestion.self, from: row["payload"] as Data) else { continue }
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM question WHERE legacyKey = ?", arguments: [key]) {
                map[old.id] = existing
                try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [key])
                continue
            }
            let (title, detail) = legacyQuestionTitle(old.question)
            let evidenceExists = try old.evidence.map { try legacyRecordExists(db, $0) } ?? false
            var q = Question(title: title, detail: detail,
                             status: old.solvedAt != nil ? .solved : (evidenceExists ? .lead : .open),
                             answer: old.answer, createdAt: old.createdAt, updatedAt: old.updatedAt,
                             solvedAt: old.solvedAt, legacyKey: key)
            try q.insert(db)
            guard let id = q.id else { continue }
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notebook WHERE id = ?", arguments: [old.notebookID]) == 1 {
                try db.execute(sql: "INSERT OR IGNORE INTO question_scope(questionId, kind, recordId) VALUES (?, 'notebook', ?)", arguments: [id, old.notebookID])
            }
            if let e = old.evidence, evidenceExists {
                try db.execute(sql: "INSERT OR IGNORE INTO question_material(questionId, kind, recordId, reason, position, addedAt) VALUES (?, ?, ?, '', 1, ?)",
                               arguments: [id, legacyMaterialKind(e.kind).rawValue, e.recordID, old.updatedAt])
            }
            try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [key])
            map[old.id] = id
            converted += 1
        }
        for row in try Row.fetchAll(db, sql: "SELECT key, payload, updatedAt FROM app_progress WHERE key LIKE 'question-draft.%' ORDER BY key") {
            let key: String = row["key"]
            guard let old = try? JSONDecoder().decode(TopicQuestionDraft.self, from: row["payload"] as Data) else { continue }
            var questionId = old.original.flatMap { map[$0.id] }
            if questionId == nil, old.original != nil {
                questionId = try Int64.fetchOne(db, sql: "SELECT id FROM question WHERE legacyKey = ?", arguments: [old.value.key])
            }
            let (title, detail) = legacyQuestionTitle(old.value.question)
            let draft = QuestionDraft(id: questionId.map { QuestionDraft.id(questionId: $0) } ?? old.value.id.uuidString,
                                      questionId: questionId,
                                      title: HTMLSourceCodec.hasContent(old.value.question) ? title : "",
                                      detail: detail, answer: old.value.answer, notebookID: old.value.notebookID,
                                      evidence: old.value.evidence == old.original?.evidence ? nil : old.value.evidence,
                                      savedAt: (row["updatedAt"] as Date?) ?? now)
            try putProgress(draft, key: draft.key, in: db)
            try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [key])
            converted += 1
        }
        return converted
    }

    private static func legacyMaterialKind(_ kind: PlanEvidence.Kind) -> QuestionMaterial.Kind {
        switch kind {
        case .highlight: .highlight
        case .block: .block
        case .card: .card
        }
    }

    private static func legacyRecordExists(_ db: Database, _ e: PlanEvidence) throws -> Bool {
        let table = switch e.kind { case .highlight: "highlight"; case .block: "notebook_block"; case .card: "card" }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [e.recordID]) == 1
    }

    /// 打开数据库时补转遗留的专题问题（通常为 0 条，只是一次按主键前缀的查询）
    func convertLegacyTopicQuestions() throws -> Int {
        try writer.write { db in try Self.convertLegacyTopicQuestions(db) }
    }

    // MARK: 写入

    private static func touch(_ db: Database, _ id: Int64, _ now: Date) throws {
        try db.execute(sql: "UPDATE question SET updatedAt = ? WHERE id = ?", arguments: [now, id])
    }

    private static func hasAnswer(_ db: Database, _ q: Question) throws -> Bool {
        if HTMLSourceCodec.hasContent(q.answer) { return true }
        guard let note = q.answerNoteId else { return false }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note WHERE id = ? AND deletedAt IS NULL", arguments: [note]) == 1
    }

    @discardableResult
    func createQuestion(title: String, detail: String = "", scopes: [(QuestionScope.Kind, Int64)] = [],
                        material: (kind: QuestionMaterial.Kind, recordId: Int64, reason: String)? = nil,
                        now: Date = Date()) throws -> Question {
        let clean = WikiLinks.normalize(title)
        guard !clean.isEmpty else { throw QuestionError.emptyTitle }
        return try writer.write { db in
            var q = Question(title: clean, detail: detail, createdAt: now, updatedAt: now)
            try q.insert(db)
            guard let id = q.id else { return q }
            for (kind, recordId) in scopes {
                try db.execute(sql: "INSERT OR IGNORE INTO question_scope(questionId, kind, recordId) VALUES (?, ?, ?)", arguments: [id, kind.rawValue, recordId])
            }
            if let m = material {
                try Self.insertMaterial(db, questionId: id, kind: m.kind, recordId: m.recordId, reason: m.reason, now: now)
                q = try Question.fetchOne(db, key: id) ?? q
            }
            return q
        }
    }

    /// 保存题目、补充说明与解答（状态另行修改）
    @discardableResult
    func saveQuestion(id: Int64, title: String, detail: String, answer: String, now: Date = Date()) throws -> Question {
        let clean = WikiLinks.normalize(title)
        guard !clean.isEmpty else { throw QuestionError.emptyTitle }
        return try writer.write { db in
            guard var q = try Question.fetchOne(db, key: id) else { throw QuestionError.missing }
            q.title = clean; q.detail = detail; q.answer = answer; q.updatedAt = now
            if q.status == .solved, !(try Self.hasAnswer(db, q)) { throw QuestionError.missingAnswer }
            try q.update(db)
            return q
        }
    }

    /// 改状态：标为已解决须有解答，记下解决日期；离开“已解决”时清除解决日期（重新打开）
    func setQuestionStatus(id: Int64, _ status: Question.Status, now: Date = Date()) throws {
        try writer.write { db in
            guard var q = try Question.fetchOne(db, key: id) else { throw QuestionError.missing }
            guard q.status != status else { return }
            if status == .solved {
                guard try Self.hasAnswer(db, q) else { throw QuestionError.missingAnswer }
                q.solvedAt = now
            } else {
                q.solvedAt = nil
            }
            q.status = status; q.updatedAt = now
            try q.update(db)
        }
    }

    /// 解答指向一条札记（nil 取消指向）
    func setQuestionAnswerNote(id: Int64, noteId: Int64?, now: Date = Date()) throws {
        try writer.write { db in
            guard var q = try Question.fetchOne(db, key: id) else { throw QuestionError.missing }
            q.answerNoteId = noteId; q.updatedAt = now
            if q.status == .solved, !(try Self.hasAnswer(db, q)) { throw QuestionError.missingAnswer }
            try q.update(db)
        }
    }

    func setQuestionPinned(id: Int64, _ pinned: Bool) throws {
        try writer.write { db in try db.execute(sql: "UPDATE question SET pinned = ? WHERE id = ?", arguments: [pinned, id]) }
    }

    func deleteQuestion(id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM question WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [QuestionDraft.prefix + QuestionDraft.id(questionId: id)])
        }
    }

    private static func insertMaterial(_ db: Database, questionId: Int64, kind: QuestionMaterial.Kind, recordId: Int64, reason: String, now: Date) throws {
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM question_material WHERE questionId = ?", arguments: [questionId]) ?? 0) + 1
        try db.execute(sql: "INSERT OR IGNORE INTO question_material(questionId, kind, recordId, reason, position, addedAt) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [questionId, kind.rawValue, recordId, clean, next, now])
        if db.changesCount == 0, !clean.isEmpty {
            try db.execute(sql: "UPDATE question_material SET reason = ? WHERE questionId = ? AND kind = ? AND recordId = ?",
                           arguments: [clean, questionId, kind.rawValue, recordId])
        }
        // 挂上第一条材料：“待研究”自动变为“有线索”
        try db.execute(sql: "UPDATE question SET status = ?, updatedAt = ? WHERE id = ? AND status = ?",
                       arguments: [Question.Status.lead.rawValue, now, questionId, Question.Status.open.rawValue])
        try touch(db, questionId, now)
    }

    /// 挂材料；已挂过的不重复，只更新说明
    func addQuestionMaterial(questionId: Int64, kind: QuestionMaterial.Kind, recordId: Int64, reason: String = "", now: Date = Date()) throws {
        try writer.write { db in
            guard try Question.exists(db, key: questionId) else { throw QuestionError.missing }
            try Self.insertMaterial(db, questionId: questionId, kind: kind, recordId: recordId, reason: reason, now: now)
        }
    }

    func removeQuestionMaterial(questionId: Int64, kind: QuestionMaterial.Kind, recordId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM question_material WHERE questionId = ? AND kind = ? AND recordId = ?", arguments: [questionId, kind.rawValue, recordId])
            try Self.touch(db, questionId, now)
        }
    }

    func setQuestionMaterialReason(questionId: Int64, kind: QuestionMaterial.Kind, recordId: Int64, reason: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE question_material SET reason = ? WHERE questionId = ? AND kind = ? AND recordId = ?",
                           arguments: [reason.trimmingCharacters(in: .whitespacesAndNewlines), questionId, kind.rawValue, recordId])
        }
    }

    func setQuestionScope(questionId: Int64, kind: QuestionScope.Kind, recordId: Int64, included: Bool, now: Date = Date()) throws {
        try writer.write { db in
            if included {
                try db.execute(sql: "INSERT OR IGNORE INTO question_scope(questionId, kind, recordId) VALUES (?, ?, ?)", arguments: [questionId, kind.rawValue, recordId])
            } else {
                try db.execute(sql: "DELETE FROM question_scope WHERE questionId = ? AND kind = ? AND recordId = ?", arguments: [questionId, kind.rawValue, recordId])
            }
            try Self.touch(db, questionId, now)
        }
    }

    /// “写成札记”：问题为题、解答为正文，带过问题下的摘录，归入问题所属的项目；问题的解答改为指向这条札记
    @discardableResult
    func writeQuestionAsNote(id: Int64, now: Date = Date()) throws -> Int64 {
        try writer.write { db in
            guard var q = try Question.fetchOne(db, key: id) else { throw QuestionError.missing }
            guard HTMLSourceCodec.hasContent(q.answer) else { throw QuestionError.missingAnswer }
            let highlightIDs = try Int64.fetchAll(db, sql: """
                SELECT m.recordId FROM question_material m JOIN highlight h ON h.id = m.recordId AND h.deletedAt IS NULL
                WHERE m.questionId = ? AND m.kind = 'highlight' ORDER BY m.position
                """, arguments: [id])
            let note = try Self.insertIdeaNote(db, title: q.title, body: q.answer, highlightIDs: highlightIDs, now: now)
            guard let noteId = note.id else { throw IdeaNoteError.missing }
            for projectId in try Int64.fetchAll(db, sql: "SELECT recordId FROM question_scope WHERE questionId = ? AND kind = 'project'", arguments: [id]) {
                let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM research_project_link WHERE projectId = ?", arguments: [projectId]) ?? 0) + 1
                try db.execute(sql: "INSERT OR IGNORE INTO research_project_link(projectId, kind, recordId, position) VALUES (?, 'note', ?, ?)",
                               arguments: [projectId, noteId, next])
            }
            q.answer = ""; q.answerNoteId = noteId; q.updatedAt = now
            try q.update(db)
            return noteId
        }
    }

    // MARK: 草稿

    func questionDrafts(notebookID: Int64? = nil) throws -> [QuestionDraft] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM app_progress WHERE key LIKE ? ORDER BY updatedAt DESC, key", arguments: [QuestionDraft.prefix + "%"])
                .compactMap { try? JSONDecoder().decode(QuestionDraft.self, from: $0) }
                .filter { notebookID == nil || $0.notebookID == notebookID }
        }
    }

    /// 尚未保存的新问题草稿：建成问题（保留草稿中的解答、专题与关联材料），删去草稿
    @discardableResult
    func restoreQuestionDraft(_ draft: QuestionDraft, now: Date = Date()) throws -> Int64 {
        try writer.write { db in
            let clean = WikiLinks.normalize(draft.title)
            var q = Question(title: clean.isEmpty ? "未命名问题" : clean, detail: draft.detail, answer: draft.answer, createdAt: now, updatedAt: now)
            try q.insert(db)
            guard let id = q.id else { throw QuestionError.missing }
            if let n = draft.notebookID, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notebook WHERE id = ?", arguments: [n]) == 1 {
                try db.execute(sql: "INSERT OR IGNORE INTO question_scope(questionId, kind, recordId) VALUES (?, 'notebook', ?)", arguments: [id, n])
            }
            if let p = draft.projectID, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM research_project WHERE id = ?", arguments: [p]) == 1 {
                try db.execute(sql: "INSERT OR IGNORE INTO question_scope(questionId, kind, recordId) VALUES (?, 'project', ?)", arguments: [id, p])
            }
            if let e = draft.evidence, try Self.legacyRecordExists(db, e) {
                try Self.insertMaterial(db, questionId: id, kind: Self.legacyMaterialKind(e.kind), recordId: e.recordID, reason: "", now: now)
            }
            try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [draft.key])
            return id
        }
    }

    // MARK: 读取

    /// 仍存在（未进回收站）的材料
    private static let liveMaterialSQL = """
        ((m.kind = 'highlight' AND EXISTS (SELECT 1 FROM highlight h WHERE h.id = m.recordId AND h.deletedAt IS NULL))
         OR (m.kind = 'note' AND EXISTS (SELECT 1 FROM idea_note n WHERE n.id = m.recordId AND n.deletedAt IS NULL))
         OR (m.kind = 'card' AND EXISTS (SELECT 1 FROM card c WHERE c.id = m.recordId AND c.deletedAt IS NULL))
         OR (m.kind = 'block' AND EXISTS (SELECT 1 FROM notebook_block b WHERE b.id = m.recordId)))
        """

    private static func filterSQL(_ f: QuestionFilter) -> (String, [any DatabaseValueConvertible]) {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []
        switch f.state {
        case .unsolved: conditions.append("q.status IN ('open', 'lead')")
        case .solved: conditions.append("q.status = 'solved'")
        case .shelved: conditions.append("q.status = 'shelved'")
        case .all: break
        }
        let query = f.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            conditions.append("instr(kr_fold(q.title || char(10) || kr_search_plain(q.detail) || char(10) || kr_search_plain(q.answer)), kr_fold(?)) > 0")
            args.append(query)
        }
        if let n = f.notebookID {
            conditions.append("EXISTS (SELECT 1 FROM question_scope s WHERE s.questionId = q.id AND s.kind = 'notebook' AND s.recordId = ?)")
            args.append(n)
        }
        if let p = f.projectID {
            conditions.append(projectScopeSQL)
            args += [p, p]
        }
        return (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "), args)
    }

    /// 归入某项目，或归入该项目所含的专题笔记本（两个占位符都是项目编号）
    private static let projectScopeSQL = """
        EXISTS (SELECT 1 FROM question_scope s WHERE s.questionId = q.id AND (
            (s.kind = 'project' AND s.recordId = ?)
            OR (s.kind = 'notebook' AND s.recordId IN (SELECT recordId FROM research_project_link WHERE projectId = ? AND kind = 'notebook'))))
        """

    /// 问题簿：「常念」在前，其次是 preferProjectID（通常为当前项目）下的问题，再按最近修改；每页 50 条
    func questionPage(_ filter: QuestionFilter, preferProjectID: Int64? = nil, offset: Int = 0, limit: Int = 50) async throws -> GrowthPage<QuestionSummary> {
        try await writer.read { db in
            let (where_, args) = Self.filterSQL(filter)
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question q" + where_, arguments: StatementArguments(args)) ?? 0
            var orderArgs: [any DatabaseValueConvertible] = []
            var prefer = "0"
            if let p = preferProjectID {
                prefer = "CASE WHEN " + Self.projectScopeSQL + " THEN 1 ELSE 0 END"
                orderArgs = [p, p]
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT q.id, q.title, q.detail, q.status, q.pinned, q.updatedAt, q.solvedAt, q.answerNoteId,
                       (SELECT COUNT(*) FROM question_material m WHERE m.questionId = q.id AND \(Self.liveMaterialSQL)) AS mc,
                       (SELECT group_concat(t, '、') FROM (
                            SELECT n.title AS t FROM question_scope s JOIN notebook n ON n.id = s.recordId WHERE s.questionId = q.id AND s.kind = 'notebook'
                            UNION ALL
                            SELECT p.title FROM question_scope s JOIN research_project p ON p.id = s.recordId WHERE s.questionId = q.id AND s.kind = 'project')) AS scopes
                FROM question q\(where_)
                ORDER BY q.pinned DESC, \(prefer) DESC, q.updatedAt DESC, q.id DESC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(args + orderArgs + [max(1, limit), max(0, offset)]))
            let items = rows.map { row in
                QuestionSummary(id: row["id"], title: row["title"],
                                preview: String(Markdown.plainText(fromHTML: row["detail"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120)),
                                status: Question.Status(rawValue: row["status"]) ?? .open, pinned: row["pinned"],
                                updatedAt: row["updatedAt"], solvedAt: row["solvedAt"], materialCount: row["mc"],
                                scopes: row["scopes"] ?? "", hasAnswerNote: (row["answerNoteId"] as Int64?) != nil)
            }
            return GrowthPage(items: items, total: total)
        }
    }

    func question(id: Int64) throws -> Question? {
        try writer.read { db in try Question.fetchOne(db, key: id) }
    }

    func openQuestionCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question WHERE status IN ('open', 'lead')") ?? 0 }
    }

    func questionDetail(id: Int64) async throws -> QuestionDetail {
        try await writer.read { db in
            guard let q = try Question.fetchOne(db, key: id) else { throw QuestionError.missing }
            var d = QuestionDetail(question: q)
            func plain(_ s: String?) -> String {
                String(Markdown.plainText(fromHTML: s ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
            }
            for row in try Row.fetchAll(db, sql: "SELECT kind, recordId, reason FROM question_material WHERE questionId = ? ORDER BY position, addedAt", arguments: [id]) {
                guard let kind = QuestionMaterial.Kind(rawValue: row["kind"]) else { continue }
                let rid: Int64 = row["recordId"]
                var title = "", context = ""
                var parent: Int64?
                switch kind {
                case .highlight:
                    guard let r = try Row.fetchOne(db, sql: """
                        SELECT h.text, h.location, s.title AS st FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                        WHERE h.id = ? AND h.deletedAt IS NULL
                        """, arguments: [rid]) else { continue }
                    title = plain(r["text"])
                    context = [(r["st"] as String?).map { "《\($0)》" }, r["location"] as String?].compactMap { $0 }.joined(separator: " ")
                case .note:
                    guard let t = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ? AND deletedAt IS NULL", arguments: [rid]) else { continue }
                    title = t; context = "札记"
                case .card:
                    guard let r = try Row.fetchOne(db, sql: "SELECT front, deck FROM card WHERE id = ? AND deletedAt IS NULL", arguments: [rid]) else { continue }
                    title = plain(Card.renderHTML(r["front"])); context = r["deck"]
                case .block:
                    guard let r = try Row.fetchOne(db, sql: """
                        SELECT b.text, b.notebookId, h.text AS ht, n.title AS nt FROM notebook_block b JOIN notebook n ON n.id = b.notebookId
                        LEFT JOIN highlight h ON h.id = b.highlightId WHERE b.id = ?
                        """, arguments: [rid]) else { continue }
                    let text: String = r["text"]
                    let quoted: String? = r["ht"]
                    title = plain(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quoted : text)
                    context = "专题《\(r["nt"] as String)》"
                    parent = r["notebookId"]
                }
                d.materials.append(QuestionMaterial(kind: kind, recordId: rid, reason: row["reason"], title: title, context: context, parentId: parent))
            }
            d.scopes = try Row.fetchAll(db, sql: """
                SELECT 'notebook' AS kind, n.id, n.title FROM question_scope s JOIN notebook n ON n.id = s.recordId WHERE s.questionId = ? AND s.kind = 'notebook'
                UNION ALL
                SELECT 'project', p.id, p.title FROM question_scope s JOIN research_project p ON p.id = s.recordId WHERE s.questionId = ? AND s.kind = 'project'
                """, arguments: [id, id]).compactMap { r in
                    QuestionScope.Kind(rawValue: r["kind"]).map { QuestionScope(kind: $0, recordId: r["id"], title: r["title"]) }
                }
            if let n = q.answerNoteId, let t = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ? AND deletedAt IS NULL", arguments: [n]) {
                d.answerNote = IdeaNoteRef(id: n, title: t)
            }
            return d
        }
    }

    /// 挂着这些记录的问题（回顾卡片、摘录编辑面板、记忆卡）；unsolvedOnly 时只要未解决的
    func questionsHolding(kind: QuestionMaterial.Kind, recordIDs ids: [Int64], unsolvedOnly: Bool = false) throws -> [Int64: [QuestionRef]] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try writer.read { db in
            var out: [Int64: [QuestionRef]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT m.recordId AS rid, q.id, q.title, q.status, q.pinned FROM question_material m JOIN question q ON q.id = m.questionId
                WHERE m.kind = ? AND m.recordId IN (\(marks))\(unsolvedOnly ? " AND q.status IN ('open', 'lead')" : "")
                ORDER BY q.pinned DESC, q.updatedAt DESC
                """, arguments: StatementArguments([kind.rawValue as any DatabaseValueConvertible] + ids.map { $0 as any DatabaseValueConvertible })) {
                out[row["rid"], default: []].append(QuestionRef(id: row["id"], title: row["title"],
                                                                status: Question.Status(rawValue: row["status"]) ?? .open, pinned: row["pinned"]))
            }
            return out
        }
    }

    /// 札记页：以这条札记为解答的问题，以及挂着这条札记的问题
    func questionsForNote(_ noteId: Int64) async throws -> (answered: [QuestionRef], holding: [QuestionRef]) {
        try await writer.read { db in
            func refs(_ sql: String) throws -> [QuestionRef] {
                try Row.fetchAll(db, sql: sql, arguments: [noteId]).map {
                    QuestionRef(id: $0["id"], title: $0["title"], status: Question.Status(rawValue: $0["status"]) ?? .open, pinned: $0["pinned"])
                }
            }
            return (try refs("SELECT id, title, status, pinned FROM question WHERE answerNoteId = ? ORDER BY updatedAt DESC"),
                    try refs("SELECT q.id, q.title, q.status, q.pinned FROM question_material m JOIN question q ON q.id = m.questionId WHERE m.kind = 'note' AND m.recordId = ? ORDER BY q.updatedAt DESC"))
        }
    }

    /// 项目页“未解问题”：归入该项目、或归入其专题的未解决问题（「常念」在前，再按最近修改）
    static func openQuestions(_ db: Database, projectId: Int64, limit: Int = 50) throws -> [QuestionRef] {
        try Row.fetchAll(db, sql: """
            SELECT q.id, q.title, q.status, q.pinned FROM question q
            WHERE q.status IN ('open', 'lead') AND \(projectScopeSQL)
            ORDER BY q.pinned DESC, q.updatedAt DESC, q.id DESC LIMIT ?
            """, arguments: [projectId, projectId, limit]).map {
                QuestionRef(id: $0["id"], title: $0["title"], status: Question.Status(rawValue: $0["status"]) ?? .open, pinned: $0["pinned"])
            }
    }

    /// 本期解决的问题（学习小结、复盘引导）；重新打开的不计
    func questionsSolved(start: Date, end: Date) async throws -> Int {
        try await writer.read { db in try Self.questionsSolved(db, start: start, end: end) }
    }

    static func questionsSolved(_ db: Database, start: Date, end: Date) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question WHERE status = 'solved' AND solvedAt >= ? AND solvedAt < ?", arguments: [start, end]) ?? 0
    }

    /// 本期新写或修改过的札记（“本期札记”导出）：题目、正文、引用摘录
    func ideaNotesTouched(start: Date, end: Date) async throws -> [IdeaNoteDetail] {
        try await writer.read { db in
            let notes = try IdeaNote.fetchAll(db, sql: """
                SELECT * FROM idea_note WHERE deletedAt IS NULL AND ((createdAt >= ? AND createdAt < ?) OR (updatedAt >= ? AND updatedAt < ?))
                ORDER BY createdAt, id
                """, arguments: [start, end, start, end])
            return try notes.map { note in
                var d = IdeaNoteDetail(note: note)
                d.highlights = try Highlight.fetchAll(db, sql: """
                    SELECT h.* FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId
                    WHERE x.noteId = ? AND h.deletedAt IS NULL ORDER BY x.position, x.addedAt
                    """, arguments: [note.id])
                return d
            }
        }
    }
}
