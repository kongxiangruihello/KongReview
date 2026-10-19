import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V32JourneyTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from:.init(year:2026,month:10,day:day,hour:hour))! }
    func testBatchPlanCommitIsAtomicClearsDraftAndRejectsReplay() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let plan = LearningPlan(title:"1. 重读原文\n\n- [ ] 整理出处\n• 补充背景",dueDate:date(18),originKey:"growth.week.2026-10-12")
        let draft = LearningPlanDraft(plan:plan,splitLines:true)
        try db.saveProgress(draft,key:draft.key)
        XCTAssertEqual(LearningPlanDraft.lines(plan.title),["重读原文","整理出处","补充背景"])
        try db.commitPlanDraft(draft)
        let page = try await db.planPage(status:.pending)
        XCTAssertEqual(page.total,3); XCTAssertEqual(Set(page.items.map(\.title)),Set(["重读原文","整理出处","补充背景"]))
        XCTAssertTrue(page.items.allSatisfy { $0.dueDate == date(18) && $0.originKey == plan.originKey })
        XCTAssertNil(try db.progressValue(LearningPlanDraft.self,key:draft.key))
        XCTAssertThrowsError(try db.commitPlanDraft(draft))
        let again = try await db.planPage(status:.pending); XCTAssertEqual(again.total,3)
        let empty = LearningPlanDraft(plan:.init(title:"\n- [ ] \n"),splitLines:true)
        XCTAssertThrowsError(try db.commitPlanDraft(empty))
    }
    func testDraftConflictNeverOverwritesNewCompletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let plan = LearningPlan(title:"原计划"); try db.saveLearningPlan(plan)
        var draft = LearningPlanDraft(plan:plan,original:plan); draft.plan.title = "未保存的新文字"
        try db.saveProgress(draft,key:draft.key)
        try db.changePlanStatus(id:plan.id,status:.completed,now:date(18))
        XCTAssertThrowsError(try db.commitPlanDraft(draft))
        XCTAssertEqual(try db.progressValue(LearningPlan.self,key:plan.key)?.completedAt,date(18))
        XCTAssertEqual(try db.progressValue(LearningPlanDraft.self,key:draft.key)?.plan.title,"未保存的新文字")
    }
    func testTodayOverdueCancellationRestorationAndPaging() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<12 { try db.saveLearningPlan(.init(title:"到期 \(i)",dueDate:i < 4 ? date(17,23) : date(18,23))) }
        try db.saveLearningPlan(.init(title:"明天",dueDate:date(19)))
        let first = try await db.todayPlans(now:date(18,12),calendar:calendar,limit:5)
        let second = try await db.todayPlans(now:date(18,12),calendar:calendar,offset:5,limit:5)
        XCTAssertEqual(first.today,8); XCTAssertEqual(first.overdue,4); XCTAssertEqual(first.page.items.count,5)
        XCTAssertTrue(Set(first.page.items.map(\.id)).isDisjoint(with:second.page.items.map(\.id)))
        let plan = first.page.items[0]
        try db.changePlanStatus(id:plan.id,status:.cancelled,now:date(18))
        let cancelled = try await db.planPage(status:.cancelled); XCTAssertEqual(cancelled.total,1)
        let hidden = try await db.todayPlans(now:date(18,12),calendar:calendar); XCTAssertEqual(hidden.page.total,11)
        try db.changePlanStatus(id:plan.id,status:.pending)
        try db.changePlanStatus(id:plan.id,status:.completed,now:date(18,13))
        let report = try await db.learningPlans(completed:true,start:date(18),end:date(19)); XCTAssertEqual(report.items.map(\.id),[plan.id])
        try db.changePlanStatus(id:plan.id,status:.cancelled)
        let removed = try await db.learningPlans(completed:true,start:date(18),end:date(19)); XCTAssertEqual(removed.total,0)
    }
    func testOldPlanAndCarePayloadsDecodeWithoutNewFields() throws {
        let plan = LearningPlan(title:"旧版计划"), care = DifficultCardCare(cardID:7)
        var p = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
        p.removeValue(forKey:"cancelledAt")
        XCTAssertNil(try JSONDecoder().decode(LearningPlan.self,from:JSONSerialization.data(withJSONObject:p)).cancelledAt)
        var c = try JSONSerialization.jsonObject(with:JSONEncoder().encode(care)) as! [String:Any]
        c.removeValue(forKey:"baseline"); c.removeValue(forKey:"relatedCardIDs")
        let decoded = try JSONDecoder().decode(DifficultCardCare.self,from:JSONSerialization.data(withJSONObject:c))
        XCTAssertNil(decoded.baseline); XCTAssertNil(decoded.relatedCardIDs)
    }
    func testTrackedEditsRecordSnapshotsButScheduleAndDeckChangesDoNot() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try db.save(Card(front:"原问题",back:"原答案"))
        _ = try db.saveCare(cardID:card.id!,reason:.split,note:"需要拆分")
        card.front = "修改后的问题"; card.back = "更短的答案"; card = try db.save(card)
        var changes = try await db.careAdjustments(cardID:card.id!)
        XCTAssertEqual(changes.total,1); XCTAssertEqual(changes.items[0].before.front,"原问题"); XCTAssertEqual(changes.items[0].after.back,"更短的答案")
        let care = try XCTUnwrap(db.progressValue(DifficultCardCare.self,key:"difficult-care.\(card.id!)"))
        XCTAssertEqual(care.baseline?.front,"原问题"); XCTAssertNotNil(care.adjustedAt)
        card.reps += 1; card.deck = "新的牌组"; card = try db.save(card)
        changes = try await db.careAdjustments(cardID:card.id!); XCTAssertEqual(changes.total,1)
        card.back = "再次补充背景"; _ = try db.save(card)
        changes = try await db.careAdjustments(cardID:card.id!); XCTAssertEqual(changes.total,2)
        XCTAssertTrue(changes.items.contains { $0.before.back == "更短的答案" && $0.after.back == "再次补充背景" })
        var untracked = try db.save(Card(front:"普通卡")); untracked.back = "新答案"; _ = try db.save(untracked)
        let none = try await db.careAdjustments(cardID:untracked.id!); XCTAssertEqual(none.total,0)
    }
    @MainActor func testEditorSaveCreatesCareHistoryThroughRealStoreAction() async throws {
        let db = try AppDatabase(DatabaseQueue())
        // Use an isolated store/database for the same save path as the editor.
        let active = LibraryStore(db:db,positionDefaults:nil)
        let card = try db.save(Card(front:"需要调整的问题",back:"答案"))
        _ = try db.saveCare(cardID:card.id!,reason:.context,note:"补背景")
        active.cardEditor = CardDraft(card:card); active.cardEditor?.card.back = "补充后的答案"
        active.commitCardEditor()
        XCTAssertNil(active.cardEditor)
        let changes = try await db.careAdjustments(cardID:card.id!)
        XCTAssertEqual(changes.total,1); XCTAssertEqual(changes.items[0].after.back,"补充后的答案")
    }
    func testRelatedCardsDeduplicateRejectSelfAndKeepDeletedHistory() async throws {
        let db = try AppDatabase(DatabaseQueue()), parent = try db.save(Card(front:"原问题")), child = try db.save(Card(front:"拆分问题"))
        _ = try db.saveCare(cardID:parent.id!,reason:.split,note:"")
        try db.linkCareCard(parent:parent.id!,child:child.id!); try db.linkCareCard(parent:parent.id!,child:child.id!)
        XCTAssertThrowsError(try db.linkCareCard(parent:parent.id!,child:parent.id!))
        var care = try XCTUnwrap(db.progressValue(DifficultCardCare.self,key:"difficult-care.\(parent.id!)")); care.adjustedAt = date(10); try db.saveProgress(care,key:care.key)
        for answer in [1,3,3] { db.log(.init(kind:.card,cardId:child.id,answer:answer,at:date(11))) }
        db.log(.init(kind:.card,cardId:child.id,answer:1,at:date(9)))
        let page = try await db.careRelatedCards(cardID:parent.id!,now:date(12)); XCTAssertEqual(page.total,1); XCTAssertEqual(page.items[0].ratings,3); XCTAssertEqual(page.items[0].again,1)
        try db.deleteCards([child.id!])
        let deleted = try await db.careRelatedCards(cardID:parent.id!,now:date(12)); XCTAssertEqual(deleted.total,1); XCTAssertFalse(deleted.items[0].available); XCTAssertEqual(deleted.items[0].ratings,3)
        try db.linkCareCard(parent:parent.id!,child:child.id!,remove:true)
        let removed = try await db.careRelatedCards(cardID:parent.id!); XCTAssertEqual(removed.total,0)
    }
    func testRollupTotalsMatchDetailAndDeduplicateNotebookBlocks() async throws {
        let db = try AppDatabase(DatabaseQueue()), start = date(1), end = date(31)
        let source = try db.save(Source(title:"史料")), h = try db.save(Highlight(sourceId:source.id,text:"摘录",createdAt:date(2)))
        let c = try db.save(Card(deck:"专题牌组",front:"问答",highlightId:h.id,createdAt:date(2)))
        let n = try db.createNotebook(title:"专题一"), other = try db.createNotebook(title:"专题二")
        for notebook in [n,other] {
            _ = try db.insertBlocks([.init(notebookId:notebook.id!,position:1,kind:.highlight,highlightId:h.id),.init(notebookId:notebook.id!,position:2,kind:.highlight,highlightId:h.id)],into:notebook.id!,after:nil)
        }
        db.log(.init(kind:.keep,highlightId:h.id,at:date(3))); db.log(.init(kind:.favorite,highlightId:h.id,at:date(3)))
        for answer in [1,1,1,3] { db.log(.init(kind:.card,cardId:c.id,answer:answer,at:date(3))) }
        for metric in [GrowthMetric.highlights,.cards,.ratings,.difficult,.newHighlights,.newCards] {
            for grouping in GrowthGrouping.allCases where grouping != .deck || metric.isCardMetric {
                let groups = try await db.growthBreakdown(metric:metric,grouping:grouping,start:start,end:end)
                let expected = metric == .ratings ? 4 : 1
                XCTAssertEqual(groups.total,grouping == .notebook ? 2 : 1)
                for group in groups.items {
                    XCTAssertEqual(group.count,expected)
                    let detail = try await db.growthBreakdownDetails(metric:metric,grouping:grouping,key:group.key,start:start,end:end)
                    XCTAssertEqual(detail.total,group.count); XCTAssertEqual(detail.rows.count,expected)
                }
            }
        }
        try db.deleteCards([c.id!])
        let deleted = try await db.growthBreakdown(metric:.cards,grouping:.source,start:start,end:end)
        XCTAssertEqual(deleted.items[0].count,1); XCTAssertNil(deleted.items[0].key)
        let details = try await db.growthBreakdownDetails(metric:.cards,grouping:.source,key:nil,start:start,end:end)
        XCTAssertNil(details.rows[0].target)
    }
    func testRollupGroupAndDetailPagination() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<55 {
            let c = try db.save(Card(deck:"牌组 \(i)",front:"题目 \(i)"))
            db.log(.init(kind:.card,cardId:c.id,answer:3,at:date(3)))
        }
        let a = try await db.growthBreakdown(metric:.cards,grouping:.deck,start:date(1),end:date(31)), b = try await db.growthBreakdown(metric:.cards,grouping:.deck,start:date(1),end:date(31),offset:50)
        XCTAssertEqual(a.total,55); XCTAssertEqual(a.items.count,50); XCTAssertEqual(b.items.count,5)
        XCTAssertTrue(Set(a.items.map(\.id)).isDisjoint(with:b.items.map(\.id)))
        let c = try db.save(Card(deck:"集中牌组",front:"题目"))
        for _ in 0..<105 { db.log(.init(kind:.card,cardId:c.id,answer:3,at:date(3))) }
        let first = try await db.growthBreakdownDetails(metric:.ratings,grouping:.deck,key:"集中牌组",start:date(1),end:date(31))
        let last = try await db.growthBreakdownDetails(metric:.ratings,grouping:.deck,key:"集中牌组",start:date(1),end:date(31),offset:100)
        XCTAssertEqual(first.total,105); XCTAssertEqual(first.rows.count,50); XCTAssertEqual(last.rows.count,5)
    }
    func testBackupRestoresDraftCancellationSnapshotsAndRelatedCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let db = try AppDatabase(DatabaseQueue(path:directory.appendingPathComponent("original.sqlite").path))
        let plan = LearningPlan(title:"取消的计划"); try db.saveLearningPlan(plan); try db.changePlanStatus(id:plan.id,status:.cancelled)
        let draft = LearningPlanDraft(plan:.init(title:"尚未保存\n拆分计划"),splitLines:true); try db.saveProgress(draft,key:draft.key)
        var card = try db.save(Card(front:"原文")); let child = try db.save(Card(front:"拆分"))
        _ = try db.saveCare(cardID:card.id!,reason:.split,note:"原因"); try db.linkCareCard(parent:card.id!,child:child.id!)
        card.back = "新答案"; _ = try db.save(card)
        let url = directory.appendingPathComponent("test.kongreviewbackup"), prefs = UserDefaults(suiteName:UUID().uuidString)!
        try FullBackupService.create(db:db,draftURL:nil,defaults:prefs,destination:url)
        let prepared = try FullBackupService.prepare(url:url); defer { prepared.cleanup() }
        let restored = try AppDatabase(DatabaseQueue()); _ = try FullBackupService.restore(prepared,db:restored,draftURL:nil,defaults:prefs,safetyDirectory:directory)
        XCTAssertEqual(try restored.progressValue(LearningPlanDraft.self,key:draft.key),draft)
        let cancelled = try await restored.planPage(status:.cancelled); XCTAssertEqual(cancelled.total,1)
        let snapshots = try await restored.careAdjustments(cardID:card.id!); XCTAssertEqual(snapshots.total,1); XCTAssertEqual(snapshots.items[0].before.front,"原文")
        let related = try await restored.careRelatedCards(cardID:card.id!); XCTAssertEqual(related.items.map(\.id),[child.id!])
        try restored.commitPlanDraft(draft)
        let pending = try await restored.planPage(status:.pending); XCTAssertEqual(pending.total,2)
    }
}
