import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V33LearningCycleTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from:.init(year:2026,month:10,day:day,hour:hour))! }
    func testDailyGoalsPreserveReflectionClampAndSeparateDates() throws {
        let db = try AppDatabase(DatabaseQueue())
        let key = GrowthPeriod.day.window(containing:date(18),calendar:calendar).key
        try db.saveProgress(GrowthReflection(gains:"已写的收获",challenges:"困难",nextSteps:"下一步"),key:key)
        try db.saveDailyArrangement(date:date(18,23),highlights:-9,cards:100001,calendar:calendar)
        let value = try XCTUnwrap(db.progressValue(GrowthReflection.self,key:key))
        XCTAssertEqual(value.gains,"已写的收获"); XCTAssertEqual(value.nextSteps,"下一步"); XCTAssertEqual(value.goalHighlights,0); XCTAssertEqual(value.goalCards,100000)
        try db.saveDailyArrangement(date:date(19),highlights:5,cards:10,calendar:calendar)
        XCTAssertEqual(try db.progressValue(GrowthReflection.self,key:key),value)
        let other = GrowthPeriod.day.window(containing:date(19),calendar:calendar).key
        XCTAssertEqual(try db.progressValue(GrowthReflection.self,key:other)?.goalCards,10)
    }
    func testCompletionOutcomePersistsAndEditingDoesNotMoveCompletionDate() async throws {
        let db = try AppDatabase(DatabaseQueue()), plan = LearningPlan(title:"完成史料核对")
        try db.saveLearningPlan(plan)
        let h = try db.save(Highlight(text:"可追溯史料"))
        let draft = PlanOutcomeDraft(original:plan,outcome:.init(gains:String(repeating:"长篇收获。",count:1000),evidence:.init(kind:.highlight,recordID:h.id!,title:h.text)))
        try db.saveProgress(draft,key:draft.key); try db.finishPlan(draft,now:date(18,12))
        XCTAssertNil(try db.progressValue(PlanOutcomeDraft.self,key:draft.key))
        let saved = try XCTUnwrap(db.progressValue(LearningPlan.self,key:plan.key))
        XCTAssertEqual(saved.outcome,draft.outcome); XCTAssertEqual(saved.completedAt,date(18,12))
        XCTAssertThrowsError(try db.finishPlan(draft,now:date(19)))
        var edit = PlanOutcomeDraft(original:saved,outcome:saved.outcome!); edit.outcome.gains += "补充"
        try db.finishPlan(edit,now:date(20))
        let daily = try await db.learningPlans(completed:true,start:date(18),end:date(19))
        XCTAssertEqual(daily.total,1); XCTAssertEqual(daily.items[0].completedAt,date(18,12)); XCTAssertTrue(daily.items[0].outcome!.gains.hasSuffix("补充"))
        try db.moveToTrash(h)
        let target = try await db.evidenceTarget(draft.outcome.evidence!); XCTAssertNil(target.0); XCTAssertNil(target.1)
        XCTAssertNotNil(try db.progressValue(LearningPlan.self,key:plan.key)?.outcome?.evidence)
    }
    func testOutcomeDraftSurvivesConflictingCancellationAndOldPayloadDecodes() throws {
        let db = try AppDatabase(DatabaseQueue()), plan = LearningPlan(title:"原计划")
        try db.saveLearningPlan(plan)
        let draft = PlanOutcomeDraft(original:plan,outcome:.init(gains:"不要丢失")); try db.saveProgress(draft,key:draft.key)
        try db.changePlanStatus(id:plan.id,status:.cancelled)
        XCTAssertThrowsError(try db.finishPlan(draft))
        XCTAssertEqual(try db.progressValue(PlanOutcomeDraft.self,key:draft.key),draft)
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]; object.removeValue(forKey:"outcome")
        XCTAssertNil(try JSONDecoder().decode(LearningPlan.self,from:JSONSerialization.data(withJSONObject:object)).outcome)
    }
    func testWeeklyBoundariesDecisionsAndStaleReviewProtection() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let window = GrowthPeriod.week.window(containing:date(14),now:date(19),calendar:calendar)
        let delayed = LearningPlan(title:"上期延期",dueDate:date(10)), future = LearningPlan(title:"下周",dueDate:date(19)), completed = LearningPlan(title:"当周完成",dueDate:date(13)), cancelled = LearningPlan(title:"当周取消",dueDate:date(14))
        for p in [delayed,future,completed,cancelled] { try db.saveLearningPlan(p) }
        try db.finishPlan(.init(original:completed,outcome:.init(gains:"已理解")),now:date(12))
        try db.changePlanStatus(id:cancelled.id,status:.cancelled,now:date(18,23))
        let pending = try await db.weeklyPlans(window:window,filter:.delayed), done = try await db.weeklyPlans(window:window,filter:.completed), dropped = try await db.weeklyPlans(window:window,filter:.cancelled)
        XCTAssertEqual(pending.items.map(\.id),[delayed.id]); XCTAssertEqual(done.items.map(\.id),[completed.id]); XCTAssertEqual(dropped.items.map(\.id),[cancelled.id])
        try db.reviewPlan(delayed,window:window,decision:.continued,due:date(19),now:date(18))
        XCTAssertThrowsError(try db.reviewPlan(delayed,window:window,decision:.dropped,due:date(19)))
        let empty = try await db.weeklyPlans(window:window,filter:.delayed); XCTAssertEqual(empty.total,0)
        let record = try XCTUnwrap(db.progressValue(PlanReviewDecision.self,key:"plan-review.\(window.key).\(delayed.id.uuidString)"))
        XCTAssertEqual(record.decision,.continued); XCTAssertEqual(record.previousDue,date(10)); XCTAssertEqual(record.nextDue,date(19))
        let savedCancelled = try XCTUnwrap(db.progressValue(LearningPlan.self,key:cancelled.key))
        try db.reviewPlan(savedCancelled,window:window,decision:.adjusted,due:date(21))
        XCTAssertNil(try db.progressValue(LearningPlan.self,key:cancelled.key)?.cancelledAt)
    }
    func testTimelineDedupChronologyEditRetentionAndPlanAssociation() async throws {
        let db = try AppDatabase(DatabaseQueue()), notebook = try db.createNotebook(title:"专题")
        let h = try db.save(Highlight(text:"摘录",note:"摘录按语",createdAt:date(1)))
        _ = try db.insertBlocks([.init(notebookId:notebook.id!,position:1,kind:.highlight,highlightId:h.id),.init(notebookId:notebook.id!,position:2,kind:.highlight,highlightId:h.id),.init(notebookId:notebook.id!,position:3,kind:.text,text:"自己的笔记")],into:notebook.id!,after:nil)
        var c = try db.save(Card(front:"问题",back:"旧答案",highlightId:h.id))
        c.back = "新答案"; c = try db.save(c)
        c.deck = "移牌组"; c = try db.save(c)
        let plan = LearningPlan(title:"专题学习计划",link:.init(kind:.notebook,recordID:notebook.id!,title:notebook.title)); try db.saveLearningPlan(plan)
        try db.finishPlan(.init(original:plan,outcome:.init(gains:"专题收获")),now:date(18))
        var page = try await db.topicTimeline(notebookID:notebook.id!)
        XCTAssertEqual(page.items.filter { $0.kind == "新增摘录" }.count,1)
        XCTAssertEqual(page.items.filter { $0.kind == "修改记忆卡" }.count,1)
        XCTAssertTrue(page.items.contains { $0.kind == "完成计划" && $0.title.contains("专题收获") })
        XCTAssertEqual(page.items.map(\.at),page.items.map(\.at).sorted(by:>))
        try db.deleteCards([c.id!]); page = try await db.topicTimeline(notebookID:notebook.id!)
        XCTAssertNil(page.items.first { $0.kind == "修改记忆卡" }?.target)
        XCTAssertEqual(page.items.filter { $0.kind == "修改记忆卡" }.count,1)
    }
    func testEvidenceTimelineAndWeeklyPaginationOverFifty() async throws {
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"大量资料")
        for i in 0..<105 {
            let h = try db.save(Highlight(text:"资料 \(i)"))
            _ = try db.insertBlocks([.init(notebookId:n.id!,position:Double(i),kind:.highlight,highlightId:h.id)],into:n.id!,after:nil)
            try db.saveLearningPlan(.init(title:"计划 \(i)",dueDate:date(1)))
        }
        let evidence = try await db.evidenceChoices(kind:.highlight,query:"资料",offset:100); XCTAssertEqual(evidence.total,105); XCTAssertEqual(evidence.items.count,5)
        let a = try await db.topicTimeline(notebookID:n.id!), b = try await db.topicTimeline(notebookID:n.id!,offset:100)
        XCTAssertEqual(a.total,105); XCTAssertEqual(a.items.count,50); XCTAssertEqual(b.items.count,5); XCTAssertTrue(Set(a.items.map(\.id)).isDisjoint(with:b.items.map(\.id)))
        let week = GrowthPeriod.week.window(containing:date(14),now:date(19),calendar:calendar)
        let last = try await db.weeklyPlans(window:week,filter:.delayed,offset:100); XCTAssertEqual(last.total,105); XCTAssertEqual(last.items.count,5)
        let block = try db.insertBlocks([.init(notebookId:n.id!,position:106,kind:.text,text:"独立笔记")],into:n.id!,after:nil)[0]
        let notes = try await db.evidenceChoices(kind:.block,query:"独立"); XCTAssertEqual(notes.total,1)
        let target = try await db.evidenceTarget(notes.items[0]); XCTAssertEqual(target.1,n.id)
        try db.deleteBlocks([block.id!]); let missing = try await db.evidenceTarget(notes.items[0]); XCTAssertNil(missing.1)
    }
    func testFullBackupRestoresOutcomesDraftGoalsAndTimeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let suite = UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"备份专题"), h = try db.save(Highlight(text:"备份摘录"))
        _ = try db.insertBlocks([.init(notebookId:n.id!,position:1,kind:.highlight,highlightId:h.id)],into:n.id!,after:nil)
        var card = try db.save(Card(front:"问题",highlightId:h.id)); card.back = "新增答案"; _ = try db.save(card)
        let p = LearningPlan(title:"完成的计划",link:.init(kind:.notebook,recordID:n.id!,title:n.title)); try db.saveLearningPlan(p)
        try db.finishPlan(.init(original:p,outcome:.init(gains:"备份收获")),now:date(18))
        let pending = LearningPlan(title:"未完成"); try db.saveLearningPlan(pending)
        let draft = PlanOutcomeDraft(original:pending,outcome:.init(gains:"长篇草稿")); try db.saveProgress(draft,key:draft.key)
        try db.saveDailyArrangement(date:date(18),highlights:12,cards:20,calendar:calendar)
        let url = dir.appendingPathComponent("test.kongreviewbackup")
        try FullBackupService.create(db:db,draftURL:nil,defaults:prefs,destination:url)
        let prepared = try FullBackupService.prepare(url:url); defer { prepared.cleanup() }
        let restored = try AppDatabase(DatabaseQueue()); _ = try FullBackupService.restore(prepared,db:restored,draftURL:nil,defaults:prefs,safetyDirectory:dir)
        XCTAssertEqual(try restored.progressValue(PlanOutcomeDraft.self,key:draft.key),draft)
        XCTAssertEqual(try restored.progressValue(LearningPlan.self,key:p.key)?.outcome?.gains,"备份收获")
        let key = GrowthPeriod.day.window(containing:date(18),calendar:calendar).key
        XCTAssertEqual(try restored.progressValue(GrowthReflection.self,key:key)?.goalCards,20)
        let timeline = try await restored.topicTimeline(notebookID:n.id!); XCTAssertEqual(timeline.items.filter{$0.kind == "修改记忆卡"}.count,1)
        try restored.finishPlan(draft); XCTAssertNil(try restored.progressValue(PlanOutcomeDraft.self,key:draft.key))
    }
}
