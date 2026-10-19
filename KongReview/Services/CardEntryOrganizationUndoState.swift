import Foundation
import Observation
import KongReviewCore

@MainActor @Observable final class CardEntryOrganizationUndoState {
    var token: CardEntryOrganizationUndoToken?
    var isBusy = false
    var message: String?
    func clear() { token = nil;message = nil;isBusy = false }
}

extension LibraryStore {
    /// Shared by the current-session and persistent-entry-history lists. Callers
    /// determine allowedIDs from the list's current session/date scope.
    func changeCardEntryOrganization(ids: [Int64], allowedIDs: [Int64], change: CardEntryBatchChange,
                                     historyQuery: CardEntryHistoryQuery? = nil) throws {
        guard !fullBackupBusy else { throw CardEntryOrganizationUndoError.backupBusy }
        let token = try db.changeCardEntryOrganizationRecordingUndo(ids:ids,allowedIDs:allowedIDs,change:change,historyQuery:historyQuery)
        cardEntryOrganizationUndo.token = token
        cardEntryOrganizationUndo.message = token == nil ? "所选卡片无需更改。" : nil
        if var draft = cardEditor,let id = draft.card.id,ids.contains(id) {
            switch change {
            case .move(let deck): draft.card.deck = deck.trimmingCharacters(in:.whitespacesAndNewlines)
            case .tags(let values,let mode):
                let values = TagParser.parse(values.joined(separator:" "))
                var tags = TagParser.parse(draft.tagsText)
                switch mode {
                case .add:
                    var seen = Set(tags);tags += values.filter { seen.insert($0).inserted }
                case .remove: tags.removeAll { values.contains($0) }
                }
                draft.tagsText = TagParser.format(tags);draft.card.tags = tags
            }
            cardEditor = draft
        }
        if let id = study.current?.id,ids.contains(id) { study.current = try db.card(id:id) }
        reload()
    }

    @discardableResult
    func undoLastCardEntryOrganization() -> Bool {
        let state = cardEntryOrganizationUndo
        guard !state.isBusy,let token = state.token else { return false }
        guard !fullBackupBusy else { state.message = CardEntryOrganizationUndoError.backupBusy.localizedDescription;return false }
        guard cardEditor?.card.id.map({ token.cardIDs.contains($0) }) != true else {
            state.message = CardEntryOrganizationUndoError.cardBeingEdited.localizedDescription;return false
        }
        state.isBusy = true
        defer { state.isBusy = false }
        do {
            let restored = try db.undoCardEntryOrganization(token)
            if let id = study.current?.id,let current = restored.first(where:{ $0.id == id }) { study.current = current }
            state.token = nil
            state.message = "已撤销本次整理，正文、学习进度和其他牌组或标签修改已保留。"
            reload()
            return true
        } catch {
            // A rejected attempt must not discard the receipt or any open input.
            state.message = error.localizedDescription
            return false
        }
    }
}
