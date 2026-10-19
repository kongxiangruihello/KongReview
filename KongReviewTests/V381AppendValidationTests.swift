import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V381AppendValidationTests: XCTestCase {
    @MainActor func testPreviewRevalidatesFrontAfterPendingInputChanges() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(front:"Question",back:"旧答案"))
        let original = try XCTUnwrap(db.card(id:inserted.id!))
        let store = LibraryStore(db:db)
        store.newCard(deck:nil)
        store.cardEditor?.card.front = " QUESTION "
        store.cardEditor?.card.back = "刚输入的答案"
        var latest = original; latest.back = "最新答案"
        _ = try db.save(latest)
        XCTAssertEqual(try store.duplicateCardPreview(original,forAppend:true).back,"最新答案")
        XCTAssertEqual(store.cardEditor?.card.back,"刚输入的答案")
        store.cardEditor?.card.front = "新的独立题目"
        XCTAssertThrowsError(try store.duplicateCardPreview(original,forAppend:true))
        XCTAssertThrowsError(try store.duplicateCardPreview(original,forAppend:false))
        XCTAssertEqual(store.cardEditor?.card.front,"新的独立题目")
    }
    @MainActor func testDeletedDuplicateCanBeComparedButRequiresRestoreBeforeAppend() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(front:"重复问题",back:"旧答案",deletedAt:Date()))
        let deleted = try XCTUnwrap(db.card(id:inserted.id!))
        let store = LibraryStore(db:db)
        store.newCard(deck:nil)
        store.cardEditor?.card.front = "重复问题"
        XCTAssertEqual(try store.duplicateCardPreview(deleted,forAppend:false),deleted)
        XCTAssertThrowsError(try store.duplicateCardPreview(deleted,forAppend:true))
        try db.restoreInputDuplicate(id:inserted.id!)
        XCTAssertNil(try store.duplicateCardPreview(deleted,forAppend:true).deletedAt)
    }
    func testAppendRejectsChangedFrontEvenWhenPreviewReloadedLatestTarget() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(deck:"原牌组",front:"旧问题",back:"原答案",state:.review,reps:7))
        let incoming = Card(front:"旧问题",back:"当前补充")
        var changed = try XCTUnwrap(db.card(id:inserted.id!)); changed.front = "另一个问题"
        _ = try db.save(changed)
        let latestPreview = try XCTUnwrap(db.card(id:inserted.id!))
        let history = try db.cardContentHistory(id:inserted.id!).count
        XCTAssertThrowsError(try db.appendCardAnswer(from:incoming,to:latestPreview))
        XCTAssertEqual(try db.card(id:inserted.id!),latestPreview)
        XCTAssertEqual(try db.cardContentHistory(id:inserted.id!).count,history)
    }
    func testAppendStillAcceptsNormalizedDuplicateAndKeepsOriginalProgress() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(deck:"保留牌组",front:"Hello World",back:"原答案",state:.review,interval:20,reps:8))
        let original = try XCTUnwrap(db.card(id:inserted.id!))
        let result = try db.appendCardAnswer(from:Card(front:"<p>  HELLO   world </p>",back:"补充答案"),to:original)
        XCTAssertEqual(result.front,original.front); XCTAssertEqual(result.reps,8); XCTAssertEqual(result.interval,20)
        XCTAssertEqual(result.deck,"保留牌组"); XCTAssertTrue(result.back.contains("原答案")); XCTAssertTrue(result.back.contains("补充答案"))
        XCTAssertEqual(try db.cardCount(),1)
    }
}
