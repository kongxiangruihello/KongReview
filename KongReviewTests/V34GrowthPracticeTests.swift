import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V34GrowthPracticeTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from:.init(year:2026,month:10,day:day,hour:hour))! }
    private func schedule(_ db: AppDatabase, at date: Date) throws -> (WeeklySchedule,LearningPlan) {
        let schedule = WeeklySchedule(title:"每周整理",weekday:calendar.component(.weekday,from:date),startsAt:date,lastOccurrence:date)
        let plan = LearningPlan(title:schedule.title,dueDate:date,recurrenceID:schedule.id)
        try db.saveProgress(schedule,key:schedule.key); try db.saveLearningPlan(plan)
        return (schedule,plan)
    }
    func testRecurringCreationIsAtomicAndOldDraftPayloadIsCompatible() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let draft = LearningPlanDraft(plan:.init(title:"整理摘录\n周复盘",dueDate:date(4)),splitLines:true,repeatWeekly:true)
        try db.commitPlanDraft(draft)
        let plans = try await db.planPage(status:.pending), schedules = try await db.weeklySchedules()
        XCTAssertEqual(plans.total,2); XCTAssertEqual(schedules.total,2)
        XCTAssertEqual(Set(plans.items.compactMap(\.recurrenceID)),Set(schedules.items.map(\.id)))
        XCTAssertThrowsError(try db.commitPlanDraft(draft))
        let after = try await db.weeklySchedules(); XCTAssertEqual(after.total,2)
        var raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(draft)) as! [String:Any]; raw.removeValue(forKey:"repeatWeekly")
        XCTAssertNil(try JSONDecoder().decode(LearningPlanDraft.self,from:JSONSerialization.data(withJSONObject:raw)).repeatWeekly)
    }
    func testMissedWeeksProduceOnePendingAndSkipDoesNotImmediatelyRecreate() async throws {
        let db = try AppDatabase(DatabaseQueue()), (schedule,plan) = try schedule(db,at:date(4))
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(25),calendar:calendar),0)
        var pending = try await db.planPage(status:.pending); XCTAssertEqual(pending.total,1)
        try db.changePlanStatus(id:plan.id,status:.cancelled,now:date(25))
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(25,18),calendar:calendar),0)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(32),calendar:calendar),1)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(32),calendar:calendar),0)
        pending = try await db.planPage(status:.pending); XCTAssertEqual(pending.total,1); XCTAssertEqual(pending.items[0].recurrenceID,schedule.id)
        XCTAssertThrowsError(try db.changePlanStatus(id:plan.id,status:.pending))
    }
    func testPauseResumeDoesNotBackfillAndKeepsExistingHistory() async throws {
        let db = try AppDatabase(DatabaseQueue()), (schedule,plan) = try schedule(db,at:date(4))
        try db.finishPlan(.init(original:plan,outcome:.init(gains:"第一次收获")),now:date(4,10))
        try db.setWeeklySchedulePaused(id:schedule.id,paused:true,now:date(5),calendar:calendar)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(25),calendar:calendar),0)
        try db.setWeeklySchedulePaused(id:schedule.id,paused:false,now:date(25),calendar:calendar)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(25,12),calendar:calendar),0)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(32),calendar:calendar),1)
        XCTAssertEqual(try db.progressValue(LearningPlan.self,key:plan.key)?.outcome?.gains,"第一次收获")
    }
    func testRecurrenceUsesCalendarAcrossDST() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"America/New_York")!
        let before = c.date(from:.init(year:2026,month:3,day:1))!, after = c.date(from:.init(year:2026,month:3,day:15,hour:12))!
        let schedule = WeeklySchedule(title:"周日学习",weekday:1,startsAt:before,lastOccurrence:before)
        try db.saveProgress(schedule,key:schedule.key)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:after,calendar:c),1)
        let plans = try await db.planPage(status:.pending)
        XCTAssertEqual(c.component(.hour,from:plans.items[0].dueDate),0); XCTAssertEqual(c.component(.day,from:plans.items[0].dueDate),15)
    }
    func testOutcomesSearchDatesTopicDedupAndDeletedEvidence() async throws {
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"专题"), h = try db.save(Highlight(text:"史料"))
        _ = try db.insertBlocks([.init(notebookId:n.id!,position:1,kind:.highlight,highlightId:h.id),.init(notebookId:n.id!,position:2,kind:.highlight,highlightId:h.id)],into:n.id!,after:nil)
        let plan = LearningPlan(title:"研究成果",link:.init(kind:.notebook,recordID:n.id!,title:n.title)); try db.saveLearningPlan(plan)
        try db.finishPlan(.init(original:plan,outcome:.init(gains:"臺灣歷史的理解",evidence:.init(kind:.highlight,recordID:h.id!,title:h.text))),now:date(18))
        let empty = LearningPlan(title:"仅完成无收获"); try db.saveLearningPlan(empty); try db.finishPlan(.init(original:empty,outcome:.init()),now:date(18))
        let found = try await db.learningOutcomes(query:"台湾",notebookID:n.id,start:date(18),end:date(19)); XCTAssertEqual(found.total,1)
        let excluded = try await db.learningOutcomes(start:date(19)); XCTAssertEqual(excluded.total,0)
        try db.moveToTrash(h)
        let still = try await db.learningOutcomes(); XCTAssertEqual(still.total,1); XCTAssertEqual(still.items[0].outcome?.gains,"臺灣歷史的理解")
        let target = try await db.evidenceTarget(still.items[0].outcome!.evidence!); XCTAssertNil(target.0)
        try db.changePlanStatus(id:plan.id,status:.pending)
        let undone = try await db.learningOutcomes(); XCTAssertEqual(undone.total,0)
    }
    func testOutcomeAndQuestionPaginationAndFacts() async throws {
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"专题")
        for i in 0..<105 {
            let p = LearningPlan(title:"成果 \(i)"); try db.saveLearningPlan(p)
            try db.finishPlan(.init(original:p,outcome:.init(gains:"收获 \(i)")),now:date(18))
            let q = TopicQuestion(notebookID:n.id!,question:"问题 \(i)",answer:"解释",solvedAt:date(18))
            try db.saveTopicQuestion(.init(value:q))
        }
        let first = try await db.learningOutcomes(), last = try await db.learningOutcomes(offset:100)
        XCTAssertEqual(first.total,105); XCTAssertEqual(first.items.count,50); XCTAssertEqual(last.items.count,5); XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with:last.items.map(\.id)))
        let questions = try await db.topicQuestions(notebookID:n.id!,solved:true,offset:100); XCTAssertEqual(questions.total,105); XCTAssertEqual(questions.items.count,5)
        let facts = try await db.periodReviewFacts(window:GrowthPeriod.month.window(containing:date(18),now:date(19),calendar:calendar))
        XCTAssertEqual(facts.completed,105); XCTAssertEqual(facts.outcomes,105); XCTAssertEqual(facts.solvedQuestions,105)
    }
    func testQuestionDraftConflictResolutionAndReopeningPreserveAnswer() async throws {
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"专题")
        let q = TopicQuestion(notebookID:n.id!,question:"为什么？",answer:"原解释")
        try db.saveTopicQuestion(.init(value:q),now:date(18))
        let original = try XCTUnwrap(db.progressValue(TopicQuestion.self,key:q.key))
        var edit = TopicQuestionDraft(value:original,original:original); edit.value.answer = String(repeating:"充分解释",count:2000); edit.value.solvedAt = date(18)
        try db.saveProgress(edit,key:edit.key); try db.saveTopicQuestion(edit,now:date(18,12))
        XCTAssertNil(try db.progressValue(TopicQuestionDraft.self,key:edit.key))
        XCTAssertThrowsError(try db.saveTopicQuestion(edit))
        let solved = try XCTUnwrap(db.progressValue(TopicQuestion.self,key:q.key))
        var reopen = TopicQuestionDraft(value:solved,original:solved); reopen.value.solvedAt = nil
        try db.saveTopicQuestion(reopen)
        let pending = try await db.topicQuestions(notebookID:n.id!,solved:false); XCTAssertEqual(pending.total,1); XCTAssertEqual(pending.items[0].answer,edit.value.answer)
        var invalid = TopicQuestion(notebookID:n.id!,question:"需要解答",solvedAt:date(18))
        XCTAssertThrowsError(try db.saveTopicQuestion(.init(value:invalid)))
        invalid.solvedAt = nil; invalid.question = " \n "
        XCTAssertThrowsError(try db.saveTopicQuestion(.init(value:invalid)))
    }
    func testQuestionDraftBackupAndRecurringCursorRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let suite = UUID().uuidString, db = try AppDatabase(DatabaseQueue())
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let n = try db.createNotebook(title:"备份专题"), (schedule,plan) = try schedule(db,at:date(4))
        try db.changePlanStatus(id:plan.id,status:.cancelled)
        XCTAssertEqual(try db.materializeWeeklyPlans(now:date(18),calendar:calendar),1)
        let draft = TopicQuestionDraft(value:.init(notebookID:n.id!,question:"备份草稿",answer:"未保存解释")); try db.saveProgress(draft,key:draft.key)
        let q = TopicQuestion(notebookID:n.id!,question:"已解决",answer:"答案",solvedAt:date(18)); try db.saveTopicQuestion(.init(value:q))
        let backup = dir.appendingPathComponent("test.kongreviewbackup")
        try FullBackupService.create(db:db,draftURL:nil,defaults:prefs,destination:backup)
        let prepared = try FullBackupService.prepare(url:backup); defer { prepared.cleanup() }
        let restored = try AppDatabase(DatabaseQueue()); _ = try FullBackupService.restore(prepared,db:restored,draftURL:nil,defaults:prefs,safetyDirectory:dir)
        XCTAssertEqual(try restored.progressValue(TopicQuestionDraft.self,key:draft.key),draft)
        XCTAssertEqual(try restored.progressValue(WeeklySchedule.self,key:schedule.key)?.lastOccurrence,date(18))
        XCTAssertEqual(try restored.materializeWeeklyPlans(now:date(18),calendar:calendar),0)
        let pending = try await restored.planPage(status:.pending); XCTAssertEqual(pending.total,1)
        try restored.saveTopicQuestion(draft)
        let questions = try await restored.topicQuestions(notebookID:n.id!,solved:false); XCTAssertEqual(questions.total,1)
    }
    @MainActor func testHomeEntrypointsAndGrowthReturnStateRemainIndependent() throws {
        let db = try AppDatabase(DatabaseQueue()), store = LibraryStore(db:db,positionDefaults:nil)
        store.study.deck = "某个牌组"
        store.journeyNavigation.outcomesPage = 2; store.journeyNavigation.outcomesQuery = "收获"
        store.openCardsHome(); XCTAssertEqual(store.selection,.cards); XCTAssertNil(store.study.deck)
        store.openTodayReview(); XCTAssertEqual(store.selection,.review)
        XCTAssertEqual(store.journeyNavigation.outcomesPage,2); XCTAssertEqual(store.journeyNavigation.outcomesQuery,"收获")
        store.journeyNavigation.questionPages[42] = 3
        store.openLearningPlans(); XCTAssertEqual(store.selection,.growth); XCTAssertEqual(store.journeyNavigation.questionPages[42],3)
    }
}
