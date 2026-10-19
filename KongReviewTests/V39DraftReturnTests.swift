import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V39DraftReturnTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KongReview-draft-return-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor private func makeContext() throws -> (LibraryStore, AppDatabase, EditorDraftPersistence, Card, CardDraft, URL) {
        let directory = try temporaryDirectory()
        let db = try AppDatabase(DatabaseQueue())
        let original = try db.save(Card(deck: "原牌组", front: "Question", back: "原答案", tags: ["原标签"],
                                       state: .review, interval: 30, reps: 12))
        let full = try XCTUnwrap(db.card(id: original.id!))
        let persistence = try EditorDraftPersistence(directory: directory)
        let store = LibraryStore(db: db, draftPersistence: persistence)
        store.newCard(deck: "输入牌组")
        store.cardEditor?.card.front = " <p>QUESTION</p> "
        store.cardEditor?.card.back = "本次输入的答案"
        store.cardEditor?.tagsText = "本次标签"
        let incoming = try XCTUnwrap(store.cardEditor)
        XCTAssertTrue(store.editOriginalDuplicate(full))
        return (store, db, persistence, full, incoming, directory)
    }

    @MainActor func testReturningPreservesUnsavedOriginalAndRestoresIncomingDurably() throws {
        let (store, db, _, original, incoming, directory) = try makeContext()
        let originalEditorID = try XCTUnwrap(store.cardEditor?.id)
        store.cardEditor?.card.back = "原卡未保存的修改"
        store.cardEditor?.tagsText = "原卡未保存标签"

        XCTAssertTrue(store.canReturnToIncomingCardDraft)
        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertEqual(store.cardEditor?.tagsText, incoming.tagsText)
        XCTAssertNil(store.cardWorkflow.duplicateReturn)
        XCTAssertEqual(try db.card(id: original.id!), original)
        let restarted = try EditorDraftPersistence(directory: directory)
        XCTAssertEqual(restarted.cardDrafts.first { $0.id == originalEditorID }?.card.back, "原卡未保存的修改")
        XCTAssertEqual(restarted.cardDrafts.first { $0.id == originalEditorID }?.tagsText, "原卡未保存标签")
        XCTAssertEqual(restarted.cardDrafts.first { $0.id == incoming.id }?.card, incoming.card)
    }

    @MainActor func testSuccessfulSaveAuthorizesReturningFromClosedOriginalEditor() throws {
        let (store, db, _, original, incoming, directory) = try makeContext()
        let originalEditorID = try XCTUnwrap(store.cardEditor?.id)
        store.cardEditor?.card.back = "原卡已正式保存的修改"
        store.commitCardEditor()

        XCTAssertNil(store.cardEditor)
        XCTAssertTrue(store.cardWorkflow.duplicateReturn?.originalSaved == true)
        XCTAssertTrue(store.canReturnToIncomingCardDraft)
        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card.back, incoming.card.back)
        XCTAssertEqual(try db.card(id: original.id!)?.back, "原卡已正式保存的修改")
        XCTAssertEqual(try db.card(id: original.id!)?.reps, 12)
        let reopened = try EditorDraftPersistence(directory: directory)
        XCTAssertNil(reopened.cardDrafts.first { $0.id == originalEditorID })
        XCTAssertNotNil(reopened.cardDrafts.first { $0.id == incoming.id })
    }

    @MainActor func testClosingOrDiscardingOriginalDoesNotAuthorizeJumpFromNil() throws {
        for discard in [false, true] {
            let (store, _, _, _, incoming, _) = try makeContext()
            store.cardEditor?.card.back = "暂存的原卡修改"
            if discard { store.discardAndCloseEditor(.card) }
            else { store.keepAndCloseEditor(.card) }
            XCTAssertNil(store.cardEditor)
            XCTAssertFalse(store.canReturnToIncomingCardDraft)
            XCTAssertFalse(store.returnToIncomingCardDraft())
            XCTAssertNil(store.cardEditor)
            XCTAssertNotNil(store.savedCardDrafts.first { $0.id == incoming.id })
        }
    }

    @MainActor func testMissingIncomingDraftLeavesCurrentOriginalUnchanged() throws {
        let (store, db, persistence, original, incoming, _) = try makeContext()
        store.cardEditor?.card.back = "原卡当前输入"
        let current = try XCTUnwrap(store.cardEditor)
        try persistence.removeCard(id: incoming.id)

        XCTAssertFalse(store.canReturnToIncomingCardDraft)
        XCTAssertFalse(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, current.id)
        XCTAssertEqual(store.cardEditor?.card, current.card)
        XCTAssertNotNil(store.cardEditor?.error)
        XCTAssertEqual(try db.card(id: original.id!), original)
    }

    @MainActor func testDraftWriteFailureRefusesReturnAndCanRetryWithoutLosingEitherInput() throws {
        let (store, db, persistence, original, incoming, directory) = try makeContext()
        let originalEditorID = try XCTUnwrap(store.cardEditor?.id)
        try FileManager.default.removeItem(at: directory)
        try Data("阻止草稿目录写入".utf8).write(to: directory)
        store.cardEditor?.card.back = "写入失败时的原卡修改"

        XCTAssertFalse(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, originalEditorID)
        XCTAssertEqual(store.cardEditor?.card.back, "写入失败时的原卡修改")
        XCTAssertNotNil(store.draftSaveError)
        XCTAssertNotNil(store.cardWorkflow.duplicateReturn)
        XCTAssertNotNil(persistence.cardDrafts.first { $0.id == incoming.id })
        XCTAssertEqual(try db.card(id: original.id!), original)

        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(store.returnToIncomingCardDraft())
        let reopened = try EditorDraftPersistence(directory: directory)
        XCTAssertEqual(reopened.cardDrafts.first { $0.id == originalEditorID }?.card.back, "写入失败时的原卡修改")
        XCTAssertEqual(reopened.cardDrafts.first { $0.id == incoming.id }?.card, incoming.card)
    }

    @MainActor func testBackupBusyLeavesBothDraftsAndContextInPlace() throws {
        let (store, _, persistence, _, incoming, _) = try makeContext()
        let originalEditorID = try XCTUnwrap(store.cardEditor?.id)
        store.cardEditor?.card.back = "原卡修改"
        store.fullBackupBusy = true

        XCTAssertFalse(store.canReturnToIncomingCardDraft)
        XCTAssertFalse(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, originalEditorID)
        XCTAssertEqual(store.cardEditor?.card.back, "原卡修改")
        XCTAssertNotNil(store.cardWorkflow.duplicateReturn)
        XCTAssertNotNil(persistence.cardDrafts.first { $0.id == incoming.id })
    }

    @MainActor func testIncomingExistingCardChangedElsewhereRestoresAsNewWithoutOverwritingProgress() throws {
        let directory = try temporaryDirectory()
        let db = try AppDatabase(DatabaseQueue())
        let target = try db.save(Card(front: "重复问题", back: "目标答案"))
        let edited = try db.save(Card(front: "原来独立的问题", back: "另一答案", state: .review, interval: 20, reps: 8))
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.editCard(edited)
        store.cardEditor?.card.front = "重复问题"
        store.cardEditor?.card.back = "本次未保存输入"
        let incoming = try XCTUnwrap(store.cardEditor)
        XCTAssertTrue(store.editOriginalDuplicate(target))
        var elsewhere = try XCTUnwrap(db.card(id: edited.id!))
        elsewhere.back = "其他窗口已保存内容"
        elsewhere.reps = 19; elsewhere.interval = 45
        _ = try db.save(elsewhere)
        let latest = try XCTUnwrap(db.card(id: edited.id!))

        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertNil(store.cardEditor?.card.id)
        XCTAssertEqual(store.cardEditor?.card.back, "本次未保存输入")
        XCTAssertEqual(store.cardEditor?.card.state, .new)
        XCTAssertEqual(store.cardEditor?.card.reps, 0)
        XCTAssertTrue(store.draftRecoveryNotice?.contains("新卡") == true)
        XCTAssertEqual(try db.card(id: edited.id!), latest)
        XCTAssertNil(try EditorDraftPersistence(directory: directory).cardDrafts.first { $0.id == incoming.id }?.card.id)
    }

    @MainActor func testReturningDetachesMissingOriginalHighlightAndExplainsWhy() throws {
        let directory = try temporaryDirectory()
        let db = try AppDatabase(DatabaseQueue())
        let original = try db.save(Card(front: "Question", back: "原卡答案"))
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "Question"
        store.cardEditor?.card.back = "从已删除摘录产生的输入"
        store.cardEditor?.card.highlightId = 999
        XCTAssertTrue(store.editOriginalDuplicate(original))

        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertNil(store.cardEditor?.card.highlightId)
        XCTAssertTrue(store.draftRecoveryNotice?.contains("解除关联") == true)
        XCTAssertNil(try EditorDraftPersistence(directory: directory).cardDrafts.first?.card.highlightId)
    }

    @MainActor func testDifferentEditorSessionCannotUseStaleReturnContext() throws {
        let (store, _, _, _, incoming, _) = try makeContext()
        store.cardEditor = CardDraft(card: Card(front: "另一份输入", back: "另一答案"))
        let unrelated = try XCTUnwrap(store.cardEditor)

        XCTAssertFalse(store.canReturnToIncomingCardDraft)
        XCTAssertFalse(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, unrelated.id)
        XCTAssertEqual(store.cardEditor?.card, unrelated.card)
        XCTAssertNotNil(store.savedCardDrafts.first { $0.id == incoming.id })
    }

    @MainActor func testNewSessionClearsReturnContextButRetainsBothSavedDrafts() throws {
        let (store, _, _, _, incoming, _) = try makeContext()
        let originalEditorID = try XCTUnwrap(store.cardEditor?.id)
        store.cardEditor?.card.back = "已保留的原卡草稿"
        store.newCard(deck: "新会话")

        XCTAssertNil(store.cardWorkflow.duplicateReturn)
        XCTAssertFalse(store.canReturnToIncomingCardDraft)
        XCTAssertNotNil(store.savedCardDrafts.first { $0.id == originalEditorID })
        XCTAssertNotNil(store.savedCardDrafts.first { $0.id == incoming.id })
    }

    @MainActor func testChainedOriginalEditingReturnsToNearestInputAndKeepsEarlierInput() throws {
        let (store, db, _, _, incoming, directory) = try makeContext()
        let nextOriginal = try db.save(Card(front: "第二个问题", back: "第二张原卡答案"))
        store.cardEditor?.card.front = "第二个问题"
        store.cardEditor?.card.back = "中间原卡尚未保存的内容"
        let middle = try XCTUnwrap(store.cardEditor)

        XCTAssertTrue(store.editOriginalDuplicate(nextOriginal))
        XCTAssertEqual(store.cardWorkflow.duplicateReturn?.incomingID, middle.id)
        XCTAssertTrue(store.draftRecoveryNotice?.contains("更早的输入") == true)
        XCTAssertTrue(store.returnToIncomingCardDraft())
        XCTAssertEqual(store.cardEditor?.id, middle.id)
        XCTAssertEqual(store.cardEditor?.card, middle.card)
        let reopened = try EditorDraftPersistence(directory: directory)
        XCTAssertEqual(reopened.cardDrafts.first { $0.id == incoming.id }?.card, incoming.card)
        XCTAssertEqual(reopened.cardDrafts.first { $0.id == middle.id }?.card, middle.card)
    }
}
