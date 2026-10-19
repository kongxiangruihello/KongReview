import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V310EntryBatchTests: XCTestCase {
    private func saved(_ value: Card,in db: AppDatabase) throws -> Card {
        let value = try db.save(value)
        return try XCTUnwrap(db.card(id:value.id!))
    }
    private func persistence() throws -> (URL,EditorDraftPersistence) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory,try EditorDraftPersistence(directory:directory))
    }
    func testBatchPaginationOnlyIncludesSessionCardsAndClampsAfterDeletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        var ids: [Int64] = []
        for i in 0..<151 { ids.append(try saved(Card(front:"录入题目\(i)"),in:db).id!) }
        _ = try saved(Card(front:"不属于本次"),in:db)
        var all = Set<Int64>()
        for page in 1...4 {
            let value = try db.cardEntryBatchPage(ids:ids + ids,page:page)
            XCTAssertEqual(value.total,151)
            XCTAssertLessThanOrEqual(value.cards.count,50)
            XCTAssertTrue(all.isDisjoint(with:value.cards.compactMap(\.id)))
            all.formUnion(value.cards.compactMap(\.id))
        }
        XCTAssertEqual(all,Set(ids))
        try db.deleteCards(Array(ids.suffix(52)))
        let last = try db.cardEntryBatchPage(ids:ids,page:100)
        XCTAssertEqual(last.total,99);XCTAssertEqual(last.page,2);XCTAssertEqual(last.cards.count,49)
    }
    func testDeletedOrOutsideSelectionCannotPartiallyUpdateBatch() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try saved(Card(front:"甲",tags:["保留"]),in:db)
        let b = try saved(Card(front:"乙"),in:db)
        XCTAssertThrowsError(try db.changeCardEntryBatch(ids:[a.id!,b.id!],allowedIDs:[a.id!],change:.move("新牌组")))
        XCTAssertEqual(try db.card(id:a.id!),a)
        var deleted = b;deleted.deletedAt = Date();_ = try db.save(deleted)
        XCTAssertThrowsError(try db.changeCardEntryBatch(ids:[a.id!,b.id!],allowedIDs:[a.id!,b.id!],change:.tags(["新标签"],.add)))
        XCTAssertEqual(try db.card(id:a.id!),a)
    }
    func testMetadataUpdatesAndTagUndoKeepLatestLearningAndOtherTags() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"答案",tags:["已有"],state:.review,interval:20,reps:8),in:db)
        let id = original.id!
        let undo = try XCTUnwrap(db.changeCardEntryBatch(ids:[id],allowedIDs:[id],change:.tags(["本次"],.add)))
        _ = try db.changeCardEntryBatch(ids:[id],allowedIDs:[id],change:.move("调整牌组"))
        var later = try XCTUnwrap(db.card(id:id));later.reps = 11;later.interval = 40;later.tags.append("后来标签")
        _ = try db.save(later)
        try db.restore(undo)
        let result = try XCTUnwrap(db.card(id:id))
        XCTAssertEqual(result.tags,["已有","后来标签"])
        XCTAssertEqual(result.deck,"调整牌组");XCTAssertEqual(result.reps,11);XCTAssertEqual(result.interval,40)
        XCTAssertEqual(result.front,original.front);XCTAssertEqual(result.back,original.back)
    }
    func testNewCardIDsAreRecordedOnceAndNewSessionClearsOnlyTheList() throws {
        let store = LibraryStore(db:try AppDatabase(DatabaseQueue()),positionDefaults:nil)
        store.newCard(deck:nil);store.cardEditor?.card.front = "新题"
        XCTAssertTrue(store.commitCardAndContinue())
        let id = try XCTUnwrap(store.cardWorkflow.addedCardIDs.first)
        XCTAssertEqual(store.cardWorkflow.addedCount,1)
        store.cardWorkflow.recordAddedCard(id)
        XCTAssertEqual(store.cardWorkflow.addedCardIDs,[id]);XCTAssertEqual(store.cardWorkflow.addedCount,1)
        let batch = store.cardWorkflow.batchID
        store.newCard(deck:nil)
        XCTAssertNotEqual(store.cardWorkflow.batchID,batch);XCTAssertTrue(store.cardWorkflow.addedCardIDs.isEmpty)
        XCTAssertNotNil(try store.db.card(id:id))
    }
    func testBatchEditRetainsIncomingDraftAndPreservesTheBatchSession() throws {
        let db = try AppDatabase(DatabaseQueue()),(directory,persistence) = try self.persistence()
        defer { try? FileManager.default.removeItem(at:directory) }
        let existing = try saved(Card(front:"本次已保存卡片",back:"原答案"),in:db)
        let store = LibraryStore(db:db,draftPersistence:persistence,positionDefaults:nil)
        store.newCard(deck:"继续录入");store.cardEditor?.card.front = "下一张未保存问题"
        let incoming = try XCTUnwrap(store.cardEditor)
        store.cardWorkflow.recordAddedCard(existing.id)
        let batch = store.cardWorkflow.batchID
        XCTAssertTrue(store.editCardFromEntryBatch(id:existing.id!,batchID:batch))
        XCTAssertEqual(store.cardEditor?.card,existing)
        XCTAssertEqual(store.cardWorkflow.batchID,batch);XCTAssertEqual(store.cardWorkflow.addedCount,1)
        XCTAssertEqual(store.savedCardDrafts.first { $0.id == incoming.id }?.card,incoming.card)
        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id,incoming.id)
    }
    func testBatchEditingWithoutPersistenceDoesNotCloseCurrentInput() throws {
        let store = LibraryStore(db:try AppDatabase(DatabaseQueue()),positionDefaults:nil)
        let actual = try saved(Card(front:"本次卡片"),in:store.db)
        store.newCard(deck:nil);store.cardEditor?.card.front = "未保存输入"
        let incoming = try XCTUnwrap(store.cardEditor)
        store.cardWorkflow.recordAddedCard(actual.id)
        XCTAssertFalse(store.editCardFromEntryBatch(id:actual.id!,batchID:store.cardWorkflow.batchID))
        XCTAssertEqual(store.cardEditor?.id,incoming.id);XCTAssertEqual(store.cardEditor?.card,incoming.card)
    }
    func testBatchMetadataAlsoUpdatesOpenEditorWithoutDroppingUnsavedAnswer() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try saved(Card(front:"本次题目",back:"旧答案",tags:["旧标签"]),in:db)
        let store = LibraryStore(db:db,positionDefaults:nil)
        store.editCard(card);store.cardEditor?.card.back = "未保存的新答案";store.cardEditor?.tagsText = "旧标签 未保存标签"
        store.cardWorkflow.recordAddedCard(card.id)
        let batch = store.cardWorkflow.batchID
        try store.changeCurrentCardEntryBatch(ids:[card.id!],batchID:batch,change:.tags(["批量标签"],.add))
        try store.changeCurrentCardEntryBatch(ids:[card.id!],batchID:batch,change:.move("新牌组"))
        XCTAssertEqual(store.cardEditor?.card.back,"未保存的新答案")
        XCTAssertEqual(Set(TagParser.parse(store.cardEditor!.tagsText)),["旧标签","未保存标签","批量标签"])
        XCTAssertEqual(store.cardEditor?.card.deck,"新牌组")
        XCTAssertEqual(try db.card(id:card.id!)?.back,"旧答案")
        XCTAssertEqual(try db.card(id:card.id!)?.tags,["旧标签","批量标签"])
    }
    func testStaleSessionAndBackupBusyCannotWriteBatchChanges() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try saved(Card(front:"本次题目"),in:db),store = LibraryStore(db:db,positionDefaults:nil)
        store.cardWorkflow.recordAddedCard(card.id)
        let batch = store.cardWorkflow.batchID
        store.fullBackupBusy = true
        XCTAssertThrowsError(try store.changeCurrentCardEntryBatch(ids:[card.id!],batchID:batch,change:.move("禁止")))
        store.fullBackupBusy = false;store.cardWorkflow.startSession()
        XCTAssertThrowsError(try store.changeCurrentCardEntryBatch(ids:[card.id!],batchID:batch,change:.move("禁止")))
        XCTAssertEqual(try db.card(id:card.id!),card)
    }
}
