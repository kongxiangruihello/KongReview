import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V39ContinuousEntryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KongReview-continuous-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor func testSaveAndContinueCreatesEmptyCardWithSelectedMetadataAndCountsOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase(DatabaseQueue())
        let highlight = try db.save(Highlight(text: "原摘录"))
        let store = LibraryStore(db: db, draftPersistence: try EditorDraftPersistence(directory: directory))
        store.newCard(deck: "历史")
        store.cardEditor?.card.front = "第一题"
        store.cardEditor?.card.back = "<img src=\"old.png\">旧答案 [sound:old.mp3]"
        store.cardEditor?.card.highlightId = highlight.id
        store.cardEditor?.card.ankiGuid = "old-guid"
        store.cardEditor?.card.state = .review
        store.cardEditor?.card.reps = 7
        store.cardEditor?.card.interval = 12
        store.cardEditor?.card.stability = 9
        store.cardEditor?.card.difficulty = 4
        store.cardEditor?.card.lastReview = Date(timeIntervalSince1970: 1)
        store.cardEditor?.card.isSuspended = true
        store.cardEditor?.tagsText = "专题 #待复习"
        let section = CardSection(name: "释义", text: "旧栏目正文", folded: true)
        store.cardEditor?.card.sections = [section]
        let previousID = try XCTUnwrap(store.cardEditor?.id)

        XCTAssertTrue(store.commitCardAndContinue())
        let next = try XCTUnwrap(store.cardEditor)
        XCTAssertNotEqual(next.id, previousID)
        XCTAssertTrue(next.isNew)
        XCTAssertEqual(next.card.deck, "历史")
        XCTAssertEqual(next.card.tags, ["专题", "待复习"])
        XCTAssertEqual(next.tagsText, TagParser.format(next.card.tags))
        XCTAssertEqual(next.card.front, "")
        XCTAssertEqual(next.card.back, "")
        XCTAssertEqual(next.card.sections?.first?.name, "释义")
        XCTAssertEqual(next.card.sections?.first?.text, "")
        XCTAssertEqual(next.card.sections?.first?.folded, true)
        XCTAssertNotEqual(next.card.sections?.first?.id, section.id)
        XCTAssertNil(next.card.highlightId)
        XCTAssertNil(next.card.ankiGuid)
        XCTAssertNil(next.card.deletedAt)
        XCTAssertEqual(next.card.state, .new)
        XCTAssertEqual(next.card.reps, 0)
        XCTAssertEqual(next.card.interval, 0)
        XCTAssertEqual(next.card.step, 0)
        XCTAssertEqual(next.card.lapses, 0)
        XCTAssertEqual(next.card.ease, 2.5)
        XCTAssertFalse(next.card.isSuspended)
        XCTAssertNil(next.card.stability)
        XCTAssertNil(next.card.difficulty)
        XCTAssertNil(next.card.lastReview)
        XCTAssertEqual(store.cardWorkflow.addedCount, 1)
        XCTAssertEqual(try db.cardCount(), 1)
        XCTAssertFalse(try EditorDraftPersistence(directory: directory).cardDrafts.contains { $0.id == previousID })

        store.cardEditor?.card.front = "第二题"
        XCTAssertTrue(store.commitCardAndContinue())
        XCTAssertEqual(store.cardWorkflow.addedCount, 2)
        XCTAssertEqual(try db.cardCount(), 2)
    }

    @MainActor func testDisabledCarryOptionsStartOrdinaryCardInDefaultDeck() throws {
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db)
        store.newCard(deck: "原牌组")
        store.cardWorkflow.keepDeck = false
        store.cardWorkflow.keepTags = false
        store.cardWorkflow.keepStructure = false
        store.cardEditor?.card.front = "问题"
        store.cardEditor?.tagsText = "原标签"
        store.cardEditor?.card.sections = [CardSection(name: "例句", text: "旧例句")]

        XCTAssertTrue(store.commitCardAndContinue())
        let card = try XCTUnwrap(store.cardEditor?.card)
        XCTAssertEqual(card.deck, "默认")
        XCTAssertTrue(card.tags.isEmpty)
        XCTAssertEqual(store.cardEditor?.tagsText, "")
        XCTAssertNil(card.sections)
        XCTAssertNil(card.noteType)
        XCTAssertTrue(card.fields.isEmpty)
    }

    @MainActor func testTemplateStructureRemainsEditableWithEmptyFields() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name: "问答模板", fieldNames: ["正面", "解释", "出处"], front: [0], back: [1, 2])
        try db.save(template)
        let store = LibraryStore(db: db)
        store.newCard(deck: "模板牌组")
        store.cardEditor?.card.noteType = template.name
        store.cardEditor?.card.fields = ["模板问题", "模板答案", "<img src=\"old.png\">"]
        store.cardEditor?.card.front = "模板问题"

        XCTAssertTrue(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.card.noteType, template.name)
        XCTAssertEqual(store.cardEditor?.card.fields, ["", "", ""])
        XCTAssertEqual(store.cardEditor?.card.front, "")
        XCTAssertEqual(store.cardEditor?.card.back, "")
        XCTAssertFalse(store.commitCardAndContinue(), "The empty fields must not create an empty second card")
        XCTAssertEqual(store.cardWorkflow.addedCount, 1)
        XCTAssertEqual(try db.cardCount(), 1)
    }

    @MainActor func testDuplicateFailureRetainsInputAndDoesNotAdvanceOrCount() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try db.save(Card(front: "Question", back: "原答案"))
        let store = LibraryStore(db: db)
        store.newCard(deck: "输入牌组")
        store.cardEditor?.card.front = " <p>QUESTION</p> "
        store.cardEditor?.card.back = "尚未保存的输入"
        store.cardEditor?.tagsText = "标签"
        let incoming = try XCTUnwrap(store.cardEditor)

        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertEqual(store.cardEditor?.tagsText, incoming.tagsText)
        XCTAssertEqual(store.cardEditor?.duplicate?.id, original.id)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        XCTAssertEqual(try db.cardCount(), 1)
    }

    @MainActor func testEmptyHTMLAndDatabaseFailureRetainCurrentDraft() throws {
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db)
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "<p><br></p>"
        let emptyID = store.cardEditor?.id
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.id, emptyID)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        XCTAssertEqual(try db.cardCount(), 0)
        store.cardEditor?.card.front = "写入失败仍保留的问题"
        try db.writer.write { database in
            try database.execute(sql: "CREATE TRIGGER reject_card BEFORE INSERT ON card BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let incoming = try XCTUnwrap(store.cardEditor)
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.id, incoming.id)
        XCTAssertEqual(store.cardEditor?.card, incoming.card)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        XCTAssertEqual(try db.cardCount(), 0)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testExistingCardsAndBusyBackupCannotAdvance() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(front: "已有问题", back: "原答案", state: .review, interval: 30, reps: 12))
        let original = try XCTUnwrap(db.card(id: inserted.id!))
        let store = LibraryStore(db: db)
        store.editCard(original)
        store.cardEditor?.card.back = "未保存的修改"
        let existing = try XCTUnwrap(store.cardEditor)
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.id, existing.id)
        XCTAssertEqual(store.cardEditor?.card, existing.card)
        XCTAssertEqual(try db.card(id: original.id!), original)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "完整备份中"
        let newID = store.cardEditor?.id
        store.fullBackupBusy = true
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(store.cardEditor?.id, newID)
        XCTAssertEqual(try db.cardCount(), 1)
    }

    @MainActor func testDraftCleanupFailureKeepsSavedContentAndCannotInsertTwice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try EditorDraftPersistence(directory: directory)
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db, draftPersistence: persistence)
        store.newCard(deck: "历史")
        store.cardEditor?.card.front = "保存成功但草稿清理失败"
        store.cardEditor?.card.back = "必须保留此内容"
        let draftID = try XCTUnwrap(store.cardEditor?.id)
        let backupURL = directory.appendingPathComponent("draft-backup.json")
        try FileManager.default.moveItem(at: persistence.fileURL, to: backupURL)
        try FileManager.default.createDirectory(at: persistence.fileURL, withIntermediateDirectories: false)

        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(try db.cardCount(), 1)
        XCTAssertEqual(store.cardWorkflow.addedCount, 1)
        XCTAssertEqual(store.cardEditor?.id, draftID)
        XCTAssertNotNil(store.cardEditor?.card.id, "A retry must treat the saved content as an existing card")
        XCTAssertEqual(store.cardEditor?.card.back, "必须保留此内容")
        XCTAssertNotNil(store.draftSaveError)
        XCTAssertNotNil(store.cardEditor?.error)

        try FileManager.default.removeItem(at: persistence.fileURL)
        try FileManager.default.moveItem(at: backupURL, to: persistence.fileURL)
        XCTAssertFalse(store.commitCardAndContinue(), "It has already been saved, so the new-card action cannot save it again")
        XCTAssertNotNil(store.commitCardEditor())
        XCTAssertNil(store.cardEditor)
        XCTAssertEqual(try db.cardCount(), 1)
        XCTAssertEqual(store.cardWorkflow.addedCount, 1)
        XCTAssertTrue(try EditorDraftPersistence(directory: directory).cardDrafts.isEmpty)
    }

    @MainActor func testNewAndEditSessionsResetCountOnlyWhenAnEditorOpens() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try db.save(Card(front: "已存问题"))
        let store = LibraryStore(db: db)
        store.newCard(deck: nil)
        store.cardEditor?.card.front = "连续录入问题"
        XCTAssertTrue(store.commitCardAndContinue())
        XCTAssertEqual(store.cardWorkflow.addedCount, 1)
        let generation = store.cardWorkflow.generation
        store.newCard(deck: nil)
        XCTAssertGreaterThan(store.cardWorkflow.generation, generation)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        store.cardWorkflow.addedCount = 3
        var missing = original; missing.id = 999_999
        store.editCard(missing)
        XCTAssertEqual(store.cardWorkflow.addedCount, 3)
        store.editCard(original)
        XCTAssertEqual(store.cardWorkflow.addedCount, 0)
        XCTAssertEqual(store.cardEditor?.card.id, original.id)
    }

    @MainActor func testActualTemplateFrontAllowsEmptyCacheButRejectsEmptyRenderedQuestion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name: "第二字段为题", fieldNames: ["缓存", "问题", "答案"], front: [1], back: [2])
        try db.save(template)
        let store = LibraryStore(db: db)
        store.newCard(deck: nil)
        store.cardEditor?.card.noteType = template.name
        store.cardEditor?.card.fields = ["", "实际问题", "答案"]
        XCTAssertTrue(store.commitCardAndContinue())
        XCTAssertEqual(try db.cardCount(), 1)
        store.cardEditor?.card.fields = ["缓存非空", "<p><br></p>", "答案"]
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(try db.cardCount(), 1)
        store.cardEditor?.card.fields = ["", "[sound:question.mp3]", "答案"]
        XCTAssertTrue(store.commitCardAndContinue(), "Sound questions remain valid even when template rendering strips sound markers")
        XCTAssertEqual(try db.cardCount(), 2)
    }
}
