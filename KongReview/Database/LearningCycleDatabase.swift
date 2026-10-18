import Foundation
import GRDB
import KongReviewCore

struct PlanEvidence: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable { case highlight, block, card }
    var kind: Kind
    var recordID: Int64
    var title: String
    var id: String { "\(kind.rawValue).\(recordID)" }
}
struct PlanOutcome: Codable, Equatable, Sendable {
    var gains = ""
    var evidence: PlanEvidence?
}
struct PlanOutcomeDraft: Codable, Equatable, Sendable {
    var original: LearningPlan
    var outcome: PlanOutcome
    var key: String { "plan-outcome-draft.\(original.id.uuidString)" }
}
enum WeeklyPlanFilter: String, CaseIterable, Identifiable {
    case completed, delayed, cancelled
    var id: String { rawValue }
    var title: String { switch self { case .completed: "已完成"; case .delayed: "待处理／延期"; case .cancelled: "已取消" } }
}
enum WeeklyDecision: String, Codable { case continued, adjusted, dropped }
struct PlanReviewDecision: Codable, Sendable {
    var planID: UUID
    var title: String
    var weekKey: String
    var decision: WeeklyDecision
    var at: Date
    var previousDue: Date
    var nextDue: Date?
    var key: String { "plan-review.\(weekKey).\(planID.uuidString)" }
}
struct TopicTimelineEntry: Identifiable, Sendable {
    var id: String
    var at: Date
    var kind: String
    var title: String
    var target: GlobalSearchTarget?
}
struct TopicCardEdit: Codable, Sendable {
    var id = UUID()
    var cardID: Int64
    var notebookIDs: [Int64]
    var at: Date
    var title: String
}
extension AppDatabase {
    /// Patch just the goals so editing today's arrangement never overwrites the day's reflection.
    func saveDailyArrangement(date: Date, highlights: Int, cards: Int, calendar: Calendar = .current) throws {
        let key = GrowthPeriod.day.window(containing:date,now:date,calendar:calendar).key
        try writer.write { db in
            var value = try Self.readProgress(GrowthReflection.self,key:key,in:db) ?? .init()
            value.goalHighlights = min(100000,max(0,highlights)); value.goalCards = min(100000,max(0,cards))
            try Self.putProgress(value,key:key,in:db)
        }
    }
    func finishPlan(_ draft: PlanOutcomeDraft, now: Date = Date()) throws {
        try writer.write { db in
            guard var plan = try Self.readProgress(LearningPlan.self,key:draft.original.key,in:db), plan == draft.original else { throw JourneyError.changedPlan }
            // Completion is idempotent and editing a result preserves its original completion date.
            guard plan.cancelledAt == nil else { throw JourneyError.changedPlan }
            plan.completedAt = plan.completedAt ?? now
            plan.outcome = draft.outcome
            try Self.putProgress(plan,key:plan.key,in:db)
            try db.execute(sql:"DELETE FROM app_progress WHERE key=?",arguments:[draft.key])
        }
    }
    func evidenceChoices(kind: PlanEvidence.Kind, query: String, offset: Int = 0) async throws -> GrowthPage<PlanEvidence> {
        try await writer.read { db in
            let column = kind == .card ? "front" : "text"
            let table = kind == .highlight ? "highlight" : kind == .card ? "card" : "notebook_block"
            let active = kind == .block ? "kind='text'" : "deletedAt IS NULL"
            let from = " FROM \(table) WHERE \(active) AND instr(kr_fold(\(column)),kr_fold(?))>0"
            let count = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from,arguments:[query]) ?? 0
            let rows = try Row.fetchAll(db,sql:"SELECT id,\(column) AS text" + from + " ORDER BY id DESC LIMIT 50 OFFSET ?",arguments:[query,max(0,offset)])
            return .init(items:rows.map { .init(kind:kind,recordID:$0["id"],title:String(($0["text"] as String).prefix(160))) },total:count)
        }
    }
    func evidenceTarget(_ evidence: PlanEvidence) async throws -> (GlobalSearchTarget?, Int64?) {
        try await writer.read { db in
            if evidence.kind != .block {
                let table = evidence.kind == .card ? "card" : "highlight"
                let id = try Int64.fetchOne(db,sql:"SELECT id FROM \(table) WHERE id=? AND deletedAt IS NULL",arguments:[evidence.recordID])
                return (id.map { .init(kind:evidence.kind == .card ? .card : .highlight,recordID:$0) },nil)
            }
            return (nil,try Int64.fetchOne(db,sql:"SELECT notebookId FROM notebook_block WHERE id=?",arguments:[evidence.recordID]))
        }
    }
    /// Current plan status, bounded by the selected week's end; not a historical status reconstruction.
    func weeklyPlans(window: GrowthWindow, filter: WeeklyPlanFilter, offset: Int = 0) async throws -> GrowthPage<LearningPlan> {
        try await writer.read { db in
            let completed = "json_extract(CAST(payload AS TEXT),'$.completedAt')", cancelled = "json_extract(CAST(payload AS TEXT),'$.cancelledAt')", due = "json_extract(CAST(payload AS TEXT),'$.dueDate')"
            let condition: String
            var args: [any DatabaseValueConvertible]
            switch filter {
            case .completed: condition = "\(completed)>=? AND \(completed)<? AND \(cancelled) IS NULL"; args = [window.start.timeIntervalSinceReferenceDate,window.end.timeIntervalSinceReferenceDate]
            case .cancelled: condition = "\(cancelled)>=? AND \(cancelled)<?"; args = [window.start.timeIntervalSinceReferenceDate,window.end.timeIntervalSinceReferenceDate]
            case .delayed: condition = "\(completed) IS NULL AND \(cancelled) IS NULL AND \(due)<?"; args = [window.end.timeIntervalSinceReferenceDate]
            }
            let from = " FROM app_progress WHERE key LIKE 'learning-plan.%' AND " + condition
            let count = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from,arguments:StatementArguments(args)) ?? 0
            args.append(max(0,offset))
            let rows = try Data.fetchAll(db,sql:"SELECT payload" + from + " ORDER BY \(due),key LIMIT 50 OFFSET ?",arguments:StatementArguments(args))
            return .init(items:try rows.map { try JSONDecoder().decode(LearningPlan.self,from:$0) },total:count)
        }
    }
    func weeklyDecisions(window: GrowthWindow, offset: Int = 0) async throws -> GrowthPage<PlanReviewDecision> {
        try await writer.read { db in
            let from = " FROM app_progress WHERE key LIKE 'plan-review.%' AND json_extract(CAST(payload AS TEXT),'$.weekKey')=?"
            let count = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from,arguments:[window.key]) ?? 0
            let rows = try Data.fetchAll(db,sql:"SELECT payload" + from + " ORDER BY updatedAt DESC,key LIMIT 50 OFFSET ?",arguments:[window.key,max(0,offset)])
            return .init(items:try rows.map { try JSONDecoder().decode(PlanReviewDecision.self,from:$0) },total:count)
        }
    }
    func reviewPlan(_ original: LearningPlan, window: GrowthWindow, decision: WeeklyDecision, due: Date, now: Date = Date()) throws {
        try writer.write { db in
            guard var plan = try Self.readProgress(LearningPlan.self,key:original.key,in:db), plan == original else { throw JourneyError.changedPlan }
            guard plan.completedAt == nil else { throw JourneyError.changedPlan }
            let record = PlanReviewDecision(planID:plan.id,title:plan.title,weekKey:window.key,decision:decision,at:now,previousDue:plan.dueDate,nextDue:decision == .dropped ? nil : due)
            if decision == .dropped { plan.cancelledAt = now }
            else { plan.cancelledAt = nil; plan.dueDate = due }
            try Self.putProgress(plan,key:plan.key,in:db)
            try Self.putProgress(record,key:record.key,in:db)
        }
    }
    static func recordTopicCardEdit(before: Card, after: Card, in db: Database) throws {
        guard let id = after.id, before.deletedAt == nil, after.deletedAt == nil,
              before.front != after.front || before.back != after.back || before.fields != after.fields || before.sections != after.sections || before.noteType != after.noteType else { return }
        let ids = try Int64.fetchAll(db,sql:"SELECT DISTINCT notebookId FROM notebook_block WHERE highlightId IN (?,?)",arguments:[before.highlightId,after.highlightId])
        guard !ids.isEmpty else { return }
        let edit = TopicCardEdit(cardID:id,notebookIDs:ids,at:after.updatedAt,title:after.front)
        try Self.putProgress(edit,key:"topic-card-edit.\(edit.id.uuidString)",in:db)
    }
    func topicTimeline(notebookID: Int64, offset: Int = 0) async throws -> GrowthPage<TopicTimelineEntry> {
        try await writer.read { db in
            // SQL pages the union; duplicate excerpt references do not duplicate its creation event.
            let sql = """
                WITH members AS (SELECT DISTINCT highlightId FROM notebook_block WHERE notebookId=? AND highlightId IS NOT NULL), events AS (
                SELECT 'h.'||h.id AS id,h.createdAt AS at,'新增摘录' AS kind,h.text AS title,'highlight' AS targetKind,h.id AS targetID FROM highlight h JOIN members m ON m.highlightId=h.id WHERE h.deletedAt IS NULL
                UNION ALL
                SELECT 'n.'||b.id,b.updatedAt,'笔记／批注（最近修改）',CASE WHEN b.kind='text' THEN b.text ELSE b.note END,NULL,NULL FROM notebook_block b WHERE b.notebookId=? AND (b.kind='text' OR trim(coalesce(b.note,''))!='')
                UNION ALL
                SELECT 'hn.'||h.id,h.updatedAt,'摘录按语（条目最近修改）',h.note,'highlight',h.id FROM highlight h JOIN members m ON m.highlightId=h.id WHERE h.deletedAt IS NULL AND trim(coalesce(h.note,''))!=''
                UNION ALL
                SELECT p.key,datetime(json_extract(CAST(p.payload AS TEXT),'$.at')+978307200,'unixepoch'),'修改记忆卡',json_extract(CAST(p.payload AS TEXT),'$.title'),'card',c.id FROM app_progress p LEFT JOIN card c ON c.id=json_extract(CAST(p.payload AS TEXT),'$.cardID') AND c.deletedAt IS NULL WHERE p.key LIKE 'topic-card-edit.%' AND EXISTS(SELECT 1 FROM json_each(json_extract(CAST(p.payload AS TEXT),'$.notebookIDs')) WHERE value=?)
                UNION ALL
                SELECT p.key,datetime(json_extract(CAST(p.payload AS TEXT),'$.completedAt')+978307200,'unixepoch'),'完成计划',json_extract(CAST(p.payload AS TEXT),'$.title')||CASE WHEN coalesce(json_extract(CAST(p.payload AS TEXT),'$.outcome.gains'),'')!='' THEN char(10)||json_extract(CAST(p.payload AS TEXT),'$.outcome.gains') ELSE '' END,NULL,NULL FROM app_progress p WHERE p.key LIKE 'learning-plan.%' AND json_extract(CAST(p.payload AS TEXT),'$.completedAt') IS NOT NULL AND json_extract(CAST(p.payload AS TEXT),'$.cancelledAt') IS NULL AND (
                  (json_extract(CAST(p.payload AS TEXT),'$.link.kind')='notebook' AND json_extract(CAST(p.payload AS TEXT),'$.link.recordID')=?) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.link.kind')='card' AND json_extract(CAST(p.payload AS TEXT),'$.link.recordID') IN (SELECT id FROM card WHERE highlightId IN (SELECT highlightId FROM members))) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='highlight' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT highlightId FROM members)) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='card' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT id FROM card WHERE highlightId IN (SELECT highlightId FROM members))) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='block' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT id FROM notebook_block WHERE notebookId=?))
                ))
                """
            let args: [any DatabaseValueConvertible] = [notebookID,notebookID,notebookID,notebookID,notebookID]
            let count = try Int.fetchOne(db,sql:sql + " SELECT COUNT(*) FROM events",arguments:StatementArguments(args)) ?? 0
            let rows = try Row.fetchAll(db,sql:sql + " SELECT * FROM events ORDER BY at DESC,id LIMIT 50 OFFSET ?",arguments:StatementArguments(args + [max(0,offset)]))
            return .init(items:rows.map { row in
                let kind: String? = row["targetKind"], id: Int64? = row["targetID"]
                return .init(id:row["id"],at:row["at"],kind:row["kind"],title:Markdown.plainText(fromHTML:Card.renderHTML(row["title"])),target:id.flatMap { id in kind.flatMap(GlobalSearchKind.init(rawValue:)).map { .init(kind:$0,recordID:id) } })
            },total:count)
        }
    }
}
