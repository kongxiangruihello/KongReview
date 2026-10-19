import Foundation
import Observation
import KongReviewCore

struct CardEntryHistoryEditRequest {
    var id: Int64
    var query: CardEntryHistoryQuery
    var generation: UUID
}

@MainActor @Observable final class CardEntryHistoryState {
    var isPresented = false
    var generation = UUID()
    var pendingEdit: CardEntryHistoryEditRequest?
    func clear() { isPresented = false;generation = UUID();pendingEdit = nil }
}

extension LibraryStore {
    func scheduleCardEntryHistoryEdit(id: Int64, query: CardEntryHistoryQuery, generation: UUID) {
        guard !fullBackupBusy,cardEntryHistory.generation == generation else { return }
        do {
            try db.validateCardEntryHistorySelection([id],query:query)
            cardEntryHistory.pendingEdit = .init(id:id,query:query,generation:generation)
            cardEntryHistory.isPresented = false
        } catch { report(error) }
    }

    func performPendingCardEntryHistoryEdit() {
        guard let request = cardEntryHistory.pendingEdit else { return }
        cardEntryHistory.pendingEdit = nil
        guard !fullBackupBusy,request.generation == cardEntryHistory.generation else { return }
        do {
            try db.validateCardEntryHistorySelection([request.id],query:request.query)
            _ = openRecordedCardPreservingDraft(id:request.id)
        } catch { report(error) }
    }

    @discardableResult
    func openRecordedCardPreservingDraft(id: Int64) -> Bool {
        guard !fullBackupBusy else { return false }
        do {
            guard let current = try db.card(id:id),current.deletedAt == nil else { throw CardEntryBatchError.stale }
            let incoming = cardEditor
            if incoming != nil {
                guard let persistence = draftPersistence else {
                    cardEditor?.error = "草稿保存暂不可用，请先保存当前输入再打开录入记录。"
                    return false
                }
                persistCardEditorDraft()
                guard draftSaveError == nil else { return false }
                try persistence.flush()
            }
            guard let latest = try db.card(id:id),latest.deletedAt == nil else { throw CardEntryBatchError.stale }
            let draft = CardDraft(card:latest,tagsText:TagParser.format(latest.tags))
            let retained = incoming.map { old in savedCardDrafts.contains { $0.id == old.id } } ?? false
            cardEditor = draft
            cardWorkflow.duplicateReturn = retained ? .init(incomingID:incoming!.id,originalEditorID:draft.id) : nil
            if retained { draftRecoveryNotice = "当前输入已保留，可返回本次草稿，或保存这张卡后返回。" }
            closingCardEditor = false
            return true
        } catch {
            if cardEditor != nil { cardEditor?.error = error.localizedDescription } else { report(error) }
            return false
        }
    }

    func changeCardEntryHistory(ids: [Int64], allowedIDs: [Int64], query: CardEntryHistoryQuery, generation: UUID, change: CardEntryBatchChange) throws {
        guard !fullBackupBusy,cardEntryHistory.generation == generation,Set(ids).isSubset(of:Set(allowedIDs)) else { throw CardEntryBatchError.stale }
        try changeCardEntryOrganization(ids:ids,allowedIDs:allowedIDs,change:change,historyQuery:query)
    }
}
