import Foundation
import GRDB
import KongReviewCore

struct CardContentVersion: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var card: Card
    static func sameContent(_ a: Card, _ b: Card) -> Bool {
        a.front == b.front && a.back == b.back && a.fields == b.fields && a.sections == b.sections && a.noteType == b.noteType
    }
    func applying(to current: Card) -> Card {
        var result = current
        result.front = card.front; result.back = card.back; result.fields = card.fields
        result.sections = card.sections; result.noteType = card.noteType
        return result
    }
}

enum CardComparisonError: LocalizedError {
    case changed, noAnswer, noAnswerField, noDraft
    var errorDescription: String? {
        switch self {
        case .changed: "已有卡片已发生变化，请重新打开对照后再确认。"
        case .noAnswer: "当前输入没有可以追加的答案。"
        case .noAnswerField: "已有卡片的模板没有独立背面字段，请打开原卡手动补充。"
        case .noDraft: "编辑内容已变化，请重新打开对照。"
        }
    }
}

extension AppDatabase {
    func liveCardDuplicate(_ card: Card) async throws -> Card? {
        try await writer.read { db in
            try Task.checkCancellation()
            return try Self.matchingFront(card,deleted:false,in:db) ?? Self.matchingFront(card,deleted:true,in:db)
        }
    }
    static func recordCardContentHistory(before: Card, after: Card, in db: Database) throws {
        guard let id = before.id, !CardContentVersion.sameContent(before,after) else { return }
        let key = "card-content-history.\(id)"
        var versions = try readProgress([CardContentVersion].self,key:key,in:db) ?? []
        if versions.last.map({ !CardContentVersion.sameContent($0.card,before) }) ?? true {
            versions.append(.init(date:before.updatedAt,card:before))
        }
        versions.append(.init(date:after.updatedAt,card:after))
        if versions.count > 100 { versions.removeFirst(versions.count-100) }
        try putProgress(versions,key:key,in:db)
    }
    func cardContentHistory(id: Int64) throws -> [CardContentVersion] {
        Array((try progressValue([CardContentVersion].self,key:"card-content-history.\(id)") ?? []).reversed())
    }
    /// Compatibility entry point: append all answer blocks to the first independent answer location.
    func appendCardAnswer(from incoming: Card, to expected: Card) throws -> Card {
        let templates = try writer.read { db in
            (try incoming.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) },
             try expected.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) })
        }
        let blocks = CardAnswerAppendComposer.sources(for:incoming,template:templates.0)
        guard !blocks.isEmpty else { throw CardComparisonError.noAnswer }
        guard let target = CardAnswerAppendComposer.destinations(for:expected,template:templates.1).first else {
            throw CardComparisonError.noAnswerField
        }
        let preview = try CardAnswerAppendComposer.preview(from:incoming,to:expected,
            incomingTemplate:templates.0,existingTemplate:templates.1,
            selection:.init(sourceIDs:Set(blocks.map(\.id)),target:target.id))
        return try appendCardAnswer(preview)
    }

    /// Validate the complete card and template snapshots, then save the very same composition as the preview.
    func appendCardAnswer(_ preview: CardAnswerAppendPreview) throws -> Card {
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
            current.updatedAt = Date(); try current.save(db)
            try Self.recordCareAdjustment(before:before,after:current,in:db)
            try Self.recordTopicCardEdit(before:before,after:current,in:db)
            return current
        }
    }
}
