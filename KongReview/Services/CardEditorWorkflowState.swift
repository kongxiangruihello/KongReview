import Foundation
import Observation

@MainActor @Observable final class CardEditorWorkflowState {
    var keepDeck = true
    var keepTags = true
    var keepStructure = true
    var addedCount = 0
    var actionBusy = false
    var generation = 0
    var duplicateReturn: CardDraftReturnContext?

    func startSession() {
        actionBusy = false
        addedCount = 0
        duplicateReturn = nil
    }
}

struct CardDraftReturnContext {
    var incomingID: UUID
    var originalEditorID: UUID
    /// Only a successful explicit save authorizes returning after the original editor closes.
    var originalSaved = false
}
