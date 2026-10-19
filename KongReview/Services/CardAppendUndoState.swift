import Foundation
import Observation
import KongReviewCore

@MainActor @Observable final class CardAppendUndoState {
    var token: CardAppendUndoToken?
    var isBusy = false
    var message: String?

    func clear() { token = nil; message = nil; isBusy = false }
}

extension LibraryStore {
    /// The editor owns draft completion; this service never closes or replaces an input draft.
    func appendCardAnswerWithUndo(_ preview: CardAnswerAppendPreview) throws -> Card {
        guard !fullBackupBusy else { throw CardAppendUndoError.backupBusy }
        let token = try db.appendCardAnswerRecordingUndo(preview)
        cardAppendUndo.token = token
        cardAppendUndo.message = nil
        if study.current?.id == token.after.id { study.current = token.after }
        return token.after
    }

    @discardableResult
    func undoLastCardAppend() -> Bool {
        guard !cardAppendUndo.isBusy, let token = cardAppendUndo.token else { return false }
        guard !fullBackupBusy else {
            cardAppendUndo.message = CardAppendUndoError.backupBusy.localizedDescription
            return false
        }
        guard cardEditor?.card.id != token.after.id else {
            cardAppendUndo.message = CardAppendUndoError.cardBeingEdited.localizedDescription
            return false
        }
        cardAppendUndo.isBusy = true
        defer { cardAppendUndo.isBusy = false }
        do {
            let restored = try db.undoCardAppend(token)
            if study.current?.id == restored.id { study.current = restored }
            cardAppendUndo.token = nil
            cardAppendUndo.message = "已撤销本次追加，学习进度、牌组和标签已保留。"
            reload()
            return true
        } catch {
            cardAppendUndo.token = nil
            cardAppendUndo.message = error.localizedDescription
            return false
        }
    }
}
