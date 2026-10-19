import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V311TemplateTests: XCTestCase {
    func testFiveBuiltinsAreIndependentEmptyTemplatesWithSeparateExamples() throws {
        XCTAssertEqual(CardEntryBuiltins.all.map(\.preset.name), ["名词解释", "历史事件", "人物", "史料分析", "论述题"])
        for builtin in CardEntryBuiltins.all {
            let first = builtin.editableCopy(), second = builtin.editableCopy()
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertNotEqual(first.sections.first?.id, second.sections.first?.id)
            let draft = try first.blankDraft(templates: [:])
            XCTAssertFalse(CardEntryPreset.hasInput(draft.card))
            XCTAssertFalse(builtin.examples.isEmpty)
            XCTAssertNotNil(draft.entryGuidance)
            let body = draft.card.front + draft.card.back + (draft.card.sections ?? []).map(\.text).joined()
            for example in builtin.examples { XCTAssertFalse(body.contains(example.text)) }
        }
    }

    func testOld310PresetAndSavedDraftDecodeWithoutRules() throws {
        let preset = CardEntryPreset(name: "旧预设", sections: [.init(name: "旧栏目")])
        let old = try JSONDecoder().decode(CardEntryPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertNil(old.frontRule)
        XCTAssertNil(old.sections.first?.rule)
        let saved = SavedCardDraft(draft: CardDraft(card: Card(front: "旧草稿")), original: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        XCTAssertNil(json["entryGuidance"])
        let recovered = try JSONDecoder().decode(SavedCardDraft.self, from: JSONSerialization.data(withJSONObject: json)).restored(current: nil).draft
        XCTAssertEqual(recovered.card.front, "旧草稿")
        XCTAssertNil(recovered.entryGuidance)
    }

    func testHintsNeverEnterCardBodyAndRequiredChecksIgnorePlaceholderMarkup() throws {
        let preset = CardEntryPreset(name: "必填", frontRule: .init(hint: "写概念", required: true), backRule: .init(hint: "写释义", required: true))
        var draft = try preset.blankDraft(templates: [:])
        XCTAssertEqual(draft.entryValidationIssues(templates: [:]).map(\.key), ["front", "back"])
        draft.card.front = "<p><br></p>"
        draft.card.back = "<div>&nbsp;</div>"
        XCTAssertEqual(draft.entryValidationIssues(templates: [:]).count, 2)
        draft.card.front = "<img src='question.png'>"
        draft.card.back = "[sound:answer.mp3]"
        XCTAssertTrue(draft.entryValidationIssues(templates: [:]).isEmpty)
        XCTAssertFalse(draft.card.front.contains("写概念"))
        XCTAssertFalse(draft.card.back.contains("写释义"))
    }

    func testSectionRulesFollowIDsAfterReorderingAndMissingRequiredSectionFails() throws {
        let preset = CardEntryPreset(name: "有栏目", sections: [
            .init(name: "甲", rule: .init(hint: "甲提示", required: true)),
            .init(name: "乙", rule: .init(hint: "乙提示"))
        ])
        var draft = try preset.blankDraft(templates: [:])
        let firstID = try XCTUnwrap(draft.card.sections?.first?.id)
        draft.card.sections?.reverse()
        XCTAssertEqual(draft.entryGuidance?.rule(for: "section:" + firstID)?.hint, "甲提示")
        XCTAssertEqual(draft.entryValidationIssues(templates: [:]).map(\.key), ["section:" + firstID])
        draft.card.sections?.removeAll { $0.id == firstID }
        XCTAssertEqual(draft.entryValidationIssues(templates: [:]).first?.title, "甲")
    }

    func testFieldSnapshotRefusesChangedNameOrderAndDifferentNoteType() throws {
        let template = NoteTemplate(name: "多字段", fieldNames: ["题目", "答案"], front: [0], back: [1])
        let preset = CardEntryPreset(name: "字段规则", noteType: template.name, fieldNames: template.fieldNames,
                                    fieldRules: [.init(hint: "问什么", required: true), .init(hint: "如何答", required: true)])
        var draft = try preset.blankDraft(templates: [template.name: template])
        draft.card.fields = ["问题", "答案"]
        XCTAssertTrue(draft.entryValidationIssues(templates: [template.name: template]).isEmpty)
        var changed = template; changed.fieldNames.reverse()
        XCTAssertEqual(draft.entryValidationIssues(templates: [template.name: changed]).first?.key, "structure")
        draft.card.noteType = nil
        XCTAssertEqual(draft.entryValidationIssues(templates: [template.name: template]).first?.key, "structure")
    }

    func testMismatchedFieldRuleCountCannotBeAppliedOrPersisted() throws {
        let template = NoteTemplate(name: "二字段", fieldNames: ["甲", "乙"], front: [0], back: [1])
        let preset = CardEntryPreset(name: "错误规则", noteType: template.name, fieldNames: template.fieldNames, fieldRules: [.init(required: true)])
        XCTAssertThrowsError(try preset.blankDraft(templates: [template.name: template]))
    }

    func testSavedDraftRestoresGuidanceSnapshotIncludingStableSectionIDs() throws {
        let preset = CardEntryPreset(name: "旧规则", sections: [.init(name: "解释", rule: .init(hint: "先定义", required: true))])
        var draft = try preset.blankDraft(templates: [:]); draft.card.front = "问题"
        let saved = SavedCardDraft(draft: draft, original: nil)
        let decoded = try JSONDecoder().decode(SavedCardDraft.self, from: JSONEncoder().encode(saved))
        let restored = decoded.restored(current: nil).draft
        XCTAssertEqual(restored.entryGuidance, draft.entryGuidance)
        XCTAssertEqual(restored.entryValidationIssues(templates: [:]).first?.key, "section:" + draft.card.sections![0].id)
        var changed = preset; changed.sections[0].rule = .init(hint: "新的说明", required: false)
        XCTAssertEqual(restored.entryGuidance?.rule(for: "section:" + draft.card.sections![0].id)?.hint, "先定义")
    }

    func testContinuousEntryRebasesIDsAndRejectsDifferentStructure() throws {
        let preset = CardEntryPreset(name: "沿用", sections: [.init(name: "解释", rule: .init(required: true))])
        var draft = try preset.blankDraft(templates: [:]); draft.card.front = "问题"; draft.card.sections?[0].text = "回答"
        let next = CardContinuousEntry.blankCard(after: draft.card, keepDeck: true, keepTags: true, keepStructure: true)
        let guidance = try XCTUnwrap(draft.entryGuidance?.rebased(from: draft.card, to: next))
        XCTAssertNotEqual(draft.card.sections?[0].id, next.sections?[0].id)
        XCTAssertEqual(guidance.validationIssues(card: next, templates: [:]).first?.key, "section:" + next.sections![0].id)
        var different = next; different.sections?[0].name = "别的栏目"
        XCTAssertNil(draft.entryGuidance?.rebased(from: draft.card, to: different))
        different = next; different.front = "已有输入"
        XCTAssertNil(draft.entryGuidance?.rebased(from: draft.card, to: different))
    }

    @MainActor func testApplyingAndCapturingTemplatePreservesRulesWithoutChangingExistingCards() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "模板", deck: "历史", sections: [.init(name: "背景", rule: .init(hint: "背景提示", required: true))], frontRule: .init(required: true))
        try db.saveCardEntryPreset(preset); try db.setDeckEntryPreset(deck: "历史", presetID: preset.id)
        let store = LibraryStore(db: db)
        let draft = try store.blankCardDraftUsingDeckPreset(deck: "历史")
        XCTAssertEqual(draft.entryGuidance?.front?.required, true)
        store.cardEditor = draft
        let captured = try store.saveCurrentCardEntryPreset(name: "结构与规则")
        XCTAssertEqual(captured.sections[0].rule?.hint, "背景提示")
        store.cardEditor = CardDraft(card: Card(id: 123, deck: "历史", front: "已有问题"))
        XCTAssertFalse(store.applyCardEntryPreset(preset))
        XCTAssertNil(store.cardEditor?.entryGuidance)
    }
    @MainActor func testCommitBlocksMissingFieldsAndContinuousEntryRetainsRequiredRules() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "完整必填", sections: [.init(name: "依据", rule: .init(required: true))],
                                    frontRule: .init(required: true), backRule: .init(hint: "解释清楚", required: true))
        try db.saveCardEntryPreset(preset); try db.setDeckEntryPreset(deck: "历史", presetID: preset.id)
        let store = LibraryStore(db: db, positionDefaults: nil)
        store.newCard(deck: "历史")
        let originalID = store.cardEditor?.id
        store.cardEditor?.card.front = "第一题"
        XCTAssertNil(store.commitCardEditor())
        XCTAssertEqual(store.cardEditor?.id, originalID)
        XCTAssertEqual(store.cardEditor?.entryValidationAttempted, true)
        XCTAssertTrue(store.cardEditor?.error?.contains("背面") == true)
        XCTAssertEqual(try db.cardCount(), 0)
        store.cardEditor?.card.back = "答案"
        XCTAssertNil(store.commitCardEditor())
        XCTAssertTrue(store.cardEditor?.error?.contains("依据") == true)
        store.cardEditor?.card.sections?[0].text = "论据"
        let oldSectionID = store.cardEditor?.card.sections?[0].id
        store.cardWorkflow.keepStructure = true
        XCTAssertTrue(store.commitCardAndContinue())
        let next = try XCTUnwrap(store.cardEditor)
        XCTAssertNotEqual(next.id, originalID)
        XCTAssertNotEqual(next.card.sections?[0].id, oldSectionID)
        XCTAssertEqual(next.entryGuidance?.back?.hint, "解释清楚")
        XCTAssertFalse(next.entryValidationAttempted)
        XCTAssertEqual(next.entryValidationIssues(templates: [:]).count, 3)
        XCTAssertEqual(try db.cardCount(), 1)
        store.cardEditor?.card.front = "第二题"
        XCTAssertFalse(store.commitCardAndContinue())
        XCTAssertEqual(try db.cardCount(), 1)
    }

    @MainActor func testContinuousEntryDropsRulesWhenStructureCarryIsDisabled() throws {
        let db = try AppDatabase(DatabaseQueue())
        let preset = CardEntryPreset(name: "有提示", frontRule: .init(hint: "问题", required: true), backRule: .init(required: true))
        let store = LibraryStore(db: db, positionDefaults: nil)
        store.cardEditor = try preset.blankDraft(templates: [:])
        store.cardEditor?.card.front = "首题"; store.cardEditor?.card.back = "首答"
        store.cardWorkflow.keepStructure = false
        XCTAssertTrue(store.commitCardAndContinue())
        XCTAssertNil(store.cardEditor?.entryGuidance)
        XCTAssertEqual(try db.cardCount(), 1)
    }

}
