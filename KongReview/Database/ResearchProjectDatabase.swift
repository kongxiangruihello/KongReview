import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.0：研究项目
//
// 一个研究项目就是一件要交出去的学术成果：论文、著作、讲座与讲稿、课程。
// 项目不存材料，只把已有的专题笔记本、出处、学习计划、专题问题归到一起；
// “当前项目”沿用 3.15 本期焦点的存储（app_progress 的 learning.focus，kind = project）。

struct ResearchProject: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case paper, book, lecture, course, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paper: "论文"
            case .book: "著作"
            case .lecture: "讲座与讲稿"
            case .course: "课程"
            case .other: "其他"
            }
        }
        var icon: String {
            switch self {
            case .paper: "doc.text"
            case .book: "book.closed"
            case .lecture: "person.wave.2"
            case .course: "graduationcap"
            case .other: "folder"
            }
        }
    }

    /// 阶段：构思 → 资料 → 初稿 → 修改 → 已交出 → 完成；“搁置”可从任一阶段进入，再回到原阶段
    enum Stage: String, Codable, CaseIterable, Identifiable, Sendable {
        case idea, material, draft, revision, submitted, done, paused
        var id: String { rawValue }
        var title: String {
            switch self {
            case .idea: "构思"
            case .material: "资料"
            case .draft: "初稿"
            case .revision: "修改"
            case .submitted: "已交出"
            case .done: "完成"
            case .paused: "搁置"
            }
        }
        var hint: String {
            switch self {
            case .idea: "定题、写研究问题"
            case .material: "读书、摘录、建专题笔记本"
            case .draft: "在专题笔记本或 Word 里成稿"
            case .revision: "引文核对、补注、改写"
            case .submitted: "投稿、交书稿或已开讲，等待结果"
            case .done: "刊出、出版或课程结束"
            case .paused: "暂时放下，随时可回到原阶段"
            }
        }
        /// 阶段条上依次显示的六步（不含搁置）
        static let flow: [Stage] = [.idea, .material, .draft, .revision, .submitted, .done]
        var order: Int { Stage.flow.firstIndex(of: self) ?? -1 }
    }

    var id: Int64?
    var title: String
    var kind: Kind = .paper
    var stage: Stage = .idea
    /// 一句话的研究问题
    var question: String = ""
    var dueDate: Date?
    var targetWords: Int?
    var createdAt = Date()
    var updatedAt = Date()
    var archivedAt: Date?

    static let databaseTableName = "research_project"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isArchived: Bool { archivedAt != nil }

    /// 截止前剩余天数（按自然日；已过期为负数）
    func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let dueDate else { return nil }
        let a = calendar.startOfDay(for: now), b = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}

/// 项目与专题笔记本、出处的关联
struct ResearchProjectLink: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case notebook, source
        /// 4.1：札记
        case note
        var title: String {
            switch self {
            case .notebook: "专题笔记本"
            case .source: "出处"
            case .note: "札记"
            }
        }
    }
    var projectId: Int64
    var kind: Kind
    var recordId: Int64
    var title: String = ""
    /// 笔记本：摘录块数；出处：摘录条数
    var highlightCount = 0
    var id: String { "\(kind.rawValue).\(recordId)" }
}

/// 阶段变化记录
struct ResearchProjectStageEvent: Codable, Hashable, Sendable, Identifiable {
    var id: Int64
    var stage: ResearchProject.Stage
    var at: Date
    var note: String
}

/// 项目页一次读取的全部内容
struct ResearchProjectOverview: Sendable {
    var project: ResearchProject
    var links: [ResearchProjectLink] = []
    /// 关联材料中的摘录（去重）与由这些摘录做成的卡片
    var highlightCount = 0
    var cardCount = 0
    /// 下一步：关联到本项目、尚未完成也未取消的学习计划（按日期）
    var pendingPlans: [LearningPlan] = []
    /// 关联笔记本里尚未解决的专题问题（最近更新的在前）
    var openQuestions: [TopicQuestion] = []
    var stages: [ResearchProjectStageEvent] = []
}

