import Foundation
import KongReviewCore

extension LibraryStore {
    var canReturnToIncomingCardDraft: Bool {
        guard !fullBackupBusy, let context = cardWorkflow.duplicateReturn,
              savedCardDrafts.contains(where: { $0.id == context.incomingID }) else { return false }
        if let current = cardEditor { return current.id == context.originalEditorID }
        return context.originalSaved
    }

    /// The original card and the incoming card are separate durable drafts. Switching back
    /// never commits either one and never bypasses the normal conflict recovery policy.
    @discardableResult
    func returnToIncomingCardDraft() -> Bool {
        guard !fullBackupBusy else {
            reportCardDraftReturnFailure("正在处理完整备份，请稍后再返回。本次输入和原卡修改均已保留。")
            return false
        }
        guard let context = cardWorkflow.duplicateReturn else { return false }
        if let current = cardEditor {
            guard current.id == context.originalEditorID else { return false }
        } else {
            // A cancel, discard, recovery, or a different editor session must not act like save.
            guard context.originalSaved else { return false }
        }
        guard let persistence = draftPersistence else {
            reportCardDraftReturnFailure("草稿保存暂不可用，尚未返回。请先保存或复制原卡中的修改。")
            return false
        }
        guard persistence.cardDrafts.contains(where: { $0.id == context.incomingID }) else {
            reportCardDraftReturnFailure("本次输入的草稿已不存在，尚未切换。原卡中的修改仍保留在当前编辑器。")
            return false
        }

        if cardEditor != nil {
            persistCardEditorDraft()
            if let message = draftSaveError {
                reportCardDraftReturnFailure(message, preservationFailed: true)
                return false
            }
        }
        do {
            try persistence.flush()
            // Use the most recent saved incoming snapshot and database state after flushing.
            guard let saved = persistence.cardDrafts.first(where: { $0.id == context.incomingID }) else {
                reportCardDraftReturnFailure("本次输入的草稿已不存在，尚未切换。原卡中的修改已保留。")
                return false
            }
            let current = try saved.card.id.flatMap { try db.card(id: $0) }
            var recovered = saved.restored(current: current)
            var notices = recovered.notice.map { [$0] } ?? []
            if let highlightID = recovered.draft.card.highlightId {
                let highlight = try db.highlight(id: highlightID)
                if highlight == nil || highlight?.deletedAt != nil {
                    recovered.draft.card.highlightId = nil
                    notices.append("关联的原摘录已删除，恢复的卡片已解除关联。")
                }
            }
            // Persist any conflict conversion or detached highlight before replacing the editor.
            try persistence.recordCard(recovered.draft, original: current)
            try persistence.flush()
            cardEditor = recovered.draft
            cardWorkflow.duplicateReturn = nil
            closingCardEditor = false
            draftRecoveryNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            return true
        } catch {
            reportCardDraftReturnFailure("草稿暂未能保存，尚未返回：" + error.localizedDescription,
                                         preservationFailed: true)
            return false
        }
    }

    private func reportCardDraftReturnFailure(_ message: String, preservationFailed: Bool = false) {
        if cardEditor != nil { cardEditor?.error = message }
        else { errorMessage = message }
        // Setting an inline error records the editor again; retain the first failed write.
        if preservationFailed { draftSaveError = message }
    }
}
