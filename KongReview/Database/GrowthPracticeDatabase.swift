import Foundation
import GRDB

struct WeeklySchedule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var weekday: Int
    var startsAt: Date
    var lastOccurrence: Date
    var paused = false
    var link: LearningPlanLink?
    var key: String { "weekly-schedule.\(id.uuidString)" }
}
/// 3.4 的专题问题（存于 app_progress）。4.1.1 起迁入问题簿，只在迁移时读取。
struct TopicQuestion: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var notebookID: Int64
    var question = ""
    var answer = ""
    var evidence: PlanEvidence?
    var createdAt = Date()
    var updatedAt = Date()
    var solvedAt: Date?
    var key: String { "topic-question.\(id.uuidString)" }
}
/// 3.4 的专题问题草稿，4.1.1 迁移时转为 QuestionDraft
struct TopicQuestionDraft: Codable, Equatable, Identifiable, Sendable {
    var value: TopicQuestion
    var original: TopicQuestion?
    var id: UUID { value.id }
    var key: String { "question-draft.\(id.uuidString)" }
}
struct PeriodReviewFacts: Sendable {
    var completed: Int
    var outcomes: Int
    var solvedQuestions: Int
}
enum GrowthPracticeError: LocalizedError {
    case changed, emptyQuestion, missingNotebook, missingAnswer, pendingOccurrence
    var errorDescription: String? {
        switch self {
        case .pendingOccurrence: "这个重复安排已有待办，请先完成或跳过该项，再恢复旧任务。"
        case .changed: "记录已被其他操作更新，输入仍保留，请重新读取后再编辑。"
        case .emptyQuestion: "请填写需要解决的问题。"
        case .missingNotebook: "专题已删除，不能保存到这个专题。"
        case .missingAnswer: "请先补充答案或解释，再标为解决。"
        }
    }
}
extension AppDatabase {
    func weeklySchedules(offset: Int = 0) async throws -> GrowthPage<WeeklySchedule> {
        try await writer.read { db in
            let from = " FROM app_progress WHERE key LIKE 'weekly-schedule.%'"
            let total = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from) ?? 0
            let rows = try Data.fetchAll(db,sql:"SELECT payload" + from + " ORDER BY updatedAt DESC,key LIMIT 50 OFFSET ?",arguments:[max(0,offset)])
            return .init(items:try rows.map { try JSONDecoder().decode(WeeklySchedule.self,from:$0) },total:total)
        }
    }
    func setWeeklySchedulePaused(id: UUID, paused: Bool, now: Date = Date(), calendar: Calendar = .current) throws {
        try writer.write { db in
            let key = "weekly-schedule.\(id.uuidString)"
            guard var schedule = try Self.readProgress(WeeklySchedule.self,key:key,in:db) else { throw GrowthPracticeError.changed }
            if schedule.paused && !paused {
                // Do not backfill the paused interval. The next occurrence must be a future date.
                schedule.lastOccurrence = max(schedule.lastOccurrence,calendar.startOfDay(for:now))
            }
            schedule.paused = paused
            try Self.putProgress(schedule,key:key,in:db)
        }
    }
    /// Materialize at most the most recent due occurrence; never backfill missed weeks.
    @discardableResult func materializeWeeklyPlans(now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        try writer.write { db in
            let rows = try Data.fetchAll(db,sql:"SELECT payload FROM app_progress WHERE key LIKE 'weekly-schedule.%' AND json_extract(CAST(payload AS TEXT),'$.paused')=0")
            var count = 0
            let today = calendar.startOfDay(for:now)
            for data in rows {
                var schedule = try JSONDecoder().decode(WeeklySchedule.self,from:data)
                guard (1...7).contains(schedule.weekday), today >= calendar.startOfDay(for:schedule.startsAt) else { continue }
                let distance = (calendar.component(.weekday,from:today)-schedule.weekday+7)%7
                guard let occurrence = calendar.date(byAdding:.day,value:-distance,to:today), occurrence > calendar.startOfDay(for:schedule.lastOccurrence) else { continue }
                let pending = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM app_progress WHERE key LIKE 'learning-plan.%' AND json_extract(CAST(payload AS TEXT),'$.recurrenceID')=? AND json_extract(CAST(payload AS TEXT),'$.completedAt') IS NULL AND json_extract(CAST(payload AS TEXT),'$.cancelledAt') IS NULL",arguments:[schedule.id.uuidString]) ?? 0
                schedule.lastOccurrence = occurrence
                if pending == 0 {
                    let plan = LearningPlan(title:schedule.title,dueDate:occurrence,createdAt:now,recurrenceID:schedule.id,link:schedule.link)
                    try Self.putProgress(plan,key:plan.key,in:db); count += 1
                }
                try Self.putProgress(schedule,key:schedule.key,in:db)
            }
            return count
        }
    }
    private static func outcomeWhere(query: String, notebookID: Int64?, start: Date?, end: Date?) -> (String,[any DatabaseValueConvertible]) {
        let value = "CAST(p.payload AS TEXT)"
        var conditions = ["p.key LIKE 'learning-plan.%'", "json_extract(\(value),'$.completedAt') IS NOT NULL", "json_extract(\(value),'$.cancelledAt') IS NULL", "(trim(coalesce(json_extract(\(value),'$.outcome.gains'),''))!='' OR json_extract(\(value),'$.outcome.evidence') IS NOT NULL)"]
        var args: [any DatabaseValueConvertible] = []
        if !query.isEmpty { conditions.append("instr(kr_fold(kr_search_plain(coalesce(json_extract(\(value),'$.title'),'')||char(10)||coalesce(json_extract(\(value),'$.outcome.gains'),''))),kr_fold(?))>0"); args.append(query) }
        if let start { conditions.append("json_extract(\(value),'$.completedAt')>=?"); args.append(start.timeIntervalSinceReferenceDate) }
        if let end { conditions.append("json_extract(\(value),'$.completedAt')<?"); args.append(end.timeIntervalSinceReferenceDate) }
        if let notebookID {
            conditions.append("""
                ((json_extract(\(value),'$.link.kind')='notebook' AND json_extract(\(value),'$.link.recordID')=?) OR
                (json_extract(\(value),'$.link.kind')='card' AND json_extract(\(value),'$.link.recordID') IN (SELECT c.id FROM card c JOIN notebook_block b ON b.highlightId=c.highlightId WHERE b.notebookId=?)) OR
                (json_extract(\(value),'$.outcome.evidence.kind')='highlight' AND json_extract(\(value),'$.outcome.evidence.recordID') IN (SELECT highlightId FROM notebook_block WHERE notebookId=?)) OR
                (json_extract(\(value),'$.outcome.evidence.kind')='block' AND json_extract(\(value),'$.outcome.evidence.recordID') IN (SELECT id FROM notebook_block WHERE notebookId=?)) OR
                (json_extract(\(value),'$.outcome.evidence.kind')='card' AND json_extract(\(value),'$.outcome.evidence.recordID') IN (SELECT c.id FROM card c JOIN notebook_block b ON b.highlightId=c.highlightId WHERE b.notebookId=?)))
                """)
            args += [notebookID,notebookID,notebookID,notebookID,notebookID]
        }
        return (" FROM app_progress p WHERE " + conditions.joined(separator:" AND "),args)
    }
    func learningOutcomes(query: String = "", notebookID: Int64? = nil, start: Date? = nil, end: Date? = nil, offset: Int = 0) async throws -> GrowthPage<LearningPlan> {
        try await writer.read { db in
            let (from,args) = Self.outcomeWhere(query:query,notebookID:notebookID,start:start,end:end)
            let total = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from,arguments:StatementArguments(args)) ?? 0
            let rows = try Data.fetchAll(db,sql:"SELECT p.payload" + from + " ORDER BY json_extract(CAST(p.payload AS TEXT),'$.completedAt') DESC,p.key LIMIT 50 OFFSET ?",arguments:StatementArguments(args+[max(0,offset)]))
            return .init(items:try rows.map { try JSONDecoder().decode(LearningPlan.self,from:$0) },total:total)
        }
    }
    func periodReviewFacts(window: GrowthWindow) async throws -> PeriodReviewFacts {
        try await writer.read { db in
            let (from,args) = Self.outcomeWhere(query:"",notebookID:nil,start:window.start,end:window.end)
            let outcomes = try Int.fetchOne(db,sql:"SELECT COUNT(*)" + from,arguments:StatementArguments(args)) ?? 0
            let completed = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM app_progress WHERE key LIKE 'learning-plan.%' AND json_extract(CAST(payload AS TEXT),'$.cancelledAt') IS NULL AND json_extract(CAST(payload AS TEXT),'$.completedAt')>=? AND json_extract(CAST(payload AS TEXT),'$.completedAt')<?",arguments:[window.start.timeIntervalSinceReferenceDate,window.end.timeIntervalSinceReferenceDate]) ?? 0
            // 4.1.1：改从问题簿读；迁移保留了原解决日期，前后数字一致
            let solved = try Self.questionsSolved(db,start:window.start,end:window.end)
            return .init(completed:completed,outcomes:outcomes,solvedQuestions:solved)
        }
    }
}