enum ResearchProjectError: LocalizedError {
    case emptyTitle, missing
    var errorDescription: String? {
        switch self {
        case .emptyTitle: "请填写项目题目。"
        case .missing: "这个项目已被删除。"
        }
    }
}

extension AppDatabase {
    // MARK: 迁移

    /// v16：研究项目、关联、阶段记录与写作量四张表；把 3.15 的本期焦点转成一个项目并设为当前项目
    static func installResearchProjects(in db: Database, now: Date = Date()) throws {
        try db.create(table: "research_project") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("stage", .text).notNull()
            t.column("question", .text).notNull().defaults(to: "")
            t.column("dueDate", .datetime)
            t.column("targetWords", .integer)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("archivedAt", .datetime)
        }
        try db.create(table: "research_project_link") { t in
            t.column("projectId", .integer).notNull().references("research_project", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("position", .double).notNull()
            t.primaryKey(["projectId", "kind", "recordId"])
        }
        try db.create(index: "research_project_link_record", on: "research_project_link", columns: ["kind", "recordId"])
        try db.create(table: "research_project_stage") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("projectId", .integer).notNull().references("research_project", onDelete: .cascade)
            t.column("stage", .text).notNull()
            t.column("at", .datetime).notNull()
            t.column("note", .text).notNull().defaults(to: "")
        }
        try db.create(index: "research_project_stage_project", on: "research_project_stage", columns: ["projectId", "at"])
        // 写作量（4.0-b 起记录）：笔记本自动记录按“笔记本＋日期”合并为一行；手记 origin = manual
        try db.create(table: "writing_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("projectId", .integer).references("research_project", onDelete: .setNull)
            t.column("notebookId", .integer).references("notebook", onDelete: .setNull)
            t.column("day", .text).notNull()
            t.column("added", .integer).notNull().defaults(to: 0)
            t.column("removed", .integer).notNull().defaults(to: 0)
            t.column("origin", .text).notNull()
            t.column("note", .text).notNull().defaults(to: "")
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "writing_log_day", on: "writing_log", columns: ["day"])
        try db.create(index: "writing_log_project", on: "writing_log", columns: ["projectId", "day"])
        // 笔记本、出处被删除时去掉关联（关联是多态的，不能用外键）
        try db.execute(sql: """
            CREATE TRIGGER research_project_link_notebook_deleted AFTER DELETE ON notebook BEGIN
                DELETE FROM research_project_link WHERE kind = 'notebook' AND recordId = OLD.id;
            END;
            CREATE TRIGGER research_project_link_source_deleted AFTER DELETE ON source BEGIN
                DELETE FROM research_project_link WHERE kind = 'source' AND recordId = OLD.id;
            END;
            """)
        try convertLearningFocusToProject(in: db, now: now)
    }

    /// 3.15 的本期焦点（专题笔记本或出处）→ 一个“其他”类、处于“资料”阶段的项目，并设为当前项目
    static func convertLearningFocusToProject(in db: Database, now: Date = Date()) throws {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key = ?", arguments: [LearningFocus.progressKey]),
              let focus = try? JSONDecoder().decode(LearningFocus.self, from: data) else { return }
        let linkKind: ResearchProjectLink.Kind
        let table: String
        switch focus.kind {
        case .notebook: linkKind = .notebook; table = "notebook"
        case .source: linkKind = .source; table = "source"
        case .project: return
        }
        guard let title = try String.fetchOne(db, sql: "SELECT title FROM \(table) WHERE id = ?", arguments: [focus.id]) else {
            try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [LearningFocus.progressKey])
            return
        }
        var project = ResearchProject(title: title, kind: .other, stage: .material, createdAt: focus.startedAt, updatedAt: now)
        try project.insert(db)
        guard let pid = project.id else { return }
        try db.execute(sql: "INSERT INTO research_project_link(projectId, kind, recordId, position) VALUES (?, ?, ?, 1)",
                       arguments: [pid, linkKind.rawValue, focus.id])
        try db.execute(sql: "INSERT INTO research_project_stage(projectId, stage, at, note) VALUES (?, ?, ?, ?)",
                       arguments: [pid, ResearchProject.Stage.material.rawValue, focus.startedAt, "由 3.15 的本期焦点转来"])
        let current = LearningFocus(kind: .project, id: pid, title: title, startedAt: focus.startedAt)
        try db.execute(sql: "UPDATE app_progress SET payload = ?, updatedAt = ? WHERE key = ?",
                       arguments: [try JSONEncoder().encode(current), now, LearningFocus.progressKey])
    }

    // MARK: 读取

    /// 在研项目（未归档）按截止日期排，无截止日期的排后，再按最近改动；includeArchived 时归档的排最后
    func researchProjects(includeArchived: Bool = false) throws -> [ResearchProject] {
        try writer.read { db in
            try ResearchProject.fetchAll(db, sql: """
                SELECT * FROM research_project \(includeArchived ? "" : "WHERE archivedAt IS NULL")
                ORDER BY archivedAt IS NOT NULL, dueDate IS NULL, dueDate, updatedAt DESC, id DESC
                """)
        }
    }

    func researchProject(id: Int64) throws -> ResearchProject? {
        try writer.read { db in try ResearchProject.fetchOne(db, key: id) }
    }

    /// 某个笔记本或出处所属的项目
    func researchProjects(containing kind: ResearchProjectLink.Kind, recordId: Int64) throws -> [ResearchProject] {
        try writer.read { db in
            try ResearchProject.fetchAll(db, sql: """
                SELECT p.* FROM research_project p JOIN research_project_link l ON l.projectId = p.id
                WHERE l.kind = ? AND l.recordId = ? ORDER BY p.archivedAt IS NOT NULL, p.updatedAt DESC
                """, arguments: [kind.rawValue, recordId])
        }
    }

    static func researchProjectLinks(_ db: Database, projectId: Int64) throws -> [ResearchProjectLink] {
        try Row.fetchAll(db, sql: """
            SELECT l.kind, l.recordId,
                   CASE l.kind WHEN 'notebook' THEN n.title WHEN 'note' THEN i.title ELSE s.title END AS title,
                   CASE l.kind
                     WHEN 'notebook' THEN (SELECT COUNT(*) FROM notebook_block b WHERE b.notebookId = l.recordId AND b.kind = 'highlight')
                     WHEN 'note' THEN (SELECT COUNT(*) FROM idea_note_highlight x WHERE x.noteId = l.recordId)
                     ELSE (SELECT COUNT(*) FROM highlight h WHERE h.sourceId = l.recordId AND h.deletedAt IS NULL) END AS n
            FROM research_project_link l
            LEFT JOIN notebook n ON l.kind = 'notebook' AND n.id = l.recordId
            LEFT JOIN source s ON l.kind = 'source' AND s.id = l.recordId
            LEFT JOIN idea_note i ON l.kind = 'note' AND i.id = l.recordId
            WHERE l.projectId = ? AND (l.kind != 'note' OR i.deletedAt IS NULL)
            ORDER BY CASE l.kind WHEN 'notebook' THEN 0 WHEN 'note' THEN 1 ELSE 2 END, l.position, l.recordId
            """, arguments: [projectId]).compactMap { row in
                guard let kind = ResearchProjectLink.Kind(rawValue: row["kind"]) else { return nil }
                return ResearchProjectLink(projectId: projectId, kind: kind, recordId: row["recordId"],
                                           title: row["title"] ?? "", highlightCount: row["n"] ?? 0)
            }
    }

    func researchProjectLinks(projectId: Int64) throws -> [ResearchProjectLink] {
        try writer.read { db in try Self.researchProjectLinks(db, projectId: projectId) }
    }

    /// 项目全部材料中的摘录（笔记本引用的与出处下的并集，不含已删除）
    static func researchProjectHighlightIDs(_ db: Database, projectId: Int64) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: """
            SELECT b.highlightId FROM research_project_link l
            JOIN notebook_block b ON l.kind = 'notebook' AND b.notebookId = l.recordId AND b.kind = 'highlight'
            JOIN highlight h ON h.id = b.highlightId AND h.deletedAt IS NULL
            WHERE l.projectId = ?
            UNION
            SELECT h.id FROM research_project_link l
            JOIN highlight h ON l.kind = 'source' AND h.sourceId = l.recordId AND h.deletedAt IS NULL
            WHERE l.projectId = ?
            UNION
            SELECT x.highlightId FROM research_project_link l
            JOIN idea_note i ON l.kind = 'note' AND i.id = l.recordId AND i.deletedAt IS NULL
            JOIN idea_note_highlight x ON x.noteId = i.id
            JOIN highlight h ON h.id = x.highlightId AND h.deletedAt IS NULL
            WHERE l.projectId = ?
            """, arguments: [projectId, projectId, projectId]))
    }

    func researchProjectOverview(id: Int64) async throws -> ResearchProjectOverview {
        try await writer.read { db in
            guard let project = try ResearchProject.fetchOne(db, key: id) else { throw ResearchProjectError.missing }
            var o = ResearchProjectOverview(project: project)
            o.links = try Self.researchProjectLinks(db, projectId: id)
            let ids = try Self.researchProjectHighlightIDs(db, projectId: id)
            o.highlightCount = ids.count
            if !ids.isEmpty {
                o.cardCount = try Row.fetchAll(db, sql: "SELECT highlightId FROM card WHERE deletedAt IS NULL AND highlightId IS NOT NULL")
                    .filter { ids.contains($0["highlightId"]) }.count
            }
            let planRows = try Data.fetchAll(db, sql: """
                SELECT payload FROM app_progress WHERE key LIKE 'learning-plan.%'
                  AND json_extract(CAST(payload AS TEXT),'$.link.kind') = ?
                  AND json_extract(CAST(payload AS TEXT),'$.link.recordID') = ?
                  AND json_extract(CAST(payload AS TEXT),'$.completedAt') IS NULL
                  AND json_extract(CAST(payload AS TEXT),'$.cancelledAt') IS NULL
                ORDER BY json_extract(CAST(payload AS TEXT),'$.dueDate'), key LIMIT 50
                """, arguments: [LearningPlanLinkKind.project.rawValue, id])
            o.pendingPlans = planRows.compactMap { try? JSONDecoder().decode(LearningPlan.self, from: $0) }
            let notebookIDs = o.links.filter { $0.kind == .notebook }.map(\.recordId)
            if !notebookIDs.isEmpty {
                let marks = Array(repeating: "?", count: notebookIDs.count).joined(separator: ",")
                let rows = try Data.fetchAll(db, sql: """
                    SELECT payload FROM app_progress WHERE key LIKE 'topic-question.%'
                      AND json_extract(CAST(payload AS TEXT),'$.notebookID') IN (\(marks))
                      AND json_extract(CAST(payload AS TEXT),'$.solvedAt') IS NULL
                    ORDER BY updatedAt DESC, key LIMIT 50
                    """, arguments: StatementArguments(notebookIDs))
                o.openQuestions = rows.compactMap { try? JSONDecoder().decode(TopicQuestion.self, from: $0) }
            }
            o.stages = try Row.fetchAll(db, sql: "SELECT id, stage, at, note FROM research_project_stage WHERE projectId = ? ORDER BY at DESC, id DESC", arguments: [id])
                .compactMap { r in ResearchProject.Stage(rawValue: r["stage"]).map { ResearchProjectStageEvent(id: r["id"], stage: $0, at: r["at"], note: r["note"]) } }
            return o
        }
    }

    /// 一段时间内的阶段变化（学习小结表 4）
    func researchProjectStages(projectId: Int64, start: Date, end: Date) async throws -> [ResearchProjectStageEvent] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, stage, at, note FROM research_project_stage WHERE projectId = ? AND at >= ? AND at < ? ORDER BY at, id",
                             arguments: [projectId, start, end])
                .compactMap { r in ResearchProject.Stage(rawValue: r["stage"]).map { ResearchProjectStageEvent(id: r["id"], stage: $0, at: r["at"], note: r["note"]) } }
        }
    }

    // MARK: 写入

    /// 新建或保存项目；阶段改变时记一条阶段记录
    @discardableResult
    func saveResearchProject(_ project: ResearchProject, now: Date = Date()) throws -> ResearchProject {
        var p = project
        p.title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        p.question = p.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.title.isEmpty else { throw ResearchProjectError.emptyTitle }
        if let w = p.targetWords, w <= 0 { p.targetWords = nil }
        p.updatedAt = now
        return try writer.write { db in
            let previous: ResearchProject?
            if let id = p.id {
                guard let old = try ResearchProject.fetchOne(db, key: id) else { throw ResearchProjectError.missing }
                previous = old
                try p.update(db)
            } else {
                previous = nil
                p.createdAt = now
                try p.insert(db)
            }
            if previous?.stage != p.stage, let id = p.id {
                try db.execute(sql: "INSERT INTO research_project_stage(projectId, stage, at, note) VALUES (?, ?, ?, '')",
                               arguments: [id, p.stage.rawValue, now])
            }
            try Self.refreshProjectFocusTitle(db, project: p)
            return p
        }
    }

    func setResearchProjectStage(id: Int64, stage: ResearchProject.Stage, note: String = "", now: Date = Date()) throws {
        try writer.write { db in
            guard let old = try ResearchProject.fetchOne(db, key: id) else { throw ResearchProjectError.missing }
            guard old.stage != stage else { return }
            try db.execute(sql: "UPDATE research_project SET stage = ?, updatedAt = ? WHERE id = ?", arguments: [stage.rawValue, now, id])
            try db.execute(sql: "INSERT INTO research_project_stage(projectId, stage, at, note) VALUES (?, ?, ?, ?)",
                           arguments: [id, stage.rawValue, now, note.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    /// 归档或恢复；归档的项目若是当前项目，同时取消当前项目
    func setResearchProjectArchived(id: Int64, archived: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE research_project SET archivedAt = ?, updatedAt = ? WHERE id = ?",
                           arguments: [archived ? now : nil, now, id])
            if archived { try Self.clearProjectFocus(db, projectId: id) }
        }
    }

    /// 删除项目本身与关联、阶段记录；笔记本、出处、计划、问题都不动（计划的关联在打开时提示已删除）
    func deleteResearchProject(id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM research_project WHERE id = ?", arguments: [id])
            try Self.clearProjectFocus(db, projectId: id)
        }
    }

    func linkToResearchProject(_ projectId: Int64, kind: ResearchProjectLink.Kind, recordId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            let next = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM research_project_link WHERE projectId = ?", arguments: [projectId]) ?? 0) + 1
            try db.execute(sql: "INSERT OR IGNORE INTO research_project_link(projectId, kind, recordId, position) VALUES (?, ?, ?, ?)",
                           arguments: [projectId, kind.rawValue, recordId, next])
            try db.execute(sql: "UPDATE research_project SET updatedAt = ? WHERE id = ?", arguments: [now, projectId])
        }
    }

    func unlinkFromResearchProject(_ projectId: Int64, kind: ResearchProjectLink.Kind, recordId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM research_project_link WHERE projectId = ? AND kind = ? AND recordId = ?",
                           arguments: [projectId, kind.rawValue, recordId])
            try db.execute(sql: "UPDATE research_project SET updatedAt = ? WHERE id = ?", arguments: [now, projectId])
        }
    }

    private static func clearProjectFocus(_ db: Database, projectId: Int64) throws {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key = ?", arguments: [LearningFocus.progressKey]),
              let focus = try? JSONDecoder().decode(LearningFocus.self, from: data),
              focus.kind == .project, focus.id == projectId else { return }
        try db.execute(sql: "DELETE FROM app_progress WHERE key = ?", arguments: [LearningFocus.progressKey])
    }

    private static func refreshProjectFocusTitle(_ db: Database, project: ResearchProject) throws {
        guard let id = project.id,
              let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key = ?", arguments: [LearningFocus.progressKey]),
              var focus = try? JSONDecoder().decode(LearningFocus.self, from: data),
              focus.kind == .project, focus.id == id, focus.title != project.title else { return }
        focus.title = project.title
        try db.execute(sql: "UPDATE app_progress SET payload = ? WHERE key = ?", arguments: [try JSONEncoder().encode(focus), LearningFocus.progressKey])
    }
}
