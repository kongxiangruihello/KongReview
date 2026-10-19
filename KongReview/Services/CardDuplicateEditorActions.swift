import Foundation
import GRDB
import KongReviewCore

extension LibraryStore {
    /// Read again after flushing the editor: its front may no longer be a duplicate.
    func duplicateCardPreview(_ duplicate: Card, forAppend: Bool) throws -> Card {
        guard let incoming = cardEditor else { throw DuplicateEditorError.changed }
        return try db.writer.read { sql in
            guard let id = duplicate.id, id != incoming.card.id,
                  let current = try Card.fetchOne(sql,key:id) else { throw DuplicateEditorError.missing }
            if forAppend && current.deletedAt != nil { throw DuplicateEditorError.deleted }
            guard try AppDatabase.matchingFront(incoming.card,deleted:current.deletedAt != nil,in:sql)?.id == id else {
                throw DuplicateEditorError.changed
            }
            return current
        }
    }

    /// Opening an existing duplicate must never consume the unsaved card that led to it.
    /// All checks and draft writes finish before the editor changes to the latest saved card.
    @discardableResult
    func editOriginalDuplicate(_ duplicate: Card) -> Bool {
        guard let incoming = cardEditor else { return false }
        guard !fullBackupBusy else {
            cardEditor?.error = "正在处理完整备份，请稍后再编辑原卡。当前输入已保留。"
            return false
        }

        func reloadMatchingOriginal() throws -> Card {
            try db.writer.read { sql in
                guard let id = duplicate.id, id != incoming.card.id,
                      let current = try Card.fetchOne(sql, key: id) else {
                    throw DuplicateEditorError.missing
                }
                guard current.deletedAt == nil else { throw DuplicateEditorError.deleted }
                guard try AppDatabase.matchingFront(incoming.card, deleted: false, in: sql)?.id == id else {
                    throw DuplicateEditorError.changed
                }
                return current
            }
        }

        do {
            _ = try reloadMatchingOriginal()
            guard let persistence = draftPersistence else {
                let message = "草稿保存暂不可用，无法安全切换到原卡。当前输入已保留，请先保存或复制内容。"
                cardEditor?.error = message
                draftSaveError = message
                return false
            }

            persistCardEditorDraft()
            if let message = draftSaveError {
                cardEditor?.error = message
                // Updating the inline error also invokes draft persistence. Keep a failed
                // preservation visible even if that second write happens to succeed.
                draftSaveError = message
                return false
            }
            do { try persistence.flush() }
            catch {
                let message = "草稿暂未能保存，尚未切换到原卡：" + error.localizedDescription
                cardEditor?.error = message
                draftSaveError = message
                return false
            }

            // Another writer may have updated or removed the card during the disk write.
            // Recheck its front and open the current saved state, including progress and tags.
            let current = try reloadMatchingOriginal()
            let retained = persistence.cardDrafts.contains { $0.id == incoming.id }
            let hadEarlierInput = cardWorkflow.duplicateReturn != nil
            study.rememberBrowsingCard(current.id)
            let originalEditor = CardDraft(card: current, tagsText: TagParser.format(current.tags))
            cardEditor = originalEditor
            cardWorkflow.duplicateReturn = retained
                ? CardDraftReturnContext(incomingID: incoming.id, originalEditorID: originalEditor.id) : nil
            closingCardEditor = false
            if retained {
                draftRecoveryNotice = "刚才输入的内容已保留，可用上方“返回本次草稿”继续编辑。"
                    + (hadEarlierInput ? "更早的输入仍保留在首页的草稿恢复入口。" : "也可从首页的草稿恢复入口找回。")
            }
            return true
        } catch {
            cardEditor?.error = error.localizedDescription
            return false
        }
    }
}

private enum DuplicateEditorError: LocalizedError {
    case missing, deleted, changed

    var errorDescription: String? {
        switch self {
        case .missing: "原卡已不存在，当前输入已保留。请重新检查重复内容。"
        case .deleted: "原卡已移到最近删除，当前输入已保留。请先恢复原卡。"
        case .changed: "正面或原卡已变化，当前输入已保留。请重新检查重复内容。"
        }
    }
}
