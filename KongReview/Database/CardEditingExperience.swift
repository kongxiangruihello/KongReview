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
    /// Append only to the selected card; compare the full saved snapshot in the transaction.
    func appendCardAnswer(from incoming: Card, to expected: Card) throws -> Card {
        try writer.write { db in
            guard let id = expected.id, var current = try Card.fetchOne(db,key:id), current == expected, current.deletedAt == nil else { throw CardComparisonError.changed }
            let template = try incoming.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) }
            let answer = incoming.faces(using:template).back
            guard HTMLSourceCodec.hasContent(answer) || answer.contains("[sound:") else { throw CardComparisonError.noAnswer }
            let before = current
            let addition = "<hr><p>补充答案</p>" + Markdown.html(answer)
            if let name = current.noteType, !current.fields.isEmpty {
                guard let t = try NoteTemplate.fetchOne(db,key:name),
                      let index = t.back.first(where: { current.fields.indices.contains($0) && !t.front.contains($0) }) else { throw CardComparisonError.noAnswerField }
                current.fields[index] = Markdown.html(current.fields[index]) + addition
                current.front = current.fields[0]; current.back = current.fields.dropFirst().joined(separator:"<hr>")
            } else { current.back = Markdown.html(current.back) + addition }
            current.updatedAt = Date(); try current.save(db)
            try Self.recordCareAdjustment(before:before,after:current,in:db)
            try Self.recordTopicCardEdit(before:before,after:current,in:db)
            return current
        }
    }
}
