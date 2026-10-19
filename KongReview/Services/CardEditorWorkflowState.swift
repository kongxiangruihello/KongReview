import Foundation
import Observation

@MainActor @Observable final class CardEditorWorkflowState {
    var keepDeck = true
    var keepTags = true
    var keepStructure = true
    var addedCount = 0
    var batchID = UUID()
    var addedCardIDs: [Int64] = []
    var showsBatch = false
    var pendingBatchEdit: CardEntryBatchEditRequest?
    var actionBusy = false
    var generation = 0
    var duplicateReturn: CardDraftReturnContext?

    func startSession() {
        actionBusy = false
        addedCount = 0
        batchID = UUID()
        addedCardIDs = []
        showsBatch = false
        pendingBatchEdit = nil
        duplicateReturn = nil
    }

    func recordAddedCard(_ id: Int64?) {
        guard let id,!addedCardIDs.contains(id) else { return }
        addedCardIDs.append(id)
        addedCount = addedCardIDs.count
    }
}

struct CardDraftReturnContext {
    var incomingID: UUID
    var originalEditorID: UUID
    /// Only a successful explicit save authorizes returning after the original editor closes.
    var originalSaved = false
}
