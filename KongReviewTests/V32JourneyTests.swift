import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V32JourneyTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from:.init(year:2026,month:10,day:day,hour:hour))! }
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
}
