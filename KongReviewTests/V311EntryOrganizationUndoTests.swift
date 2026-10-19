import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V311EntryOrganizationUndoTests: XCTestCase {
    private func saved(_ card: Card,in db: AppDatabase) throws -> Card {
        let result = try db.save(card)
        return try XCTUnwrap(db.card(id:try XCTUnwrap(result.id)))
    }

    func testMoveUndoIsSingleUseAndOnlyRestoresDeckFromLatestRows() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(deck:"原牌组",front:"问题",back:"旧答案",tags:["旧标签"],state:.review,interval:20,reps:8),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.move(" 新牌组 ")))
        var latest = try XCTUnwrap(db.card(id:original.id!))
        latest.back = "后来编辑的答案";latest.tags = ["后来标签"];latest.reps = 12;latest.interval = 42;latest.isSuspended = true
        latest = try saved(latest,in:db)
        let result = try XCTUnwrap(db.undoCardEntryOrganization(token).first)
        var expected = latest;expected.deck = "原牌组";expected.updatedAt = result.updatedAt
        XCTAssertEqual(result,expected)
        XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.expired) }
        XCTAssertEqual(try db.card(id:original.id!),result)
    }

    func testAddingTagUndoPreservesLaterUnrelatedTagsDeckContentAndRatings() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(deck:"原牌组",front:"问题",back:"原答案",tags:["已有"]),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.tags(["已有","本次","本次"],.add)))
        var latest = try XCTUnwrap(db.card(id:original.id!))
        latest.deck = "后来移动";latest.tags += ["后来标签"];latest.back = "最新答案";latest.reps = 3;latest.due = Date(timeIntervalSince1970:2_000_000_000)
        latest = try saved(latest,in:db)
        let result = try XCTUnwrap(db.undoCardEntryOrganization(token).first)
        var expected = latest;expected.tags = ["已有","后来标签"];expected.updatedAt = result.updatedAt
        XCTAssertEqual(result,expected)
    }

    func testRemovingTagsUndoRestoresOriginalOrderAndPreservesLaterUnrelatedTags() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",tags:["甲","乙","丙","丁"]),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.tags(["甲","丙","不存在"],.remove)))
        var latest = try XCTUnwrap(db.card(id:original.id!));latest.tags.append("后来标签");latest.deck = "新牌组"
        _ = try saved(latest,in:db)
        let result = try XCTUnwrap(db.undoCardEntryOrganization(token).first)
        XCTAssertEqual(result.tags,["甲","乙","丙","丁","后来标签"])
        XCTAssertEqual(result.deck,"新牌组")
    }

    func testChangedAndChangedBackDeckBothConflictWithoutPartialUndo() throws {
        for restoreAfterChange in [false,true] {
            let db = try AppDatabase(DatabaseQueue())
            let first = try saved(Card(deck:"原牌组",front:"问题一"),in:db)
            let second = try saved(Card(deck:"原牌组",front:"问题二"),in:db)
            let ids = [first.id!,second.id!]
            let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:ids,allowedIDs:ids,change:.move("调整牌组")))
            var later = try XCTUnwrap(db.card(id:second.id!));later.deck = "另一个牌组";_ = try saved(later,in:db)
            if restoreAfterChange { later.deck = "调整牌组";_ = try saved(later,in:db) }
            let beforeAttempt = try ids.map { try db.card(id:$0) }
            XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.organizationChanged) }
            XCTAssertEqual(try ids.map { try db.card(id:$0) },beforeAttempt)
        }
    }

    func testAffectedTagABAIsDetectedForAddAndRemove() throws {
        for mode in [CardTagBatchMode.add,.remove] {
            let db = try AppDatabase(DatabaseQueue())
            let original = try saved(Card(front:"问题",tags:mode == .add ? ["旧标签"] : ["旧标签","本次"]),in:db)
            let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.tags(["本次"],mode)))
            var later = try XCTUnwrap(db.card(id:original.id!))
            if mode == .add { later.tags.removeAll { $0 == "本次" } }
            else { later.tags.append("本次") }
            _ = try saved(later,in:db)
            if mode == .add { later.tags.append("本次") }
            else { later.tags.removeAll { $0 == "本次" } }
            let unchanged = try saved(later,in:db)
            XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.organizationChanged) }
            XCTAssertEqual(try db.card(id:original.id!),unchanged)
        }
    }

    func testUnaffectedTagABAAndTagReorderingDoNotBlockDeckOrOtherTagUndo() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",tags:["旧标签","原有"]),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.tags(["本次"],.add)))
        var later = try XCTUnwrap(db.card(id:original.id!));later.tags.removeAll { $0 == "旧标签" };_ = try saved(later,in:db)
        later.tags = ["本次","原有","旧标签"];_ = try saved(later,in:db)
        let result = try XCTUnwrap(db.undoCardEntryOrganization(token).first)
        XCTAssertEqual(result.tags,["原有","旧标签"])
    }

    func testSoftDeleteAndRestoreRejectsReceiptWithoutRecreatingAnything() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题"),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.move("调整牌组")))
        var later = try XCTUnwrap(db.card(id:original.id!));later.deletedAt = Date();_ = try saved(later,in:db)
        later.deletedAt = nil;let unchanged = try saved(later,in:db)
        XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.unavailable) }
        XCTAssertEqual(try db.card(id:original.id!),unchanged)
    }

    func testHardDeletionAndReplacementWithSameIDCannotReuseReceipt() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题"),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[original.id!],allowedIDs:[original.id!],change:.tags(["本次"],.add)))
        try db.deleteCards([original.id!])
        XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.unavailable) }
        var replacement = original;replacement.tags = ["本次"]
        try db.writer.write { sql in try replacement.insert(sql) }
        XCTAssertThrowsError(try db.undoCardEntryOrganization(token)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.unavailable) }
        XCTAssertEqual(try db.card(id:original.id!)?.tags,["本次"])
    }

    func testNewOperationAndSuccessfulNoOpReplaceOlderReceipt() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saved(Card(front:"问题一"),in:db),second = try saved(Card(front:"问题二"),in:db)
        let a = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[first.id!],allowedIDs:[first.id!],change:.move("甲")))
        let b = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[second.id!],allowedIDs:[second.id!],change:.tags(["乙"],.add)))
        XCTAssertThrowsError(try db.undoCardEntryOrganization(a)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.expired) }
        XCTAssertNil(try db.changeCardEntryOrganizationRecordingUndo(ids:[second.id!],allowedIDs:[second.id!],change:.tags(["乙"],.add)))
        XCTAssertThrowsError(try db.undoCardEntryOrganization(b)) { XCTAssertEqual($0 as? CardEntryOrganizationUndoError,.expired) }
    }

    func testInvalidSelectionAndInvalidInputsRollbackAndRetainLatestReceipt() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saved(Card(front:"问题一"),in:db),second = try saved(Card(front:"问题二"),in:db)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:[first.id!],allowedIDs:[first.id!],change:.move("甲")))
        XCTAssertThrowsError(try db.changeCardEntryOrganizationRecordingUndo(ids:[first.id!,second.id!],allowedIDs:[first.id!],change:.tags(["禁止"],.add)))
        XCTAssertThrowsError(try db.changeCardEntryOrganizationRecordingUndo(ids:[first.id!],allowedIDs:[first.id!],change:.move(" \n")))
        XCTAssertThrowsError(try db.changeCardEntryOrganizationRecordingUndo(ids:[first.id!],allowedIDs:[first.id!],change:.tags([], .remove)))
        XCTAssertEqual(try db.card(id:second.id!),second)
        XCTAssertEqual(try db.undoCardEntryOrganization(token).first?.deck,first.deck)
    }

    func testHistoryScopeIsRecheckedWithinOrganizationWriteAndRejectsWholeSelection() throws {
        let db = try AppDatabase(DatabaseQueue())
        let cards = try db.saveInputCards([Card(deck:"范围牌组",front:"问题一"),Card(deck:"范围牌组",front:"问题二")])
        let ids = cards.compactMap(\.id),query = CardEntryHistoryQuery(date:nil,deck:"范围牌组")
        try db.validateCardEntryHistorySelection(ids,query:query)
        let token = try XCTUnwrap(db.changeCardEntryOrganizationRecordingUndo(ids:ids,allowedIDs:ids,change:.tags(["本次"],.add),historyQuery:query))
        var moved = try XCTUnwrap(db.card(id:ids[1]));moved.deck = "范围外";_ = try saved(moved,in:db)
        let beforeAttempt = try ids.map { try db.card(id:$0) }
        // A previously valid page capability cannot override current DB scope.
        XCTAssertThrowsError(try db.changeCardEntryOrganizationRecordingUndo(ids:ids,allowedIDs:ids,change:.move("不应移动"),historyQuery:query))
        XCTAssertEqual(try ids.map { try db.card(id:$0) },beforeAttempt)
        XCTAssertEqual(try db.undoCardEntryOrganization(token).count,2,"Rejected scope checks must retain the previous receipt")
    }

    func testStoreRetainsUndoAndUnsavedEditorOnRejectionThenSucceedsAfterClose() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try saved(Card(front:"问题",back:"旧答案",tags:["原有"]),in:db)
        let store = LibraryStore(db:db,positionDefaults:nil)
        try store.changeCardEntryOrganization(ids:[card.id!],allowedIDs:[card.id!],change:.tags(["本次"],.add))
        let token = try XCTUnwrap(store.cardEntryOrganizationUndo.token)
        store.editCard(try XCTUnwrap(db.card(id:card.id!)))
        store.cardEditor?.card.back = "未保存答案";store.cardEditor?.tagsText += " 未保存标签";store.cardEditor?.card.deck = "未保存牌组"
        let draft = try XCTUnwrap(store.cardEditor)
        XCTAssertFalse(store.undoLastCardEntryOrganization())
        XCTAssertEqual(store.cardEntryOrganizationUndo.token?.id,token.id)
        XCTAssertEqual(store.cardEditor?.id,draft.id);XCTAssertEqual(store.cardEditor?.card,draft.card)
        XCTAssertEqual(store.cardEditor?.tagsText,draft.tagsText)
        store.cardEditor = nil
        XCTAssertTrue(store.undoLastCardEntryOrganization())
        XCTAssertNil(store.cardEntryOrganizationUndo.token)
        XCTAssertEqual(try db.card(id:card.id!)?.tags,["原有"])
    }

    func testStorePreservesOtherNewInputAndBlockedFailureKeepsToken() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try saved(Card(front:"问题"),in:db),store = LibraryStore(db:db,positionDefaults:nil)
        store.newCard(deck:"当前输入");store.cardEditor?.card.front = "未保存新问题"
        let draft = try XCTUnwrap(store.cardEditor)
        try store.changeCardEntryOrganization(ids:[card.id!],allowedIDs:[card.id!],change:.move("批量牌组"))
        let tokenID = try XCTUnwrap(store.cardEntryOrganizationUndo.token?.id)
        store.fullBackupBusy = true
        XCTAssertFalse(store.undoLastCardEntryOrganization())
        XCTAssertThrowsError(try store.changeCardEntryOrganization(ids:[card.id!],allowedIDs:[card.id!],change:.move("禁止")))
        XCTAssertEqual(store.cardEntryOrganizationUndo.token?.id,tokenID)
        store.fullBackupBusy = false
        var later = try XCTUnwrap(db.card(id:card.id!));later.deck = "后来修改";_ = try saved(later,in:db)
        XCTAssertFalse(store.undoLastCardEntryOrganization())
        XCTAssertEqual(store.cardEntryOrganizationUndo.token?.id,tokenID)
        XCTAssertEqual(store.cardEditor?.id,draft.id);XCTAssertEqual(store.cardEditor?.card,draft.card)
        store.cardEntryOrganizationUndo.clear()
        XCTAssertNil(store.cardEntryOrganizationUndo.token);XCTAssertNil(store.cardEntryOrganizationUndo.message)
    }
}
