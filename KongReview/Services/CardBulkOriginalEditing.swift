import Foundation
import Observation
import KongReviewCore

@MainActor @Observable final class CardBulkOriginalEditingState {
    struct Request {
        var candidateID: UUID
        var cardID: Int64
        var bulkDraftID: UUID?
        var parentEditorID: UUID?
        var generation: UUID
    }
    struct ReturnContext {
        var editorID: UUID
        var bulkDraftID: UUID
        var parent: CardDraft?
        var parentWasPersisted: Bool
        var parentReturn: CardDraftReturnContext?
    }
    var generation = UUID()
    var pending: Request?
    var returning: ReturnContext?
    func clear() { generation = UUID();pending = nil;returning = nil }
}

private enum CardBulkOriginalEditingError: LocalizedError {
    case changed, persistence, missingParent
    var errorDescription: String? {
        switch self {
        case .changed: "原卡、批量草稿或当前编辑会话已变化，请重新检查候选后再打开。输入仍保留。"
        case .persistence: "编辑草稿暂不能保存，尚未切换。请先保存或复制当前输入。"
        case .missingParent: "原来输入的草稿已变化，未替换当前编辑内容；可从草稿管理中找回原输入。"
        }
    }
}

extension LibraryStore {
    func requestBulkOriginalEdit(candidateID: UUID,cardID: Int64) {
        guard !fullBackupBusy else { return }
        let draftID = (try? db.cardBulkEntryDraft())?.id
        bulkOriginalEditing.pending = .init(candidateID:candidateID,cardID:cardID,bulkDraftID:draftID,
            parentEditorID:cardEditor?.id,generation:bulkOriginalEditing.generation)
        showsCardBulkEntry = false
    }

    /// Run only after the batch sheet has dismissed, so it cannot compete for the editor host.
    func performPendingBulkOriginalEdit() {
        guard let request = bulkOriginalEditing.pending else { return }
        bulkOriginalEditing.pending = nil
        guard !fullBackupBusy,request.generation == bulkOriginalEditing.generation else { return }
        do {
            guard cardEditor?.id == request.parentEditorID,
                  let bulk = try db.cardBulkEntryDraft(),bulk.id == request.bulkDraftID,
                  let candidate = bulk.candidates.first(where:{ $0.id == request.candidateID }) else { throw CardBulkOriginalEditingError.changed }
            func matchingCard() throws -> Card {
                let preview = try db.previewCardBulkEntry(candidates:[candidate],configuration:bulk.configuration,selectedIDs:[candidate.id])
                guard preview.items.first?.duplicateCardID == request.cardID,
                      let card = try db.card(id:request.cardID),card.deletedAt == nil else { throw CardBulkOriginalEditingError.changed }
                return card
            }
            _ = try matchingCard()
            let parent = cardEditor,parentReturn = cardWorkflow.duplicateReturn
            var parentRetained = false
            if let parent {
                guard let persistence = draftPersistence else { throw CardBulkOriginalEditingError.persistence }
                persistCardEditorDraft()
                guard draftSaveError == nil else { throw CardBulkOriginalEditingError.persistence }
                try persistence.flush()
                parentRetained = persistence.cardDrafts.contains { $0.id == parent.id }
            }
            let current = try matchingCard()
            let editor = CardDraft(card:current,tagsText:TagParser.format(current.tags))
            if let previous = bulkOriginalEditing.returning, previous.editorID == parent?.id {
                // A second original may be opened from the same batch. Retain the first
                // input's return path while keeping the intervening original as its own draft.
                bulkOriginalEditing.returning = .init(editorID:editor.id,bulkDraftID:bulk.id,parent:previous.parent,
                    parentWasPersisted:previous.parentWasPersisted,parentReturn:previous.parentReturn)
            } else {
                bulkOriginalEditing.returning = .init(editorID:editor.id,bulkDraftID:bulk.id,parent:parent,
                    parentWasPersisted:parentRetained,parentReturn:parentReturn)
            }
            cardWorkflow.duplicateReturn = nil
            cardEditor = editor
            closingCardEditor = false
            draftRecoveryNotice = "批量录入已保留。可保存原卡后返回批量录入，也可保留未保存修改后返回。"
        } catch {
            report(error)
            showsCardBulkEntry = true
        }
    }

    var canReturnToBulkEntry: Bool {
        guard !fullBackupBusy,let context = bulkOriginalEditing.returning else { return false }
        return cardEditor?.id == context.editorID
    }

    /// Preserve both inputs. A changed original parent is restored through the ordinary
    /// conflict-to-new-card policy, never silently written back over newer database content.
    @discardableResult
    func returnToBulkEntry(allowClosedEditor: Bool = false) -> Bool {
        guard !fullBackupBusy,let context = bulkOriginalEditing.returning,
              cardEditor?.id == context.editorID || (allowClosedEditor && cardEditor == nil) else { return false }
        do {
            guard try db.cardBulkEntryDraft()?.id == context.bulkDraftID else { throw CardBulkOriginalEditingError.changed }
            if cardEditor != nil {
                guard let persistence = draftPersistence else { throw CardBulkOriginalEditingError.persistence }
                persistCardEditorDraft()
                guard draftSaveError == nil else { throw CardBulkOriginalEditingError.persistence }
                try persistence.flush()
            }
            var parent = context.parent
            var notice: String?
            if let originalParent = context.parent {
                if let saved = savedCardDrafts.first(where:{ $0.id == originalParent.id }) {
                    let current = try saved.card.id.flatMap { try db.card(id:$0) }
                    var recovery = saved.restored(current:current)
                    if let id = recovery.draft.card.highlightId {
                        let highlight = try db.highlight(id:id)
                        if highlight == nil || highlight?.deletedAt != nil { recovery.draft.card.highlightId = nil }
                    }
                    try draftPersistence?.recordCard(recovery.draft,original:current)
                    try draftPersistence?.flush()
                    parent = recovery.draft;notice = recovery.notice
                } else if context.parentWasPersisted { throw CardBulkOriginalEditingError.missingParent }
                else if let id = originalParent.card.id {
                    // An unchanged parent is not listed among saved drafts. Re-read it,
                    // especially when the original just edited is that same card.
                    if let current = try db.card(id:id),current.deletedAt == nil {
                        var latest = originalParent
                        latest.card = current;latest.tagsText = TagParser.format(current.tags)
                        parent = latest
                    } else {
                        let recovery = SavedCardDraft(draft:originalParent,original:originalParent.card).restored(current:nil)
                        parent = recovery.draft;notice = recovery.notice
                    }
                }
            }
            bulkOriginalEditing.returning = nil
            cardEditor = parent
            cardWorkflow.duplicateReturn = context.parentReturn
            closingCardEditor = false
            draftRecoveryNotice = notice
            showsCardBulkEntry = true
            return true
        } catch {
            if cardEditor != nil { cardEditor?.error = error.localizedDescription } else { report(error) }
            return false
        }
    }

    func resumeBulkAfterOriginalEditorDismissed() {
        guard cardEditor == nil,bulkOriginalEditing.returning != nil else { return }
        _ = returnToBulkEntry(allowClosedEditor:true)
    }
}
