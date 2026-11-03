import Foundation
import KongReviewCore

extension LibraryStore {
    /// Selecting a deck may fill an empty new form, never replace existing question/answer input.
    func selectDeckForCardEntry(_ value: String) {
        guard !fullBackupBusy,var draft = cardEditor else { return }
        let deck = value.trimmingCharacters(in:.whitespacesAndNewlines).nilIfBlank ?? "默认"
        draft.card.deck = deck
        cardEditor = draft
        guard draft.isNew,!(draft.entryGuidance?.hasInput(draft.card) ?? CardEntryPreset.hasInput(draft.card)),draft.card.highlightId == nil else { return }
        applyCurrentDeckEntryPreset()
    }

    func applyCurrentDeckEntryPreset() {
        guard let draft = cardEditor else { return }
        do {
            if let preset = try db.cardEntryPresetLibrary().preset(for:draft.card.deck) {
                _ = applyCardEntryPreset(preset,keepCurrentDeck:true)
            }
        } catch { cardEditor?.error = error.localizedDescription }
    }
}
