import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V31JourneyTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; value.firstWeekday = 2; return value }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { calendar.date(from: .init(year: y, month: m, day: d, hour: h))! }

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
