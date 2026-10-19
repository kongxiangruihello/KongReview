import Foundation
import KongReviewCore

extension LibraryStore {
    /// Save the current new card before replacing its editor with an empty card.
    /// Failure keeps the current draft, including a successful save whose old draft could not be cleared.
    @discardableResult
    func commitCardAndContinue(allowDeleted: Bool = false) -> Bool {
        guard !fullBackupBusy, let draft = cardEditor else { return false }
        guard draft.isNew else {
            cardEditor?.error = "“保存并新增”仅用于新建卡片；请先保存这张已有卡片。"
            return false
        }
        guard let saved = commitCardEditor(allowDeleted: allowDeleted), cardEditor == nil else { return false }
        let next = CardContinuousEntry.blankCard(after: saved,
                                                keepDeck: cardWorkflow.keepDeck,
                                                keepTags: cardWorkflow.keepTags,
                                                keepStructure: cardWorkflow.keepStructure)
        cardWorkflow.duplicateReturn = nil
        cardEditor = CardDraft(card: next, tagsText: TagParser.format(next.tags))
        return true
    }
}

enum CardContinuousEntry {
    static func hasFrontContent(_ card: Card, template: NoteTemplate?) -> Bool {
        let front = card.faces(using: template).front
        if HTMLSourceCodec.hasContent(front) || front.contains("[sound:") { return true }
        // Template rendering strips playback markers, but an audio question is valid content.
        if let template, !card.fields.isEmpty {
            return template.front.contains { card.fields.indices.contains($0) && card.fields[$0].contains("[sound:") }
        }
        return false
    }

    /// Start from a fresh Card, copying only the metadata and empty structure explicitly selected.
    /// Original links, imported identity, media content, and learning history never carry forward.
    static func blankCard(after saved: Card, keepDeck: Bool, keepTags: Bool, keepStructure: Bool) -> Card {
        var next = Card(deck: keepDeck ? saved.deck : "默认", front: "", tags: keepTags ? saved.tags : [])
        if keepStructure {
            if let type = saved.noteType {
                next.noteType = type
                next.fields = saved.fields.map { _ in "" }
            }
            next.sections = saved.sections.map { sections in
                sections.map { CardSection(name: $0.name, text: "", folded: $0.folded) }
            }
        }
        return next
    }
}
