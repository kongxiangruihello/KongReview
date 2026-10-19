import Foundation
import GRDB
import KongReviewCore

/// Created only after both snapshots have been read within the append transaction.
/// The global receipt makes a token single-use and replaces it on the next append.
struct CardAppendUndoToken: Sendable {
    let id: UUID
    let before: Card
    let after: Card
    fileprivate let template: NoteTemplate?
    fileprivate let contentVersionID: UUID

    fileprivate init(before: Card, after: Card, template: NoteTemplate?, contentVersionID: UUID) {
        id = UUID(); self.before = before; self.after = after
        self.template = template; self.contentVersionID = contentVersionID
    }
}

enum CardAppendUndoError: LocalizedError, Equatable {
    case expired, cardUnavailable, contentChanged, templateChanged, duplicateFront, backupBusy, cardBeingEdited

    var errorDescription: String? {
        switch self {
        case .expired: "这次追加已经撤销，或已有更新的追加操作，无法再次撤销。"
        case .cardUnavailable: "原卡片已删除或不存在，无法撤销；不会重新创建卡片。"
        case .contentChanged: "原卡片的正文已再次修改，无法覆盖。请打开原卡或正文修改历史查看。"
        case .templateChanged: "原卡片的模板已变化，无法安全撤销。请打开原卡检查。"
        case .duplicateFront: "恢复后的正面与另一张卡片重复，未执行撤销。请先处理重复卡片。"
        case .backupBusy: "完整备份操作进行中，请完成后再撤销追加。"
        case .cardBeingEdited: "这张原卡正在编辑，请先保存或关闭编辑器，再撤销本次追加。当前输入仍保留。"
        }
    }
}

extension AppDatabase {
    private static let latestCardAppendUndoKey = "card-append-undo.latest"

    func appendCardAnswerRecordingUndo(_ preview: CardAnswerAppendPreview) throws -> CardAppendUndoToken {
        try writer.write { db in
            guard let id = preview.existing.id, let before = try Card.fetchOne(db,key:id),
                  before == preview.existing, before.deletedAt == nil else { throw CardComparisonError.changed }
            guard try Self.matchingFront(preview.incoming,deleted:false,in:db)?.id == id else { throw CardComparisonError.changed }
            let incomingTemplate = try preview.incoming.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) }
            let existingTemplate = try before.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) }
            guard incomingTemplate == preview.incomingTemplate, existingTemplate == preview.existingTemplate else {
                throw CardComparisonError.changed
            }
            var current = try CardAnswerAppendComposer.preview(from:preview.incoming,to:before,
                incomingTemplate:incomingTemplate,existingTemplate:existingTemplate,selection:preview.selection).result
            guard current == preview.result else { throw CardComparisonError.changed }
            current.updatedAt = Date(); try current.update(db)
            // Reload before making the receipt: SQLite date precision is the comparison baseline.
            guard let after = try Card.fetchOne(db,key:id) else { throw CardComparisonError.changed }
            try Self.recordCareAdjustment(before:before,after:after,in:db)
            try Self.recordTopicCardEdit(before:before,after:after,in:db)
            guard let version = try Self.readProgress([CardContentVersion].self,key:"card-content-history.\(id)",in:db)?.last else {
                throw CardComparisonError.changed
            }
            let token = CardAppendUndoToken(before:before,after:after,template:existingTemplate,contentVersionID:version.id)
            try Self.putProgress(token.id,key:Self.latestCardAppendUndoKey,in:db)
            return token
        }
    }

    /// Restore only content into the latest row; later ratings, tags, deck and links are retained.
    @discardableResult
    func undoCardAppend(_ token: CardAppendUndoToken) throws -> Card {
        try writer.write { db in
            guard try Self.readProgress(UUID.self,key:Self.latestCardAppendUndoKey,in:db) == token.id else {
                throw CardAppendUndoError.expired
            }
            guard let id = token.before.id, id == token.after.id,
                  let current = try Card.fetchOne(db,key:id), current.deletedAt == nil else {
                throw CardAppendUndoError.cardUnavailable
            }
            let template = try current.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) }
            guard template == token.template else { throw CardAppendUndoError.templateChanged }
            guard CardContentVersion.sameContent(current,token.after),
                  try Self.readProgress([CardContentVersion].self,key:"card-content-history.\(id)",in:db)?.last?.id == token.contentVersionID else {
                throw CardAppendUndoError.contentChanged
            }
            var restored = CardContentVersion(date:token.before.updatedAt,card:token.before).applying(to:current)
            guard try Self.matchingFront(restored,deleted:false,in:db) == nil else { throw CardAppendUndoError.duplicateFront }
            restored.updatedAt = Date(); try restored.update(db)
            guard let saved = try Card.fetchOne(db,key:id) else { throw CardAppendUndoError.cardUnavailable }
            try Self.recordCareAdjustment(before:current,after:saved,in:db)
            try Self.recordTopicCardEdit(before:current,after:saved,in:db)
            try db.execute(sql:"DELETE FROM app_progress WHERE key=?",arguments:[Self.latestCardAppendUndoKey])
            return saved
        }
    }
}
