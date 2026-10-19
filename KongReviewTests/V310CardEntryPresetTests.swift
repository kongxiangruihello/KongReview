import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V310CardEntryPresetTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-entry-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    func testOldLibraryStartsEmptyAndPresetsSurviveDatabaseReopening() throws {
        let path = try directory().appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        let db = try AppDatabase(queue)
        XCTAssertEqual(try db.cardEntryPresetLibrary(), CardEntryPresetLibrary())
        let preset = CardEntryPreset(name: "史料分析", deck: "近代史", tags: ["史料"], sections: [.init(name: "出处", folded: true)])
        try db.saveCardEntryPreset(preset)
        try db.setDeckEntryPreset(deck: "晚清", presetID: preset.id)
        try queue.close()
        let reopenedQueue = try DatabaseQueue(path: path)
        defer { try? reopenedQueue.close() }
        let reopened = try AppDatabase(reopenedQueue)
        XCTAssertEqual(try reopened.cardEntryPresetLibrary().presets, [preset])
        XCTAssertEqual(try reopened.cardEntryPresetLibrary().preset(for: "晚清"), preset)
    }

    func testCaptureContainsOnlyMetadataAndIndependentEmptyStructure() throws {
        var card = Card(id: 15, deck: "历史", front: "<img src='old.png'>旧问题", back: "答案 [sound:old.mp3]", tags: ["旧标签"],
                        highlightId: 4, state: .review, interval: 12, reps: 20, ankiGuid: "original")
        card.sections = [CardSection(name: "出处", text: "旧正文", folded: true)]
        card.stability = 8
        let preset = try CardEntryPreset.capture(name: "历史题", card: card, tags: ["新标签"], templates: [:])
        let encoded = String(data: try JSONEncoder().encode(preset), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("old.png"))
        XCTAssertFalse(encoded.contains("旧正文"))
        XCTAssertFalse(encoded.contains("original"))
        let first = try preset.blankCard(templates: [:])
        let second = try preset.blankCard(templates: [:])
        XCTAssertEqual(first.deck, "历史")
        XCTAssertEqual(first.tags, ["新标签"])
        XCTAssertEqual(first.front, "")
        XCTAssertEqual(first.back, "")
        XCTAssertEqual(first.sections?.first?.text, "")
        XCTAssertEqual(first.sections?.first?.folded, true)
        XCTAssertNotEqual(first.sections?.first?.id, card.sections?.first?.id)
        XCTAssertNotEqual(first.sections?.first?.id, second.sections?.first?.id)
        XCTAssertNil(first.id)
        XCTAssertNil(first.highlightId)
        XCTAssertNil(first.ankiGuid)
        XCTAssertEqual(first.state, .new)
        XCTAssertEqual(first.reps, 0)
        XCTAssertNil(first.stability)
    }

    func testNoteTypeReferenceRequiresMatchingExistingFields() throws {
        let template = NoteTemplate(name: "三栏", fieldNames: ["题目", "解释", "出处"], front: [0], back: [1,2], collapsed: [2])
        var card = Card(front: "缓存问题", back: "缓存答案")
        card.noteType = template.name
        card.fields = ["问题", "答案", "旧出处"]
        let preset = try CardEntryPreset.capture(name: "多字段预设", card: card, tags: [], templates: [template.name: template])
        let blank = try preset.blankCard(templates: [template.name: template])
        XCTAssertEqual(blank.noteType, template.name)
        XCTAssertEqual(blank.fields, ["", "", ""])
        XCTAssertThrowsError(try preset.blankCard(templates: [:])) { XCTAssertEqual($0 as? CardEntryPresetError, .missingNoteType(template.name)) }
        var changed = template
        changed.fieldNames.append("补充")
        XCTAssertThrowsError(try preset.blankCard(templates: [template.name: changed])) { XCTAssertEqual($0 as? CardEntryPresetError, .changedFields(template.name)) }
        changed.fieldNames = ["解释", "题目", "出处"]
        XCTAssertThrowsError(try preset.blankCard(templates: [template.name: changed]))
        card.fields.append("不能丢失的字段")
        XCTAssertThrowsError(try CardEntryPreset.capture(name: "不匹配", card: card, tags: [], templates: [template.name: template]))
    }

    @MainActor func testApplyingPresetRejectsEveryExistingInputAndExistingCard() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "释义", sections: [.init(name: "释义")])
        try db.saveCardEntryPreset(preset)
        let store = LibraryStore(db: db)
        let inputs = ["输入", "<img src='x.png'>", "[sound:x.mp3]", "<iframe src='about:blank'></iframe>", "<a href='https://example.com'></a>"]
        for input in inputs {
            store.cardEditor = CardDraft(card: Card(front: input))
            let old = try XCTUnwrap(store.cardEditor)
            XCTAssertFalse(store.applyCardEntryPreset(preset))
            XCTAssertEqual(store.cardEditor?.id, old.id)
            XCTAssertEqual(store.cardEditor?.card, old.card)
        }
        var other = Card(front: "")
        other.sections = [CardSection(name: "备注", text: "仍有输入")]
        store.cardEditor = CardDraft(card: other)
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        other.sections = nil; other.fields = ["字段中有输入"]
        store.cardEditor = CardDraft(card: other)
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        other.fields = []; other.back = "背面有输入"
        store.cardEditor = CardDraft(card: other)
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        store.cardEditor = CardDraft(card: Card(id: 10, front: ""))
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        XCTAssertEqual(store.cardEditor?.card.id, 10)
    }

    @MainActor func testApplyingBlankPresetReplacesEditorSessionAndUsesFreshStoredPreset() throws {
        let db = try AppDatabase(DatabaseQueue())
        var preset = CardEntryPreset(name: "释义", deck: "预设牌组", tags: ["预设标签"], sections: [.init(name: "释义")])
        try db.saveCardEntryPreset(preset)
        let stale = preset
        preset.sections.append(.init(name: "出处", folded: true))
        try db.saveCardEntryPreset(preset, expected: stale)
        let store = LibraryStore(db: db)
        store.cardEditor = CardDraft(card: Card(deck: "当前牌组", front: "<p><br></p>"))
        let id = store.cardEditor?.id
        XCTAssertTrue(store.applyCardEntryPreset(stale, keepCurrentDeck: true))
        XCTAssertNotEqual(store.cardEditor?.id, id)
        XCTAssertEqual(store.cardEditor?.card.deck, "当前牌组")
        XCTAssertEqual(store.cardEditor?.card.sections?.map(\.name), ["释义", "出处"])
        XCTAssertEqual(store.cardEditor?.tagsText, "预设标签")
        XCTAssertTrue(store.applyCardEntryPreset(preset))
        XCTAssertEqual(store.cardEditor?.card.deck, "预设牌组")
    }

    @MainActor func testDeckPresetUsesBoundDeckAndDoesNotChangeCurrentInput() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "名词解释", deck: "默认参考", tags: ["待整理"], sections: [.init(name: "释义")])
        try db.saveCardEntryPreset(preset)
        try db.setDeckEntryPreset(deck: "实际牌组", presetID: preset.id)
        let store = LibraryStore(db: db)
        store.cardEditor = CardDraft(card: Card(deck: "现有输入", front: "问题"))
        let before = store.cardEditor?.card
        let blank = try store.blankCardUsingDeckPreset(deck: "实际牌组")
        XCTAssertEqual(blank.deck, "实际牌组")
        XCTAssertEqual(blank.tags, ["待整理"])
        XCTAssertEqual(blank.sections?.map(\.name), ["释义"])
        XCTAssertEqual(store.cardEditor?.card, before)
        XCTAssertNil(try store.blankCardUsingDeckPreset(deck: "未配置").sections)
    }

    @MainActor func testApplyingAnotherPresetDoesNotAccumulateEmptyStructureDrafts() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = CardEntryPreset(name: "第一种", sections: [.init(name: "释义")])
        let second = CardEntryPreset(name: "第二种", sections: [.init(name: "出处")])
        try db.saveCardEntryPreset(first)
        try db.saveCardEntryPreset(second)
        let persistence = try EditorDraftPersistence(directory: directory())
        let store = LibraryStore(db: db, draftPersistence: persistence)
        store.cardEditor = CardDraft(card: Card(front: ""))
        XCTAssertTrue(store.applyCardEntryPreset(first))
        let firstID = store.cardEditor?.id
        XCTAssertTrue(persistence.cardDrafts.contains { $0.id == firstID })
        XCTAssertTrue(store.applyCardEntryPreset(second))
        XCTAssertFalse(persistence.cardDrafts.contains { $0.id == firstID })
        XCTAssertEqual(persistence.cardDrafts.count, 1)
        XCTAssertEqual(persistence.cardDrafts.first?.card.sections?.map(\.name), ["出处"])
    }

    func testDeletingPresetUnbindsAllDecksAndRejectsUnknownBinding() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "甲")
        try db.saveCardEntryPreset(preset)
        try db.setDeckEntryPreset(deck: "A", presetID: preset.id)
        try db.setDeckEntryPreset(deck: "B", presetID: preset.id)
        try db.deleteCardEntryPreset(id: preset.id)
        XCTAssertEqual(try db.cardEntryPresetLibrary(), CardEntryPresetLibrary())
        XCTAssertThrowsError(try db.setDeckEntryPreset(deck: "A", presetID: preset.id))
    }

    func testRenameMigratesDefaultDeckAndMergeKeepsDestinationBinding() throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = CardEntryPreset(name: "源", deck: "旧牌组")
        let target = CardEntryPreset(name: "目标", deck: "目标牌组")
        try db.saveCardEntryPreset(source)
        try db.saveCardEntryPreset(target)
        try db.setDeckEntryPreset(deck: "旧牌组", presetID: source.id)
        try db.writer.write { try AppDatabase.renameDeckEntryPresets($0, from: "旧牌组", to: "新牌组") }
        var library = try db.cardEntryPresetLibrary()
        XCTAssertNil(library.deckPresetIDs["旧牌组"])
        XCTAssertEqual(library.preset(for: "新牌组")?.id, source.id)
        XCTAssertEqual(library.presets.first(where: { $0.id == source.id })?.deck, "新牌组")
        try db.setDeckEntryPreset(deck: "目标牌组", presetID: target.id)
        try db.writer.write { try AppDatabase.renameDeckEntryPresets($0, from: "新牌组", to: "目标牌组") }
        library = try db.cardEntryPresetLibrary()
        XCTAssertNil(library.deckPresetIDs["新牌组"])
        XCTAssertEqual(library.preset(for: "目标牌组")?.id, target.id)
    }

    func testNamesAreUniqueAndStaleManagerEditCannotOverwriteChanges() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = CardEntryPreset(name: "History")
        try db.saveCardEntryPreset(original)
        XCTAssertThrowsError(try db.saveCardEntryPreset(CardEntryPreset(name: " history ")))
        var updated = original
        updated.tags = ["新标签"]
        try db.saveCardEntryPreset(updated, expected: original)
        var stale = original
        stale.name = "旧窗口改名"
        XCTAssertThrowsError(try db.saveCardEntryPreset(stale, expected: original)) { XCTAssertEqual($0 as? CardEntryPresetError, .changedPreset) }
        XCTAssertEqual(try db.cardEntryPresetLibrary().presets, [updated])
        try db.deleteCardEntryPreset(id: original.id)
        XCTAssertThrowsError(try db.saveCardEntryPreset(updated, expected: updated))
    }

    @MainActor func testStoreMutationsRespectFullBackupBusyAndSaveOnlyCurrentStructure() throws {
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db)
        store.cardEditor = CardDraft(card: Card(deck: "历史", front: "问题", back: "答案"), tagsText: "专题 #史料")
        store.cardEditor?.card.sections = [CardSection(name: "出处", text: "旧正文")]
        let preset = try store.saveCurrentCardEntryPreset(name: "当前结构")
        XCTAssertEqual(preset.tags, ["专题", "史料"])
        XCTAssertEqual(preset.sections.map(\.name), ["出处"])
        store.fullBackupBusy = true
        XCTAssertThrowsError(try store.saveCurrentCardEntryPreset(name: "禁止"))
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        XCTAssertEqual(try db.cardEntryPresetLibrary().presets.count, 1)
        XCTAssertEqual(store.cardEditor?.card.front, "问题")
    }

    func testFullBackupRoundTripIncludesPresetsAndDeckBindings() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "备份预设", deck: "历史", sections: [.init(name: "出处", folded: true)])
        try db.saveCardEntryPreset(preset)
        try db.setDeckEntryPreset(deck: "历史", presetID: preset.id)
        let suite = "KongReview.PresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = try directory().appendingPathComponent("presets.kongreviewbackup")
        try FullBackupService.create(db: db, draftURL: nil, defaults: defaults, destination: archive)
        let prepared = try FullBackupService.prepare(url: archive)
        defer { prepared.cleanup() }
        let target = try AppDatabase(DatabaseQueue())
        _ = try FullBackupService.restore(prepared, db: target, draftURL: nil, defaults: defaults, safetyDirectory: directory())
        XCTAssertEqual(try target.cardEntryPresetLibrary(), try db.cardEntryPresetLibrary())
    }
}
