import XCTest
import KongReviewCore
@testable import KongReview

final class V25DraftTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KongReviewDraftTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testHighlightRoundTripPreservesAllEditorFieldsAndEditionPages() throws {
        let directory = temporaryDirectory()
        let persistence = try EditorDraftPersistence(directory: directory)
        var highlight = Highlight(sourceId: 17, text: "<p>原文<strong>最后输入</strong></p>",
                                  translation: "白话", note: "按语", location: "卷二，第 27 页", tags: ["原标签"])
        highlight.frequency = -1
        var draft = HighlightDraft(highlight: highlight, tagsText: "原标签，新增/标签")
        draft.newSourceTitle = "新出处"
        draft.newSourceAuthor = "作者"
        draft.newSourceKind = .web
        draft.newSourceURL = "https://example.com/材料"
        draft.showNewSource = true
        draft.editionPages = [29: "42", 30: "卷三·7"]
        try persistence.recordHighlight(draft)

        // 不等定时器、不显式 flush：重新启动即可读到最后输入。
        let saved = try XCTUnwrap(EditorDraftPersistence(directory: directory).highlightDrafts.first)
        let restored = saved.restored(current: nil).draft
        XCTAssertEqual(restored.id, draft.id)
        XCTAssertEqual(restored.highlight, draft.highlight)
        XCTAssertEqual(restored.tagsText, draft.tagsText)
        XCTAssertEqual(restored.newSourceTitle, draft.newSourceTitle)
        XCTAssertEqual(restored.newSourceAuthor, draft.newSourceAuthor)
        XCTAssertEqual(restored.newSourceURL, draft.newSourceURL)
        XCTAssertEqual(restored.newSourceKind, .web)
        XCTAssertTrue(restored.showNewSource)
        XCTAssertEqual(restored.editionPages, draft.editionPages)
    }

    func testCardRoundTripPreservesTemplateFieldsSectionsTagsAndSchedule() throws {
        let directory = temporaryDirectory()
        let persistence = try EditorDraftPersistence(directory: directory)
        var card = Card(id: 12, deck: "古籍", front: "旧正面", back: "答案", tags: ["旧标签"],
                        state: .review, interval: 30, reps: 12, lapses: 2)
        card.noteType = "三字段"
        card.fields = ["题目", "译文", "出处"]
        card.sections = [CardSection(name: "注释", text: "完整栏目\n第二行", folded: true)]
        card.stability = 28.3
        card.difficulty = 5.4
        card.lastReview = Date()
        var draft = CardDraft(card: card, tagsText: "旧标签 #新增标签")
        draft.card.fields[1] += "最后编辑"
        try persistence.recordCard(draft, original: card)

        let saved = try XCTUnwrap(EditorDraftPersistence(directory: directory).cardDrafts.first)
        let recovery = saved.restored(current: card)
        XCTAssertNil(recovery.notice)
        XCTAssertEqual(recovery.draft.id, draft.id)
        XCTAssertEqual(recovery.draft.card, draft.card)
        XCTAssertEqual(recovery.draft.tagsText, draft.tagsText)
        XCTAssertEqual(recovery.draft.card.sections?.first?.folded, true)
    }

    func testUnchangedExistingAndEmptyNewFormsDoNotCreateRecoverableDrafts() throws {
        let directory = temporaryDirectory()
        let persistence = try EditorDraftPersistence(directory: directory)
        let highlight = Highlight(id: 1, text: "原文", tags: ["专题"])
        let card = Card(id: 2, front: "问题", tags: ["标签"])
        try persistence.recordHighlight(HighlightDraft(highlight: highlight, tagsText: "专题"), original: highlight)
        try persistence.recordCard(CardDraft(card: card, tagsText: "标签"), original: card)
        try persistence.recordHighlight(HighlightDraft(highlight: Highlight(text: "")))
        try persistence.recordCard(CardDraft(card: Card(deck: "其他牌组", front: "")))
        XCTAssertTrue(persistence.highlightDrafts.isEmpty)
        XCTAssertTrue(persistence.cardDrafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    func testFirstKeystrokeRetainsOpeningBaselineAndRevertingRemovesRecoveryEntry() throws {
        let persistence = try EditorDraftPersistence(directory: temporaryDirectory())
        let original = Highlight(id: 1, text: "打开时的原文")
        var draft = HighlightDraft(highlight: original)
        try persistence.recordHighlight(draft)
        draft.highlight.text += "第一字"
        try persistence.recordHighlight(draft)
        XCTAssertEqual(persistence.highlightDrafts.first?.original, original)
        XCTAssertEqual(persistence.highlightDrafts.first?.highlight.text, draft.highlight.text)
        draft.highlight = original
        try persistence.recordHighlight(draft)
        XCTAssertTrue(persistence.highlightDrafts.isEmpty)
    }

    func testOriginalBaselineIsNotReplacedWhenDatabaseChangesDuringEditing() throws {
        let persistence = try EditorDraftPersistence(directory: temporaryDirectory())
        let original = Card(id: 1, front: "问题", back: "旧答案")
        var draft = CardDraft(card: original)
        try persistence.recordCard(draft, original: original)
        draft.card.back = "我的修改"
        var concurrentUpdate = original
        concurrentUpdate.back = "其他窗口的修改"
        try persistence.recordCard(draft, original: concurrentUpdate)
        XCTAssertEqual(persistence.cardDrafts.first?.original, original)
        let restored = try XCTUnwrap(persistence.cardDrafts.first).restored(current: concurrentUpdate)
        XCTAssertNil(restored.draft.card.id)
        XCTAssertEqual(restored.draft.card.back, "我的修改")
        XCTAssertNotNil(restored.notice)
    }

    func testIndependentDraftsSurviveRestartAndOnlySelectedOneIsRemoved() throws {
        let directory = temporaryDirectory()
        let persistence = try EditorDraftPersistence(directory: directory)
        let first = HighlightDraft(highlight: Highlight(text: "第一份草稿"))
        let second = HighlightDraft(highlight: Highlight(text: "第二份草稿"))
        let card = CardDraft(card: Card(front: "独立卡片草稿"))
        try persistence.recordHighlight(first)
        try persistence.recordHighlight(second)
        try persistence.recordCard(card)
        try persistence.flush()

        let reopened = try EditorDraftPersistence(directory: directory)
        XCTAssertEqual(Set(reopened.highlightDrafts.map(\.id)), [first.id, second.id])
        XCTAssertEqual(reopened.cardDrafts.map(\.id), [card.id])
        try reopened.removeHighlight(id: first.id)
        let afterSave = try EditorDraftPersistence(directory: directory)
        XCTAssertEqual(afterSave.highlightDrafts.map(\.id), [second.id])
        XCTAssertEqual(afterSave.cardDrafts.map(\.id), [card.id])
        try afterSave.removeCard(id: card.id)
        XCTAssertTrue(try EditorDraftPersistence(directory: directory).cardDrafts.isEmpty)
    }

    func testDeletedHighlightRecoversAsNewWithoutOldReviewState() throws {
        let persistence = try EditorDraftPersistence(directory: temporaryDirectory())
        let original = Highlight(id: 1, text: "原文", lastSurfacedAt: Date(), surfacedCount: 9,
                                 masteryHalfLifeDays: 20, masteryLastReviewedAt: Date())
        var draft = HighlightDraft(highlight: original)
        draft.highlight.note = "还没保存的按语"
        try persistence.recordHighlight(draft, original: original)
        let recovery = try XCTUnwrap(persistence.highlightDrafts.first).restored(current: nil)
        XCTAssertNotNil(recovery.notice)
        XCTAssertNil(recovery.draft.highlight.id)
        XCTAssertEqual(recovery.draft.highlight.note, "还没保存的按语")
        XCTAssertEqual(recovery.draft.highlight.surfacedCount, 0)
        XCTAssertNil(recovery.draft.highlight.masteryHalfLifeDays)
        XCTAssertNil(recovery.draft.highlight.deletedAt)
    }

    func testEditionPageChangeAlsoPreventsSilentOverwrite() throws {
        let persistence = try EditorDraftPersistence(directory: temporaryDirectory())
        let original = Highlight(id: 1, text: "原文")
        var draft = HighlightDraft(highlight: original)
        draft.editionPages = [7: "自己的页码"]
        try persistence.recordHighlight(draft, original: original, originalEditionPages: [7: "旧页码"])
        let recovery = try XCTUnwrap(persistence.highlightDrafts.first)
            .restored(current: original, currentEditionPages: [7: "其他窗口的新页码"])
        XCTAssertNil(recovery.draft.highlight.id)
        XCTAssertEqual(recovery.draft.editionPages, [7: "自己的页码"])
        XCTAssertNotNil(recovery.notice)
    }

    func testChangedCardLearningStateIsPreservedByRecoveringDraftAsNewCard() throws {
        let persistence = try EditorDraftPersistence(directory: temporaryDirectory())
        var original = Card(id: 1, front: "问题", back: "答案", state: .review,
                            interval: 40, reps: 20, lapses: 3, ankiGuid: "anki-guid")
        original.stability = 33
        original.difficulty = 4
        original.lastReview = Date()
        var draft = CardDraft(card: original)
        draft.card.back = "尚未保存的新答案"
        try persistence.recordCard(draft, original: original)
        var learned = original
        learned.reps += 1
        learned.interval = 80
        let recovery = try XCTUnwrap(persistence.cardDrafts.first).restored(current: learned)
        XCTAssertNotNil(recovery.notice)
        XCTAssertNil(recovery.draft.card.id)
        XCTAssertEqual(recovery.draft.card.back, "尚未保存的新答案")
        XCTAssertEqual(recovery.draft.card.state, .new)
        XCTAssertEqual(recovery.draft.card.reps, 0)
        XCTAssertEqual(recovery.draft.card.interval, 0)
        XCTAssertNil(recovery.draft.card.stability)
        XCTAssertNil(recovery.draft.card.ankiGuid)
        XCTAssertEqual(learned.reps, 21)
        XCTAssertEqual(learned.interval, 80)
    }

    func testCorruptDraftFileIsPreservedAndNotSilentlyReplaced() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("editor-drafts.json")
        let broken = Data("incomplete draft file".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try EditorDraftPersistence(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testUnsupportedVersionIsPreservedForNewerApp() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("editor-drafts.json")
        let future = Data(#"{"version":99,"highlights":[],"cards":[]}"#.utf8)
        try future.write(to: file)
        XCTAssertThrowsError(try EditorDraftPersistence(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
}
