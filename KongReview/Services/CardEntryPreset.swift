import Foundation
import KongReviewCore

/// Only empty input structure is retained. A preset never contains answers, media or card identity.
struct CardEntryPreset: Codable, Equatable, Identifiable, Sendable {
    struct Section: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var folded = false
        var rule: CardEntryInputRule?
    }

    var id = UUID()
    var name: String
    var deck = "默认"
    var tags: [String] = []
    var sections: [Section] = []
    var noteType: String?
    /// Requiring the same field names prevents silently assigning input to a changed type.
    var fieldNames: [String] = []
    var frontRule: CardEntryInputRule?
    var backRule: CardEntryInputRule?
    var fieldRules: [CardEntryInputRule]?

    static func capture(name: String, card: Card, tags: [String], templates: [String: NoteTemplate]) throws -> Self {
        var result = Self(name: name, deck: card.deck, tags: tags,
                          sections: (card.sections ?? []).map { Section(name: $0.name, folded: $0.folded) })
        if let type = card.noteType {
            guard let template = templates[type] else { throw CardEntryPresetError.missingNoteType(type) }
            guard card.fields.count == template.fieldNames.count else { throw CardEntryPresetError.changedFields(type) }
            result.noteType = type
            result.fieldNames = template.fieldNames
        } else if !card.fields.isEmpty {
            throw CardEntryPresetError.unassignedFields
        }
        try result.validate(templates: templates)
        return result.cleaned
    }

    var cleaned: Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.deck = deck.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "默认"
        value.tags = TagParser.parse(TagParser.format(tags))
        value.sections = sections.map { section in
            var section = section
            section.name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return section
        }
        return value
    }

    func validate(templates: [String: NoteTemplate]) throws {
        let value = cleaned
        guard !value.name.isEmpty else { throw CardEntryPresetError.emptyName }
        guard value.sections.allSatisfy({ !$0.name.isEmpty }) else { throw CardEntryPresetError.emptySection }
        guard Set(value.sections.map(\.id)).count == value.sections.count else { throw CardEntryPresetError.changedPreset }
        if let type = noteType {
            guard let template = templates[type] else { throw CardEntryPresetError.missingNoteType(type) }
            guard !fieldNames.isEmpty, fieldNames == template.fieldNames else { throw CardEntryPresetError.changedFields(type) }
            guard sections.isEmpty else { throw CardEntryPresetError.typedSections }
            guard fieldRules == nil || fieldRules?.count == fieldNames.count else { throw CardEntryPresetError.changedFields(type) }
        } else if !fieldNames.isEmpty || !(fieldRules ?? []).isEmpty {
            throw CardEntryPresetError.unassignedFields
        }
    }

    func blankCard(templates: [String: NoteTemplate], deckOverride: String? = nil) throws -> Card {
        try validate(templates: templates)
        let value = cleaned
        var card = Card(deck: deckOverride ?? value.deck, front: "", tags: value.tags)
        card.noteType = noteType
        card.fields = fieldNames.map { _ in "" }
        card.sections = value.sections.isEmpty ? nil : value.sections.map { CardSection(name: $0.name, folded: $0.folded) }
        return card
    }

    /// Carry editor instructions only when capturing the exact current structure.
    func retainingGuidance(_ guidance: CardEntryGuidance?, from card: Card) -> Self {
        guard let guidance, guidance.noteType == noteType, guidance.fieldNames == fieldNames else { return self }
        var value = self
        value.frontRule = guidance.front
        value.backRule = guidance.back
        value.fieldRules = guidance.fields
        for index in value.sections.indices {
            guard let original = card.sections, original.indices.contains(index) else { continue }
            value.sections[index].rule = guidance.sections.first { $0.cardSectionID == original[index].id }?.rule
        }
        return value
    }

    func guidance(for card: Card) -> CardEntryGuidance {
        CardEntryGuidance(presetName: name, noteType: noteType, fieldNames: fieldNames,
                          front: frontRule, back: backRule, fields: fieldRules,
                          sections: zip(sections, card.sections ?? []).compactMap { source, target in
                              source.rule.map { .init(cardSectionID: target.id, name: target.name, rule: $0) }
                          })
    }

    func blankDraft(templates: [String: NoteTemplate], deckOverride: String? = nil) throws -> CardDraft {
        let card = try blankCard(templates: templates, deckOverride: deckOverride)
        return CardDraft(card: card, tagsText: TagParser.format(card.tags), entryGuidance: guidance(for: card))
    }

    /// Only the editor's truly empty placeholder HTML counts as empty; hidden media is input too.
    static func hasInput(_ card: Card) -> Bool {
        ([card.front, card.back] + card.fields + (card.sections ?? []).map(\.text)).contains { text in
            let emptyMarkup = #"</?(?:p|div|span)\s*>|<br\s*/?>|&nbsp;|&#160;"#
            let remaining = text.replacingOccurrences(of: emptyMarkup, with: "", options: [.regularExpression, .caseInsensitive])
            return !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct CardEntryPresetLibrary: Codable, Equatable, Sendable {
    var presets: [CardEntryPreset] = []
    var deckPresetIDs: [String: UUID] = [:]

    func preset(for deck: String) -> CardEntryPreset? {
        guard let id = deckPresetIDs[deck] else { return nil }
        return presets.first { $0.id == id }
    }
}

enum CardEntryPresetError: LocalizedError, Equatable {
    case emptyName, duplicateName, emptySection, missingPreset, changedPreset, inputExists, existingCard, backupBusy
    case missingNoteType(String), changedFields(String), unassignedFields, typedSections

    var errorDescription: String? {
        switch self {
        case .emptyName: return "请填写预设名称。"
        case .duplicateName: return "已有同名录入预设，请换一个名称。"
        case .emptySection: return "请填写每个栏目的名称，或删除空栏目。"
        case .missingPreset: return "这个录入预设已删除，请重新选择。"
        case .changedPreset: return "这个录入预设刚被修改，请重新打开后再保存。"
        case .inputExists: return "当前卡片已有输入，无法套用预设；请先保存或保留草稿，再新建卡片。"
        case .existingCard: return "录入预设只用于新建卡片；已有卡片的内容和结构保持原样。"
        case .backupBusy: return "完整备份正在处理，请完成后再修改录入预设。"
        case .missingNoteType(let name): return "笔记类型「\(name)」已不存在，请在预设管理中重新选择。"
        case .changedFields(let name): return "笔记类型「\(name)」的字段已变化，请在预设管理中重新确认笔记类型后保存。"
        case .unassignedFields: return "这些字段没有可用的笔记类型，无法保存为录入预设。"
        case .typedSections: return "多字段笔记类型使用自身字段，请先移除额外栏目。"
        }
    }
}

extension LibraryStore {
    func blankCardDraftUsingDeckPreset(deck: String) throws -> CardDraft {
        let library = try db.cardEntryPresetLibrary()
        guard let preset = library.preset(for: deck) else { return CardDraft(card: Card(deck: deck, front: "")) }
        return try preset.blankDraft(templates: db.noteTemplates(), deckOverride: deck)
    }

    func blankCardUsingDeckPreset(deck: String) throws -> Card {
        let library = try db.cardEntryPresetLibrary()
        guard let preset = library.preset(for: deck) else { return Card(deck: deck, front: "") }
        return try preset.blankCard(templates: db.noteTemplates(), deckOverride: deck)
    }

    /// Call only after flushing the web editor. UUID replacement rejects late callbacks from old fields.
    @discardableResult
    func applyCardEntryPreset(_ preset: CardEntryPreset, keepCurrentDeck: Bool = false) -> Bool {
        do {
            guard !fullBackupBusy else { throw CardEntryPresetError.backupBusy }
            guard let current = cardEditor else { return false }
            guard current.isNew else { throw CardEntryPresetError.existingCard }
            guard !CardEntryPreset.hasInput(current.card), current.card.highlightId == nil else { throw CardEntryPresetError.inputExists }
            let library = try db.cardEntryPresetLibrary()
            guard let latest = library.presets.first(where: { $0.id == preset.id }) else { throw CardEntryPresetError.missingPreset }
            let next = try latest.blankDraft(templates: db.noteTemplates(), deckOverride: keepCurrentDeck ? current.card.deck : nil)
            // Empty named sections/tags can already have a persisted draft. Replacing structure
            // should not leave another recoverable copy every time a different preset is chosen.
            try draftPersistence?.removeCard(id: current.id)
            draftRevision += 1
            cardEditor = next
            return true
        } catch {
            cardEditor?.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveCurrentCardEntryPreset(name: String) throws -> CardEntryPreset {
        guard !fullBackupBusy else { throw CardEntryPresetError.backupBusy }
        guard let draft = cardEditor else { throw CardEntryPresetError.inputExists }
        let preset = try CardEntryPreset.capture(name: name, card: draft.card, tags: TagParser.parse(draft.tagsText), templates: db.noteTemplates())
            .retainingGuidance(draft.entryGuidance, from: draft.card)
        try db.saveCardEntryPreset(preset)
        return preset
    }
}
