import Foundation
import GRDB
import KongReviewCore

struct CardEntryBatchEditRequest {
    var batchID: UUID
    var cardID: Int64
}

struct CardEntryBatchPage: Sendable {
    var cards: [Card]
    var total: Int
    var page: Int
    var pageCount: Int
    static let size = 50
}

enum CardEntryBatchChange {
    case move(String)
    case tags([String], CardTagBatchMode)
}

enum CardEntryBatchError: LocalizedError {
    case stale, emptyDeck, emptyTags
    var errorDescription: String? {
        switch self {
        case .stale: "本次录入或所选卡片已变化，请刷新列表后再操作。"
        case .emptyDeck: "请输入目标牌组。"
        case .emptyTags: "请输入至少一个标签。"
        }
    }
}

extension AppDatabase {
    func cardEntryBatchPage(ids: [Int64], page: Int) throws -> CardEntryBatchPage {
        let json = String(decoding:try JSONEncoder().encode(Array(Set(ids))),as:UTF8.self)
        return try writer.read { sql in
            let filter = "deletedAt IS NULL AND id IN (SELECT value FROM json_each(?))"
            let total = try Int.fetchOne(sql,sql:"SELECT COUNT(*) FROM card WHERE " + filter,arguments:[json]) ?? 0
            let pages = max(1,(total + CardEntryBatchPage.size - 1) / CardEntryBatchPage.size)
            let current = min(max(1,page),pages)
            let cards = try Card.fetchAll(sql,sql:"SELECT * FROM card WHERE " + filter + " ORDER BY id DESC LIMIT ? OFFSET ?",
                arguments:[json,CardEntryBatchPage.size,(current - 1) * CardEntryBatchPage.size])
            return .init(cards:cards,total:total,page:current,pageCount:pages)
        }
    }

    /// Compatibility entry point for callers that use native tag undo snapshots.
    /// The same transaction also updates the latest organization receipt.
    func changeCardEntryBatch(ids: [Int64], allowedIDs: [Int64], change: CardEntryBatchChange) throws -> UndoSnapshot? {
        let token = try changeCardEntryOrganizationRecordingUndo(ids:ids,allowedIDs:allowedIDs,change:change)
        guard case .tags = change else { return nil }
        return token?.legacyTagSnapshot ?? UndoSnapshot(highlightIds:[],sourceIds:[],cardIds:[],cards:[],
                                                       cardTagsOnly:true,cardTagUndoChanges:[:])
    }

}

extension LibraryStore {
    func scheduleCardEntryBatchEdit(id: Int64, batchID: UUID) {
        guard !fullBackupBusy,cardWorkflow.batchID == batchID,cardWorkflow.addedCardIDs.contains(id) else { return }
        cardWorkflow.pendingBatchEdit = .init(batchID:batchID,cardID:id)
        cardWorkflow.showsBatch = false
    }

    func performPendingCardEntryBatchEdit() {
        guard let request = cardWorkflow.pendingBatchEdit else { return }
        cardWorkflow.pendingBatchEdit = nil
        _ = editCardFromEntryBatch(id:request.cardID,batchID:request.batchID)
    }

    @discardableResult
    func editCardFromEntryBatch(id: Int64, batchID: UUID) -> Bool {
        guard !fullBackupBusy,cardWorkflow.batchID == batchID,cardWorkflow.addedCardIDs.contains(id) else { return false }
        do {
            guard let card = try db.card(id:id),card.deletedAt == nil else { throw CardEntryBatchError.stale }
            let incoming = cardEditor
            if incoming != nil {
                guard let persistence = draftPersistence else {
                    cardEditor?.error = "草稿保存暂不可用，请先保存当前输入再编辑本次卡片。"
                    return false
                }
                persistCardEditorDraft()
                guard draftSaveError == nil else { return false }
                try persistence.flush()
            }
            guard cardWorkflow.batchID == batchID,let latest = try db.card(id:id),latest.deletedAt == nil else { throw CardEntryBatchError.stale }
            let draft = CardDraft(card:latest,tagsText:TagParser.format(latest.tags))
            let retained = incoming.map { old in savedCardDrafts.contains { $0.id == old.id } } ?? false
            cardEditor = draft
            cardWorkflow.duplicateReturn = retained ? .init(incomingID:incoming!.id,originalEditorID:draft.id) : nil
            if retained { draftRecoveryNotice = "当前输入已保留，可从上方返回本次草稿，或保存这张卡后返回。" }
            closingCardEditor = false
            return true
        } catch {
            if cardEditor != nil { cardEditor?.error = error.localizedDescription }
            else { report(error) }
            return false
        }
    }

    func changeCurrentCardEntryBatch(ids: [Int64], batchID: UUID, change: CardEntryBatchChange) throws {
        guard !fullBackupBusy,cardWorkflow.batchID == batchID else { throw CardEntryBatchError.stale }
        try changeCardEntryOrganization(ids:ids,allowedIDs:cardWorkflow.addedCardIDs,change:change)
    }
}
