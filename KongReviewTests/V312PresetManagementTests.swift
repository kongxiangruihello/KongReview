import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V312PresetManagementTests: XCTestCase {
    private func sample(_ name: String = "史料模板") -> CardEntryPreset {
        CardEntryPreset(name: name, deck: "历史", tags: ["史料", "待练习"], sections: [
            .init(name: "出处", folded: true, rule: .init(hint: "作者与页码", required: true)),
            .init(name: "分析", rule: .init(hint: "论点与依据", required: false))
        ], frontRule: .init(hint: "写问题", required: true), backRule: .init(hint: "写回答"))
    }

    func testPersonalCopyCreatesIndependentIdentityAndPreservesGuidance() throws {
        let source = sample()
        var copy = source.copied(name: "我的副本")
        XCTAssertNotEqual(source.id, copy.id)
        XCTAssertEqual(copy.name, "我的副本")
        XCTAssertEqual(copy.sections.map(\.name), source.sections.map(\.name))
        XCTAssertTrue(Set(source.sections.map(\.id)).isDisjoint(with: Set(copy.sections.map(\.id))))
        XCTAssertEqual(copy.sections.map(\.rule), source.sections.map(\.rule))
        XCTAssertEqual(copy.frontRule, source.frontRule)
        copy.sections[0].rule?.hint = "副本提示"
        XCTAssertEqual(source.sections[0].rule?.hint, "作者与页码")
        XCTAssertFalse(CardEntryPreset.hasInput(try copy.blankCard(templates: [:])))
    }

    func testReorderingMovesRulesAndFoldWithSectionAndRejectsInvalidMoves() throws {
        var preset = sample()
        let first = preset.sections[0], second = preset.sections[1]
        XCTAssertFalse(preset.moveSection(id: first.id, offset: -1))
        XCTAssertFalse(preset.moveSection(id: first.id, offset: 2))
        XCTAssertFalse(preset.moveSection(id: UUID(), offset: 1))
        XCTAssertTrue(preset.moveSection(id: first.id, offset: 1))
        XCTAssertEqual(preset.sections, [second, first])
        let draft = try preset.blankDraft(templates: [:])
        let lastID = try XCTUnwrap(draft.card.sections?.last?.id)
        XCTAssertEqual(draft.entryGuidance?.rule(for: "section:" + lastID)?.hint, "作者与页码")
        XCTAssertTrue(draft.entryGuidance?.rule(for: "section:" + lastID)?.required == true)
        XCTAssertEqual(draft.card.sections?.last?.folded, true)
        XCTAssertTrue(preset.moveSection(id: first.id, offset: -1))
        XCTAssertEqual(preset.sections, [first, second])
    }

    func testTransferRoundTripKeepsOnlyPresetDataAndPlainTextInstructions() throws {
        let preset = sample()
        let data = try CardEntryPresetTransfer.encode([preset])
        XCTAssertEqual(try CardEntryPresetTransfer.decode(data), [preset])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "presets"])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["deckPresetIDs", "reps", "interval", "highlightId", "front\"", "back\""] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        var untrusted = preset
        untrusted.frontRule?.hint = "<script>window.external.removeAll()</script>"
        let decoded = try CardEntryPresetTransfer.decode(CardEntryPresetTransfer.encode([untrusted]))
        XCTAssertEqual(decoded[0].frontRule?.hint, untrusted.frontRule?.hint)
        XCTAssertEqual(try decoded[0].blankCard(templates: [:]).front, "")
    }

    func testCardOrBackupFieldsAndUnsupportedFormatAreRejected() throws {
        let data = try CardEntryPresetTransfer.encode([sample()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(object["presets"] as? [[String: Any]])
        rows[0]["front"] = "不得导入的卡片正文"
        object["presets"] = rows
        XCTAssertThrowsError(try CardEntryPresetTransfer.decode(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? CardEntryPresetTransferError, .invalidFile)
        }
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        XCTAssertThrowsError(try CardEntryPresetTransfer.decode(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? CardEntryPresetTransferError, .unsupportedVersion)
        }
        object["version"] = 1; object["format"] = "other"
        XCTAssertThrowsError(try CardEntryPresetTransfer.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try CardEntryPresetTransfer.decode(Data("{broken".utf8)))
    }

    func testLimitsRejectOversizedOrUnboundedFiles() throws {
        XCTAssertThrowsError(try CardEntryPresetTransfer.decode(Data(repeating: 0, count: CardEntryPresetTransfer.maximumBytes + 1))) {
            XCTAssertEqual($0 as? CardEntryPresetTransferError, .tooLarge)
        }
        XCTAssertThrowsError(try CardEntryPresetTransfer.encode([]))
        XCTAssertThrowsError(try CardEntryPresetTransfer.encode((0..<101).map { sample("模板\($0)") }))
        var preset = sample(); preset.sections = (0..<101).map { .init(name: "栏目\($0)") }
        XCTAssertThrowsError(try CardEntryPresetTransfer.encode([preset]))
        preset = sample(); preset.frontRule?.hint = String(repeating: "a", count: 16_385)
        XCTAssertThrowsError(try CardEntryPresetTransfer.encode([preset]))
    }

    func testTemporaryFileReadAndWriteDoesNotTouchDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-PresetTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("templates.json")
        try CardEntryPresetTransfer.encode([sample()]).write(to: url, options: .atomic)
        XCTAssertEqual(try CardEntryPresetTransfer.read(from: url), [try CardEntryPresetTransfer.decode(Data(contentsOf: url))[0]])
        XCTAssertThrowsError(try CardEntryPresetTransfer.read(from: directory))
    }

    func testImportAddsFreshCopiesAndPreservesExistingPresetsDeckBindingsAndCards() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = sample("原模板")
        try db.saveCardEntryPreset(original)
        try db.setDeckEntryPreset(deck: "历史", presetID: original.id)
        var learned = Card(front: "实际问题", back: "实际答案", tags: ["保留"], state: .review, interval: 9, reps: 12)
        learned.stability = 7
        let card = try db.save(learned)
        // Compare persisted before/after values, including every date and learning field.
        // GRDB's timestamp representation does not preserve a new Date's subsecond bits.
        let beforeImport = try XCTUnwrap(db.card(id: card.id!))
        let incoming = sample("导入模板")
        let imported = try db.importCardEntryPresets([incoming])
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotEqual(imported[0].id, incoming.id)
        XCTAssertTrue(Set(imported[0].sections.map(\.id)).isDisjoint(with: Set(incoming.sections.map(\.id))))
        let library = try db.cardEntryPresetLibrary()
        XCTAssertEqual(library.presets.first { $0.id == original.id }, original)
        XCTAssertEqual(library.preset(for: "历史"), original)
        XCTAssertEqual(try XCTUnwrap(db.card(id: card.id!)), beforeImport)
        XCTAssertEqual(imported[0].sections.map(\.rule), incoming.sections.map(\.rule))
    }

    func testExistingAndWithinFileNameConflictsRollBackEntireSelection() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.saveCardEntryPreset(sample("History"))
        let original = try db.cardEntryPresetLibrary()
        XCTAssertThrowsError(try db.importCardEntryPresets([sample("全新"), sample(" history ")])) {
            XCTAssertEqual($0 as? CardEntryPresetError, .duplicateName)
        }
        XCTAssertEqual(try db.cardEntryPresetLibrary(), original)
        XCTAssertThrowsError(try db.importCardEntryPresets([sample("文件同名"), sample("文件同名")]))
        XCTAssertEqual(try db.cardEntryPresetLibrary(), original)
        XCTAssertEqual(try db.importCardEntryPresets([sample("显式新名称")]).count, 1)
    }

    func testMissingAndChangedNoteTypeAreRejectedWithoutImportingOtherItems() throws {
        let db = try AppDatabase(DatabaseQueue())
        var template = NoteTemplate(name: "二字段", fieldNames: ["问题", "答案"], front: [0], back: [1])
        let incoming = CardEntryPreset(name: "多字段模板", noteType: template.name, fieldNames: template.fieldNames,
                                       fieldRules: [.init(hint: "问什么", required: true), .init(hint: "怎样答")])
        let decoded = try CardEntryPresetTransfer.decode(CardEntryPresetTransfer.encode([incoming]))
        XCTAssertThrowsError(try db.importCardEntryPresets([sample("普通项"), decoded[0]])) {
            XCTAssertEqual($0 as? CardEntryPresetError, .missingNoteType(template.name))
        }
        XCTAssertTrue(try db.cardEntryPresetLibrary().presets.isEmpty)
        try db.save(template)
        try incoming.validate(templates: db.noteTemplates()) // Simulates an accepted preview.
        template.fieldNames.reverse(); try db.save(template)
        XCTAssertThrowsError(try db.importCardEntryPresets([incoming])) {
            XCTAssertEqual($0 as? CardEntryPresetError, .changedFields(template.name))
        }
        XCTAssertTrue(try db.cardEntryPresetLibrary().presets.isEmpty)
        template.fieldNames.reverse(); try db.save(template)
        let imported = try XCTUnwrap(db.importCardEntryPresets([incoming]).first)
        XCTAssertEqual(imported.fieldRules, incoming.fieldRules)
        XCTAssertEqual(try imported.blankCard(templates: db.noteTemplates()).fields, ["", ""])
    }

    func testMalformedSectionAndRuleSnapshotsCannotBeMadeValidByCopying() throws {
        let db = try AppDatabase(DatabaseQueue())
        var preset = sample()
        preset.sections[1].id = preset.sections[0].id
        // Import must reject duplicate source section IDs before regenerating identities.
        XCTAssertThrowsError(try db.importCardEntryPresets([preset]))
        XCTAssertTrue(try db.cardEntryPresetLibrary().presets.isEmpty)
    }

    func testSuggestedNamesAvoidCaseInsensitiveCollisions() {
        XCTAssertEqual(CardEntryPresetTransfer.suggestedCopyName(" History ", existingNames: []), "History 副本")
        XCTAssertEqual(CardEntryPresetTransfer.suggestedCopyName("History", existingNames: ["history 副本", "History 副本 2"]), "History 副本 3")
    }
}
