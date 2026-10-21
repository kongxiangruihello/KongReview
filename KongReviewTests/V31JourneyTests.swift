import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V31JourneyTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; value.firstWeekday = 2; return value }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { calendar.date(from: .init(year: y, month: m, day: d, hour: h))! }

    func testTrendWindowsCoverDSTLeapMonthAndYearBoundaries() {
        let now = date(2024,3,1,12)
        for range in GrowthTrendRange.allCases {
            let windows = range.windows(now: now, calendar: calendar)
            XCTAssertEqual(windows.count, range == .days ? 30 : 12)
            XCTAssertEqual(windows.last?.end, now)
            for i in 1..<windows.count { XCTAssertEqual(windows[i-1].end, windows[i].start) }
        }
        XCTAssertEqual(GrowthTrendRange.days.windows(now: now, calendar: calendar).dropLast().last?.start, date(2024,2,29))
        var local = calendar; local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let end = local.date(from: .init(year:2026,month:3,day:9,hour:12))!
        let windows = GrowthTrendRange.days.windows(now:end,calendar:local)
        XCTAssertEqual(windows[28].end.timeIntervalSince(windows[28].start),23*3600)
    }
    func testTrendBucketDeduplicationMatchesDrilldowns() async throws {
        let db = try AppDatabase(DatabaseQueue()), now = date(2026,10,18,12)
        let h = try db.save(Highlight(text: "原文")), c = try db.save(Card(front: "问题"))
        for at in [date(2026,10,17),date(2026,10,18)] {
            db.log(.init(kind:.keep,highlightId:h.id,at:at)); db.log(.init(kind:.favorite,highlightId:h.id,at:at))
            for answer in [1,3] { db.log(.init(kind:.card,cardId:c.id,answer:answer,at:at)) }
        }
        db.log(.init(kind:.note,highlightId:h.id,at:date(2026,10,16)))
        db.log(.init(kind:.card,cardId:c.id,answer:1,at:now)) // End is exclusive.
        try db.deleteCards([c.id!])
        for range in GrowthTrendRange.allCases {
            let values = try await db.growthTrend(range,now:now,calendar:calendar)
            for point in values {
                for metric in [GrowthMetric.highlights,.cards,.ratings] {
                    let page = try await db.growthDetails(metric:metric,start:point.window.start,end:point.window.end,offset:0)
                    XCTAssertEqual(point.summary[metric],page.total)
                }
            }
        }
        let daily = try await db.growthTrend(.days,now:now,calendar:calendar)
        XCTAssertEqual(daily.last?.summary[.cards],1); XCTAssertEqual(daily.last?.summary[.ratings],2)
        let monthly = try await db.growthTrend(.months,now:now,calendar:calendar)
        XCTAssertEqual(monthly.last?.summary[.cards],1); XCTAssertEqual(monthly.last?.summary[.ratings],4)
    }
    func testHistorySearchPaginationAndChronologicalOrdering() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<105 {
            let at = calendar.date(byAdding:.day,value:-i,to:date(2026,10,18))!
            try db.saveProgress(GrowthReflection(gains:"學習材料 \(i)",nextSteps:"下一步"),key:GrowthPeriod.day.window(containing:at,calendar:calendar).key)
        }
        try db.saveProgress(GrowthReflection(),key:"growth.day.2024-1-1")
        try db.saveProgress(GrowthReflection(challenges:"月度困难"),key:"growth.month.2026-10-1")
        let first = try await db.growthHistory(query:"学习",period:.day)
        let second = try await db.growthHistory(query:"学习",period:.day,offset:50)
        let last = try await db.growthHistory(query:"学习",period:.day,offset:100)
        XCTAssertEqual(first.total,105); XCTAssertEqual(first.items.count,50); XCTAssertEqual(last.items.count,5)
        XCTAssertEqual(first.items.first?.id,"growth.day.2026-10-18")
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with:second.items.map(\.id)))
        let monthly = try await db.growthHistory(query:"困难",period:.month)
        XCTAssertEqual(monthly.items.count,1)
        let empty = try await db.growthHistory(query:"不存在")
        XCTAssertEqual(empty.total,0)
    }
    func testPlansPagingCompletionBoundariesAndUndoCompletion() async throws {
        let db = try AppDatabase(DatabaseQueue()), start = date(2026,10,1), end = date(2026,11,1)
        for i in 0..<105 { try db.saveLearningPlan(LearningPlan(title:"计划 \(i)",dueDate:start.addingTimeInterval(Double(i)))) }
        let a = try await db.learningPlans(completed:false), b = try await db.learningPlans(completed:false,offset:50), c = try await db.learningPlans(completed:false,offset:100)
        XCTAssertEqual(a.total,105); XCTAssertEqual(a.items.count,50); XCTAssertEqual(c.items.count,5)
        XCTAssertTrue(Set(a.items.map(\.id)).isDisjoint(with:b.items.map(\.id)))
        var first = a.items[0]; first.completedAt = start; try db.saveLearningPlan(first)
        var second = a.items[1]; second.completedAt = end; try db.saveLearningPlan(second)
        let period = try await db.learningPlans(completed:true,start:start,end:end)
        XCTAssertEqual(period.items.map(\.id),[first.id])
        first.completedAt = nil; try db.saveLearningPlan(first)
        let undone = try await db.learningPlans(completed:true,start:start,end:end)
        XCTAssertEqual(undone.total,0)
        XCTAssertThrowsError(try db.saveLearningPlan(.init(title:" \n ")))
    }
    func testPlanLinksResolveAndDeletedTargetsDoNotErasePlans() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title:"图书")), notebook = try db.createNotebook(title:"专题"), card = try db.save(Card(front:"概念"))
        _ = try db.saveResearchProject(ResearchProject(title:"项目")) // 4.0：计划也可关联研究项目
        for kind in LearningPlanLinkKind.allCases {
            let values = try await db.planLinkChoices(kind:kind,query:"")
            XCTAssertEqual(values.total,1)
            let link = try XCTUnwrap(values.items.first)
            let exists = try await db.planLinkExists(link); XCTAssertTrue(exists)
        }
        let link = LearningPlanLink(kind:.card,recordID:card.id!,title:"概念")
        let plan = LearningPlan(title:"重读",link:link); try db.saveLearningPlan(plan)
        try db.deleteCards([card.id!]); try db.deleteNotebook(notebook.id!)
        let exists = try await db.planLinkExists(link); XCTAssertFalse(exists)
        let available = try await db.planLinkChoices(kind:.card,query:"")
        XCTAssertEqual(available.total,0)
        let retained = try await db.learningPlans(); XCTAssertEqual(retained.items.first?.link,link)
        XCTAssertNotNil(source.id)
    }
    func testPlanLinkSearchPaginationTreatsWildcardsLiterally() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<55 { _ = try db.save(Card(front:"question \(i)")) }
        _ = try db.save(Card(front:"literal % _"))
        let a = try await db.planLinkChoices(kind:.card,query:"question")
        let b = try await db.planLinkChoices(kind:.card,query:"question",offset:50)
        XCTAssertEqual(a.total,55); XCTAssertEqual(a.items.count,50); XCTAssertEqual(b.items.count,5)
        let literal = try await db.planLinkChoices(kind:.card,query:"%")
        XCTAssertEqual(literal.total,1)
    }
    func testCareComparisonEqualWindowsBoundariesCapAndSampleNotice() async throws {
        let db = try AppDatabase(DatabaseQueue()), adjusted = date(2026,10,10)
        let card = try db.save(Card(front:"困难问题"))
        let care = DifficultCardCare(cardID:card.id!,reason:.context,note:"补背景",adjustedAt:adjusted)
        for answer in [1,1,3] { db.log(.init(kind:.card,cardId:card.id,answer:answer,at:date(2026,10,9))) }
        for answer in [1,3,3] { db.log(.init(kind:.card,cardId:card.id,answer:answer,at:adjusted)) }
        db.log(.init(kind:.card,cardId:card.id,answer:1,at:date(2026,10,12)))
        let comparison = try await db.cardCareComparison(care,now:date(2026,10,12),calendar:calendar)
        XCTAssertEqual(comparison?.beforeAgain,2); XCTAssertEqual(comparison?.afterAgain,1)
        XCTAssertEqual(comparison?.beforeRatings,3); XCTAssertEqual(comparison?.afterRatings,3)
        XCTAssertTrue(comparison?.interpretation.contains("下降") == true)
        let noTime = try await db.cardCareComparison(care,now:adjusted,calendar:calendar); XCTAssertNil(noTime)
        let notAdjusted = try await db.cardCareComparison(DifficultCardCare(cardID:card.id!)); XCTAssertNil(notAdjusted)
        let capped = try await db.cardCareComparison(care,now:date(2026,11,1),calendar:calendar)
        XCTAssertEqual(capped?.days,14)
        XCTAssertTrue(CardCareComparison(beforeRatings:0,beforeAgain:0,afterRatings:0,afterAgain:0,days:1).interpretation.contains("不足"))
    }
    func testCareHistoryPreservesTrackedCardsAfterDeletion() async throws {
        let db = try AppDatabase(DatabaseQueue()), card = try db.save(Card(front:"保留标题"))
        let care = DifficultCardCare(cardID:card.id!,reason:.shelved,note:"稍后再整理")
        try db.saveProgress(care,key:care.key)
        let first = try await db.difficultCareList()
        XCTAssertEqual(first.items.first?.1,"保留标题"); XCTAssertEqual(first.items.first?.0,care)
        try db.deleteCards([card.id!])
        let deleted = try await db.difficultCareList()
        XCTAssertEqual(deleted.total,1); XCTAssertEqual(deleted.items.first?.1,"原卡片已删除")
    }
    func testPlansAndCarePersistAcrossReopenAndFullBackupRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let db = try AppDatabase(DatabaseQueue(path:path))
        let card = try db.save(Card(front:"难卡"))
        let plan = LearningPlan(title:"整理资料",completedAt:date(2026,10,18),originKey:"growth.day.2026-10-18")
        let care = DifficultCardCare(cardID:card.id!,adjustedAt:date(2026,10,17))
        try db.saveLearningPlan(plan); try db.saveProgress(care,key:care.key)
        let reopened = try AppDatabase(DatabaseQueue(path:path))
        XCTAssertEqual(try reopened.progressValue(LearningPlan.self,key:plan.key),plan)
        let defaults = UserDefaults(suiteName:UUID().uuidString)!, url = directory.appendingPathComponent("growth.kongreviewbackup")
        try FullBackupService.create(db:reopened,draftURL:nil,defaults:defaults,destination:url)
        let prepared = try FullBackupService.prepare(url:url); defer { prepared.cleanup() }
        let restored = try AppDatabase(DatabaseQueue())
        _ = try FullBackupService.restore(prepared,db:restored,draftURL:nil,defaults:defaults,safetyDirectory:directory)
        XCTAssertEqual(try restored.progressValue(LearningPlan.self,key:plan.key),plan)
        XCTAssertEqual(try restored.progressValue(DifficultCardCare.self,key:care.key),care)
    }
}
