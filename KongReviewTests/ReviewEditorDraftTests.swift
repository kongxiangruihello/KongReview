import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class ReviewEditorDraftTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-drafts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testNoteSurvivesItemScopeAndApplicationChanges() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "长摘录", note: "原按语"))
            let state = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            state.beginNote(for: highlight)
            state.noteDraft = "尚未保存的完整按语"
            state.position = 1
            XCTAssertNil(state.noteDraft)
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.note, "原按语")
            state.resumeEditor(for: highlight)
            XCTAssertEqual(state.noteDraft, "尚未保存的完整按语")
            state.theme = "历史"
            XCTAssertNil(state.noteDraft)
            let restarted = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            restarted.resumeEditor(for: highlight)
            XCTAssertEqual(restarted.noteDraft, "尚未保存的完整按语")
            XCTAssertEqual(try EditorDraftPersistence(directory: url).highlightDrafts.count, 1)
            _ = try restarted.saveCurrentEditor()
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.note, "尚未保存的完整按语")
            XCTAssertTrue(try EditorDraftPersistence(directory: url).highlightDrafts.isEmpty)
        }
    }

    func testInlineFieldsPersistOnEveryInputWithoutWaitingForClose() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "原文", translation: "原译文", note: "原按语"))
            let state = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            state.beginInline(for: highlight)
            state.inlineDraft?.text = "新原文"
            state.inlineDraft?.translation = "新译文"
            state.inlineDraft?.note = "新按语"
            let restarted = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            restarted.resumeEditor(for: highlight)
            XCTAssertEqual(restarted.inlineDraft?.text, "新原文")
            XCTAssertEqual(restarted.inlineDraft?.translation, "新译文")
            XCTAssertEqual(restarted.inlineDraft?.note, "新按语")
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.text, "原文")
        }
    }

    func testSaveMergesLatestReviewProgressFavoriteAndTags() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "原文"))
            let state = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            state.beginInline(for: highlight)
            state.inlineDraft?.text = "修改的原文"
            var current = highlight
            current.isFavorite = true; current.surfacedCount = 8; current.tags = ["新标签"]
            try db.save(current)
            _ = try state.saveCurrentEditor()
            let saved = try XCTUnwrap(db.highlight(id: highlight.id!))
            XCTAssertEqual(saved.text, "修改的原文")
            XCTAssertTrue(saved.isFavorite)
            XCTAssertEqual(saved.surfacedCount, 8)
            XCTAssertEqual(saved.tags, ["新标签"])
        }
    }

    func testNewerInlineContentPreventsSaveAndRemainsRecoverable() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "最初原文"))
            let persistence = try EditorDraftPersistence(directory: url)
            let state = ReviewState(db: db, persistence: persistence)
            state.beginInline(for: highlight)
            state.inlineDraft?.text = "草稿中的原文"
            var current = highlight; current.text = "其他编辑器的新原文"
            try db.save(current)
            XCTAssertThrowsError(try state.saveCurrentEditor())
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.text, "其他编辑器的新原文")
            state.leaveCurrentEditor()
            state.resumeEditor(for: try XCTUnwrap(db.highlight(id: highlight.id!)))
            XCTAssertNil(state.inlineDraft)
            XCTAssertNotNil(state.draftNotice)
            XCTAssertEqual(persistence.highlightDrafts.first?.highlight.text, "草稿中的原文")
            XCTAssertNil(persistence.highlightDrafts.first?.restored(current: current).draft.highlight.id)
        }
    }

    func testNoteSavePreservesConcurrentOriginalTextEdit() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "原文", note: "旧按语"))
            let state = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: url))
            state.beginNote(for: highlight); state.noteDraft = "新按语"
            var current = highlight; current.text = "后来更新的原文"
            try db.save(current)
            _ = try state.saveCurrentEditor()
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.text, "后来更新的原文")
            XCTAssertEqual(try db.highlight(id: highlight.id!)?.note, "新按语")
        }
    }

    func testDeletedOriginalAndFailedValidationKeepDraft() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "原文"))
            let persistence = try EditorDraftPersistence(directory: url)
            let state = ReviewState(db: db, persistence: persistence)
            state.beginInline(for: highlight); state.inlineDraft?.text = " "
            XCTAssertThrowsError(try state.saveCurrentEditor())
            XCTAssertNotNil(state.inlineDraft)
            state.inlineDraft?.text = "仍需保留的输入"
            try db.moveToTrash(highlight)
            XCTAssertThrowsError(try state.saveCurrentEditor())
            XCTAssertEqual(persistence.highlightDrafts.first?.highlight.text, "仍需保留的输入")
        }
    }

    func testOpeningUntouchedEditorDoesNotCreateDraftAndDiscardRemovesOnlyItsDraft() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let first = try db.save(Highlight(text: "第一条"))
            let second = try db.save(Highlight(text: "第二条"))
            let persistence = try EditorDraftPersistence(directory: url)
            let state = ReviewState(db: db, persistence: persistence)
            state.beginNote(for: first)
            XCTAssertTrue(persistence.highlightDrafts.isEmpty)
            state.noteDraft = "保留第一份"
            state.beginInline(for: second)
            state.inlineDraft?.text = "放弃第二份"
            XCTAssertEqual(persistence.highlightDrafts.count, 2)
            state.discardCurrentEditor()
            XCTAssertEqual(persistence.highlightDrafts.count, 1)
            XCTAssertEqual(persistence.highlightDrafts.first?.highlight.id, first.id)
            XCTAssertEqual(try db.highlight(id: second.id!)?.text, "第二条")
        }
    }

    func testFailedDiskWriteStillRecoversOnItemReturnInMemory() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let blocked = url.appendingPathComponent("blocked")
            try Data("file".utf8).write(to: blocked)
            let db = try AppDatabase(DatabaseQueue())
            let highlight = try db.save(Highlight(text: "原文"))
            let state = ReviewState(db: db, persistence: try EditorDraftPersistence(directory: blocked))
            var error: String?
            state.onDraftChange = { error = $0 }
            state.beginNote(for: highlight); state.noteDraft = "磁盘失败仍保留"
            XCTAssertNotNil(error)
            state.leaveCurrentEditor(); state.resumeEditor(for: highlight)
            XCTAssertEqual(state.noteDraft, "磁盘失败仍保留")
        }
    }

    func testReadingPositionsSeparateItemsScopesAndDaysAndSurviveRestart() {
        MainActor.assumeIsolated {
            let suite = "review-reading-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = ReviewReadingPositions.owner(day: "2026-10-17", scope: nil, highlightID: 1)
            let next = ReviewReadingPositions.owner(day: "2026-10-17", scope: nil, highlightID: 2)
            let theme = ReviewReadingPositions.owner(day: "2026-10-17", scope: "历史", highlightID: 1)
            let tomorrow = ReviewReadingPositions.owner(day: "2026-10-18", scope: nil, highlightID: 1)
            let reading = ReviewReadingPositions(defaults: defaults)
            reading.save(1570, for: first)
            XCTAssertEqual(reading.offset(for: next), 0)
            XCTAssertEqual(reading.offset(for: theme), 0)
            XCTAssertEqual(reading.offset(for: tomorrow), 0)
            XCTAssertEqual(ReviewReadingPositions(defaults: defaults).offset(for: first), 1570)
            reading.save(.infinity, for: first)
            XCTAssertEqual(reading.offset(for: first), 1570)
            reading.save(-20, for: first)
            XCTAssertEqual(reading.offset(for: first), 0)
        }
    }

    func testReviewDraftTransferredToFullEditorKeepsExtraFieldsAndClearsAfterSave() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Highlight(text: "原文"))
            let persistence = try EditorDraftPersistence(directory: url)
            let store = LibraryStore(db: db, draftPersistence: persistence)
            store.review.beginInline(for: original)
            store.review.inlineDraft?.text = "回顾编辑的原文"
            let id = try XCTUnwrap(persistence.highlightDrafts.first?.id)
            store.scheduleDraftRecovery(id: id, kind: .highlight)
            store.performPendingDraftRecovery()
            XCTAssertNil(store.review.inlineDraft)
            XCTAssertEqual(store.editorDraft?.highlight.text, "回顾编辑的原文")
            XCTAssertNil(persistence.highlightDrafts.first?.reviewMode)
            store.editorDraft?.tagsText = "完整面板新增标签"
            store.editorDraft?.highlight.location = "新增页码"
            store.keepAndCloseEditor(.highlight)
            store.review.resumeEditor(for: original)
            XCTAssertNil(store.review.inlineDraft)
            XCTAssertEqual(persistence.highlightDrafts.first?.tagsText, "完整面板新增标签")
            XCTAssertEqual(persistence.highlightDrafts.first?.highlight.location, "新增页码")
            store.scheduleDraftRecovery(id: id, kind: .highlight)
            store.performPendingDraftRecovery()
            store.commit(try XCTUnwrap(store.editorDraft))
            XCTAssertTrue(persistence.highlightDrafts.isEmpty)
            let saved = try XCTUnwrap(db.highlight(id: original.id!))
            XCTAssertEqual(saved.text, "回顾编辑的原文")
            XCTAssertEqual(saved.tags, ["完整面板新增标签"])
            XCTAssertEqual(saved.location, "新增页码")
        }
    }

    func testCrossingNoteAndInlineModesRetainsBothSetsOfUnsubmittedChanges() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Highlight(text: "原文"))
            let persistence = try EditorDraftPersistence(directory: url)
            let review = ReviewState(db: db, persistence: persistence)
            review.beginNote(for: original); review.noteDraft = "尚未保存的按语"
            review.beginInline(for: original)
            XCTAssertEqual(review.inlineDraft?.note, "尚未保存的按语")
            review.inlineDraft?.text = "尚未保存的新原文"
            review.beginNote(for: original)
            XCTAssertNil(review.noteDraft)
            XCTAssertEqual(review.inlineDraft?.text, "尚未保存的新原文")
            XCTAssertEqual(review.inlineDraft?.note, "尚未保存的按语")
            XCTAssertEqual(persistence.highlightDrafts.count, 1)
            _ = try review.saveCurrentEditor()
            XCTAssertEqual(try db.highlight(id: original.id!)?.text, "尚未保存的新原文")
            XCTAssertEqual(try db.highlight(id: original.id!)?.note, "尚未保存的按语")
            XCTAssertTrue(persistence.highlightDrafts.isEmpty)
        }
    }

    func testDiscardingActiveReviewDraftFromRecoveryListDoesNotRecreateItOnLeave() throws {
        try MainActor.assumeIsolated {
            let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
            let db = try AppDatabase(DatabaseQueue())
            let original = try db.save(Highlight(text: "原文"))
            let persistence = try EditorDraftPersistence(directory: url)
            let store = LibraryStore(db: db, draftPersistence: persistence)
            store.review.beginNote(for: original); store.review.noteDraft = "明确放弃的按语"
            let id = try XCTUnwrap(persistence.highlightDrafts.first?.id)
            store.draftPendingDiscard = EditorDraftSelection(id: id, kind: .highlight)
            store.discardSavedDraft()
            XCTAssertNil(store.review.noteDraft)
            store.review.leaveCurrentEditor()
            XCTAssertTrue(persistence.highlightDrafts.isEmpty)
            XCTAssertNil(try db.highlight(id: original.id!)?.note)
        }
    }
}
