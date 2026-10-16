import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V250DraftIntegrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-draft-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCardDraftSurvivesCloseAndRestartAndClearsOnlyAfterSuccessfulSave() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.newCard(deck: "草稿牌组")
            XCTAssertTrue(store.savedCardDrafts.isEmpty)
            store.cardEditor?.card.front = "应恢复的问题"
            store.cardEditor?.card.back = "完整答案"
            let id = try XCTUnwrap(store.cardEditor?.id)
            store.requestCloseCardEditor()
            XCTAssertTrue(store.closingCardEditor)
            store.keepAndCloseEditor(.card)
            XCTAssertNil(store.cardEditor)

            let restarted = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            XCTAssertEqual(restarted.savedCardDrafts.count, 1)
            restarted.scheduleDraftRecovery(id: id, kind: .card)
            restarted.performPendingDraftRecovery()
            XCTAssertEqual(restarted.cardEditor?.card.front, "应恢复的问题")
            XCTAssertEqual(restarted.cardEditor?.card.back, "完整答案")
            restarted.commitCardEditor()
            XCTAssertNil(restarted.cardEditor)
            XCTAssertTrue(restarted.savedCardDrafts.isEmpty)
            XCTAssertEqual(try db.cards().first?.front, "应恢复的问题")
            XCTAssertTrue(try EditorDraftPersistence(directory: directory).cardDrafts.isEmpty)
        }
    }

    func testHighlightSaveClearsDraftAndPreservesOtherUnsavedCard() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Highlight(text: "旧原文"))
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.newCard(deck: nil)
            store.cardEditor?.card.front = "另一份草稿"
            store.keepAndCloseEditor(.card)
            store.edit(original)
            XCTAssertTrue(store.savedHighlightDrafts.isEmpty)
            store.editorDraft?.highlight.text = "保存的新原文"
            store.editorDraft?.tagsText = "历史"
            XCTAssertEqual(store.savedHighlightDrafts.count, 1)
            store.commit(try XCTUnwrap(store.editorDraft))
            XCTAssertEqual(try db.highlight(id: original.id!)?.text, "保存的新原文")
            XCTAssertEqual(try db.highlight(id: original.id!)?.tags, ["历史"])
            XCTAssertTrue(store.savedHighlightDrafts.isEmpty)
            XCTAssertEqual(store.savedCardDrafts.count, 1)
        }
    }

    func testChangedLearningRecordIsNeverOverwrittenByRecoveredDraft() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Card(front: "原问题", back: "原答案"))
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.editCard(try XCTUnwrap(db.card(id: original.id!)))
            store.cardEditor?.card.front = "草稿修改的问题"
            let id = try XCTUnwrap(store.cardEditor?.id)
            store.keepAndCloseEditor(.card)
            var progressed = try XCTUnwrap(db.card(id: original.id!))
            progressed.reps = 9; progressed.interval = 30; progressed.state = .review
            try db.save(progressed)
            let restarted = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            restarted.scheduleDraftRecovery(id: id, kind: .card)
            restarted.performPendingDraftRecovery()
            XCTAssertNil(restarted.cardEditor?.card.id)
            XCTAssertEqual(restarted.cardEditor?.card.front, "草稿修改的问题")
            XCTAssertEqual(restarted.cardEditor?.card.state, .new)
            XCTAssertNotNil(restarted.draftRecoveryNotice)
            XCTAssertEqual(try db.card(id: original.id!)?.reps, 9)
            XCTAssertEqual(try db.card(id: original.id!)?.front, "原问题")
        }
    }

    func testExplicitDiscardLeavesStoredOriginalUnchanged() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Highlight(text: "原文"))
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.edit(original)
            store.editorDraft?.highlight.text = "不保存的修改"
            store.discardAndCloseEditor(.highlight)
            XCTAssertNil(store.editorDraft)
            XCTAssertTrue(store.savedHighlightDrafts.isEmpty)
            XCTAssertEqual(try db.highlight(id: original.id!)?.text, "原文")
        }
    }

    func testRecoveryDropsPermanentlyDeletedSourceAndCanBeSaved() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let source = try db.save(Source(title: "将删除的出处"))
            let highlight = try db.save(Highlight(sourceId: source.id, text: "原文"))
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.edit(highlight)
            store.editorDraft?.highlight.text = "要恢复的原文"
            let id = try XCTUnwrap(store.editorDraft?.id)
            store.keepAndCloseEditor(.highlight)
            try db.deleteSources([source.id!])
            let restarted = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            restarted.scheduleDraftRecovery(id: id, kind: .highlight)
            restarted.performPendingDraftRecovery()
            XCTAssertNil(restarted.editorDraft?.highlight.sourceId)
            XCTAssertNotNil(restarted.draftRecoveryNotice)
            restarted.commit(try XCTUnwrap(restarted.editorDraft))
            XCTAssertNil(restarted.errorMessage)
            XCTAssertTrue(try db.highlights().contains { $0.text == "要恢复的原文" && $0.sourceId == nil })
        }
    }

    func testFailedDraftWriteDoesNotCloseWhenAskedToKeepDraft() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data("file".utf8).write(to: blocked)
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: blocked))
            store.newCard(deck: nil)
            store.cardEditor?.card.front = "尚未落盘"
            XCTAssertNotNil(store.draftSaveError)
            store.keepAndCloseEditor(.card)
            XCTAssertNotNil(store.cardEditor)
        }
    }

    func testDeletedEditionPagesAreRetainedInRecoveredNote() throws {
        try MainActor.assumeIsolated {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try AppDatabase(DatabaseQueue())
            let source = try db.save(Source(title: "原出处"))
            let edition = try db.save(Source(title: "另一版本"))
            let highlight = try db.save(Highlight(sourceId: source.id, text: "原文", note: "原按语"))
            let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            store.edit(highlight)
            store.editorDraft?.editionPages[edition.id!] = "77–79"
            let id = try XCTUnwrap(store.editorDraft?.id)
            store.keepAndCloseEditor(.highlight)
            try db.deleteSources([edition.id!])
            let restarted = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
            restarted.scheduleDraftRecovery(id: id, kind: .highlight)
            restarted.performPendingDraftRecovery()
            XCTAssertTrue(restarted.editorDraft?.editionPages.isEmpty == true)
            XCTAssertTrue(restarted.editorDraft?.highlight.note?.contains("77–79") == true)
            XCTAssertTrue(restarted.editorDraft?.highlight.note?.contains("原按语") == true)
            restarted.commit(try XCTUnwrap(restarted.editorDraft))
            XCTAssertNil(restarted.errorMessage)
            XCTAssertTrue(try db.highlight(id: highlight.id!)?.note?.contains("77–79") == true)
        }
    }

    func testOpeningCachedCardRefreshesLearningStateBeforeEditing() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let cached = try db.save(Card(front: "旧问题"))
            var updated = try XCTUnwrap(db.card(id: cached.id!))
            updated.reps = 6; updated.state = .review; updated.interval = 14
            try db.save(updated)
            let store = LibraryStore(db: db)
            store.editCard(cached)
            XCTAssertEqual(store.cardEditor?.card.reps, 6)
            store.cardEditor?.card.front = "修改问题"
            store.commitCardEditor()
            XCTAssertEqual(try db.card(id: cached.id!)?.reps, 6)
            XCTAssertEqual(try db.card(id: cached.id!)?.interval, 14)
        }
    }
}
