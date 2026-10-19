import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V381DuplicateEditorTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KongReview-duplicate-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func saved(_ card: Card, in db: AppDatabase) throws -> Card {
        let result = try db.save(card)
        return try XCTUnwrap(db.card(id: result.id!))
    }

    @MainActor func testOpeningOriginalDurablyRetainsIncomingCardAndCanRecoverItAfterRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(deck: "原牌组", front: "Question", back: "原答案", tags: ["旧标签"],
                                       state: .review, interval: 30, reps: 12), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: "输入牌组")
        store.cardEditor?.card.front = " <p>QUESTION</p> "
        store.cardEditor?.card.back = "还没保存的补充答案"
        store.cardEditor?.card.sections = [CardSection(name: "按语", text: "独立补充")]
        store.cardEditor?.tagsText = "新标签 #待整理"
        let incoming = try XCTUnwrap(store.cardEditor)

        XCTAssertTrue(store.editOriginalDuplicate(original))
        XCTAssertEqual(store.cardEditor?.card.id, original.id)
        XCTAssertEqual(store.cardEditor?.card.back, "原答案")
        XCTAssertEqual(store.cardEditor?.card.reps, 12)
        XCTAssertEqual(store.cardEditor?.card.interval, 30)
        XCTAssertEqual(store.cardEditor?.tagsText, TagParser.format(original.tags))
        XCTAssertEqual(try db.cardCount(), 1, "Opening an original must not save the incoming duplicate")
        XCTAssertEqual(try db.card(id: original.id!), original)
        XCTAssertNotNil(store.draftRecoveryNotice)

        let reopened = try EditorDraftPersistence(directory: directory)
        let retained = try XCTUnwrap(reopened.cardDrafts.first { $0.id == incoming.id })
        XCTAssertEqual(retained.card, incoming.card)
        XCTAssertEqual(retained.tagsText, incoming.tagsText)
        let restarted = LibraryStore(db: db, draftPersistence: reopened)
        restarted.scheduleDraftRecovery(id: incoming.id, kind: .card)
        restarted.performPendingDraftRecovery()
        XCTAssertEqual(restarted.cardEditor?.id, incoming.id)
        XCTAssertEqual(restarted.cardEditor?.card, incoming.card)
        XCTAssertEqual(restarted.cardEditor?.tagsText, incoming.tagsText)
    }

    @MainActor func testOpeningOriginalReloadsLatestAnswerProgressDeckAndTags() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let cached = try saved(Card(deck: "旧牌组", front: "同一问题", back: "旧答案"), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "同一问题"
        store.cardEditor?.card.back = "本次输入"
        var latest = cached
        latest.back = "别人刚补充的答案"
        latest.deck = "新牌组"
        latest.tags = ["最新标签"]
        latest.reps = 21; latest.interval = 45; latest.state = .review
        latest.stability = 28; latest.difficulty = 4.2
        latest = try saved(latest, in: db)

        XCTAssertTrue(store.editOriginalDuplicate(cached))
        XCTAssertEqual(store.cardEditor?.card, latest)
        XCTAssertEqual(store.cardEditor?.tagsText, TagParser.format(latest.tags))
        XCTAssertEqual(try db.card(id: latest.id!), latest)
        XCTAssertEqual(store.savedCardDrafts.first?.card.back, "本次输入")
    }

    @MainActor func testMissingAndDeletedTargetsLeaveCurrentInputIntact() throws {
        for permanentlyDeleted in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let cached = try saved(Card(front: "重复问题", back: "原答案"), in: db)
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.newCard(deck: nil)
            store.cardEditor?.card.front = "重复问题"
            store.cardEditor?.card.back = "保留输入"
            let incoming = try XCTUnwrap(store.cardEditor)
            if permanentlyDeleted {
                try db.deleteCards([cached.id!])
            } else {
                var deleted = cached; deleted.deletedAt = Date()
                try db.save(deleted)
            }

            XCTAssertFalse(store.editOriginalDuplicate(cached))
            XCTAssertEqual(store.cardEditor?.id, incoming.id)
            XCTAssertEqual(store.cardEditor?.card, incoming.card)
            XCTAssertNotNil(store.cardEditor?.error)
            XCTAssertEqual(try EditorDraftPersistence(directory: directory).cardDrafts.first?.card, incoming.card)
        }
    }

    @MainActor func testChangedIncomingFrontAndChangedOriginalFrontRejectStaleWarning() throws {
        for changedIncoming in [true, false] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let cached = try saved(Card(front: "重复问题", back: "原答案"), in: db)
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.newCard(deck: nil)
            store.cardEditor?.card.front = "重复问题"
            store.cardEditor?.card.back = "保留输入"
            store.cardEditor?.duplicate = cached
            if changedIncoming {
                store.cardEditor?.card.front = "已经改成独立问题"
            } else {
                var updated = cached; updated.front = "原卡已经改题"
                try db.save(updated)
            }
            let incoming = try XCTUnwrap(store.cardEditor)

            XCTAssertFalse(store.editOriginalDuplicate(cached))
            XCTAssertEqual(store.cardEditor?.id, incoming.id)
            XCTAssertEqual(store.cardEditor?.card, incoming.card)
            XCTAssertTrue(store.cardEditor?.error?.contains("变化") == true)
            XCTAssertEqual(try db.cardCount(), 1)
        }
    }

    @MainActor func testRestoredOriginalOpensEvenWhenWarningSnapshotStillSaysDeleted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let deletedSnapshot = try saved(Card(front: "恢复的问题", back: "恢复答案", reps: 8, deletedAt: Date()), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "恢复的问题"
        store.cardEditor?.card.back = "保留输入"
        try db.restoreInputDuplicate(id: deletedSnapshot.id!)

        XCTAssertTrue(store.editOriginalDuplicate(deletedSnapshot))
        XCTAssertEqual(store.cardEditor?.card.id, deletedSnapshot.id)
        XCTAssertNil(store.cardEditor?.card.deletedAt)
        XCTAssertEqual(store.cardEditor?.card.reps, 8)
    }

    @MainActor func testUnavailableDraftPersistenceRefusesSwitchWithoutLosingInput() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front: "重复问题", back: "原答案"), in: db)
        let store = LibraryStore(db: db)
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "重复问题"
        store.cardEditor?.card.back = "没有落盘的内容"
        let incoming = try XCTUnwrap(store.cardEditor)

        XCTAssertFalse(store.editOriginalDuplicate(original))
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertNotNil(store.draftSaveError)
        XCTAssertNotNil(store.cardEditor?.error)
        XCTAssertEqual(try db.card(id: original.id!), original)
    }

    @MainActor func testDraftWriteFailureRefusesSwitchAndReportsRecoverableError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front: "重复问题", back: "原答案"), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: blocked))
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "重复问题"
        store.cardEditor?.card.back = "写入失败仍须保留"
        let incoming = try XCTUnwrap(store.cardEditor)

        XCTAssertFalse(store.editOriginalDuplicate(original))
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertNotNil(store.draftSaveError)
        XCTAssertNotNil(store.cardEditor?.error)
        XCTAssertEqual(try db.card(id: original.id!), original)
        XCTAssertEqual(try db.cardCount(), 1)
    }

    @MainActor func testFullBackupBusyRefusesSwitch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front: "重复问题"), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "重复问题"
        let incoming = try XCTUnwrap(store.cardEditor)
        store.fullBackupBusy = true

        XCTAssertFalse(store.editOriginalDuplicate(original))
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertTrue(store.cardEditor?.error?.contains("完整备份") == true)
    }

    @MainActor func testEditedExistingCardIsRetainedAgainstItsOwnOriginalBaseline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front: "重复问题", back: "原答案"), in: db)
        let edited = try saved(Card(front: "原本独立的问题", back: "另一答案", reps: 7), in: db)
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.editCard(edited)
        store.cardEditor?.card.front = "重复问题"
        store.cardEditor?.card.back = "修改但未保存"
        store.cardEditor?.tagsText = "未保存标签"
        let incoming = try XCTUnwrap(store.cardEditor)

        XCTAssertTrue(store.editOriginalDuplicate(original))
        let saved = try XCTUnwrap(try EditorDraftPersistence(directory: directory).cardDrafts.first { $0.id == incoming.id })
        XCTAssertEqual(saved.original, edited)
        XCTAssertEqual(saved.card, incoming.card)
        XCTAssertEqual(saved.restored(current: edited).draft.card.id, edited.id)
        XCTAssertEqual(try db.card(id: edited.id!), edited)
        XCTAssertEqual(try db.card(id: original.id!), original)
    }
}
