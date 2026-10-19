import Foundation
import GRDB
import KongReviewCore

private struct CardBulkFrontKey: Hashable {
    var text: String
    var media: [String]
    init(_ identity: CardFrontIdentity) { text = identity.text;media = identity.media }
}

extension AppDatabase {
    func previewCardBulkEntry(candidates: [CardBulkEntryCandidate], configuration: CardBulkEntryConfiguration,
                              selectedIDs: Set<UUID>) throws -> CardBulkEntryPreview {
        try writer.read { sql in
            try Self.cardBulkPreview(candidates:candidates,configuration:configuration,selectedIDs:selectedIDs,in:sql)
        }
    }

    /// Recheck exactly the reviewed candidate data against the latest preset, template,
    /// media and active/trash cards in the same transaction as the inserts and entry log.
    /// A duplicate, invalid required field or write failure rolls back every card.
    func saveCardBulkEntry(_ preview: CardBulkEntryPreview, draft: CardBulkEntryDraft? = nil) throws -> [Card] {
        try writer.write { sql in
            if let draft {
                guard try !Self.cardBulkEntryWasClosed(draft.id,in:sql) else { throw CardBulkEntryError.alreadySaved }
                guard try Self.cardBulkEntryDraft(in:sql) == draft,
                      draft.configuration == preview.configuration,draft.candidates == preview.candidates,
                      draft.selectedIDs == preview.selectedIDs else { throw CardBulkEntryError.draftChanged }
            }
            guard !preview.selectedIDs.isEmpty else { throw CardBulkEntryError.emptySelection }
            let templates = Dictionary(uniqueKeysWithValues:try NoteTemplate.fetchAll(sql).map { ($0.name,$0) })
            let template = preview.configuration.preset?.noteType.flatMap { templates[$0] }
            guard template == preview.template else { throw CardBulkEntryError.changedTemplate }
            let fresh = try Self.cardBulkPreview(candidates:preview.candidates,configuration:preview.configuration,
                                                selectedIDs:preview.selectedIDs,in:sql,templates:templates)
            let selected = fresh.items.filter { fresh.selectedIDs.contains($0.id) }
            guard !selected.isEmpty else { throw CardBulkEntryError.emptySelection }
            if let invalid = selected.first(where:{ $0.card == nil || !$0.issues.isEmpty }) {
                throw CardBulkEntryError.invalidCandidate(invalid.candidate.line,invalid.issues.first ?? "卡片尚未通过检查。")
            }
            var saved: [Card] = []
            let now = Date()
            for item in selected {
                guard var card = item.card,card.id == nil else { throw CardBulkEntryError.changedSelection }
                card.createdAt = now;card.updatedAt = now;card.due = now
                try card.insert(sql)
                try Self.recordCardEntry(card,at:now,in:sql)
                saved.append(card)
            }
            if let draft { try Self.closeCardBulkEntryDraft(draft.id,in:sql) }
            return saved
        }
    }

    private static func cardBulkPreview(candidates: [CardBulkEntryCandidate], configuration: CardBulkEntryConfiguration,
                                        selectedIDs: Set<UUID>, in sql: Database,
                                        templates supplied: [String:NoteTemplate]? = nil) throws -> CardBulkEntryPreview {
        guard candidates.count <= CardBulkEntryParser.maximumCards else { throw CardBulkEntryError.tooMany }
        let IDs = Set(candidates.map(\.id))
        guard IDs.count == candidates.count, selectedIDs.isSubset(of:IDs),candidates.allSatisfy({ $0.line > 0 }) else {
            throw CardBulkEntryError.changedSelection
        }
        if let expected = configuration.preset {
            let payload = try Data.fetchOne(sql,sql:"SELECT payload FROM app_progress WHERE key=?",arguments:[cardEntryPresetProgressKey])
            let library = try payload.map { try JSONDecoder().decode(CardEntryPresetLibrary.self,from:$0) } ?? .init()
            guard library.presets.first(where:{ $0.id == expected.id }) == expected else { throw CardBulkEntryError.changedPreset }
        }
        let templates = try supplied ?? Dictionary(uniqueKeysWithValues:NoteTemplate.fetchAll(sql).map { ($0.name,$0) })
        if let preset = configuration.preset { try preset.validate(templates:templates) }
        // Build the current front index once, using the same normalization/media identity
        // as the single-card input check. No entire-card bodies are copied into the preview.
        var existing: [CardBulkFrontKey:(id:Int64?,deck:String,deleted:Bool)] = [:]
        let cards = try Card.fetchCursor(sql,sql:"SELECT * FROM card ORDER BY deletedAt IS NOT NULL,id")
        while let card = try cards.next() {
            if let key = try cardBulkFrontKey(card,templates:templates,in:sql),existing[key] == nil {
                existing[key] = (card.id,card.deck,card.deletedAt != nil)
            }
        }
        var selectedFronts: [CardBulkFrontKey:Int] = [:]
        var items: [CardBulkEntryPreviewItem] = []
        for candidate in candidates {
            var item = CardBulkEntryPreviewItem(candidate:candidate)
            do {
                let card = try configuration.makeCard(candidate,templates:templates)
                item.card = card
                if let key = try cardBulkFrontKey(card,templates:templates,in:sql) {
                    if let found = existing[key] {
                        item.duplicateCardID = found.id
                        item.duplicateIsDeleted = found.deleted
                        item.issues.append(found.deleted
                            ? "最近删除中已有相同正面的卡片（牌组：\(found.deck)）；请恢复原卡，或修改本条正面。"
                            : "已有相同正面的卡片（牌组：\(found.deck)）；请修改本条正面，或取消勾选。")
                    }
                    if selectedIDs.contains(candidate.id) {
                        if let line = selectedFronts[key] {
                            item.issues.append("与本批第 \(line) 行的正面重复；请修改内容，或只勾选其中一张。")
                        } else { selectedFronts[key] = candidate.line }
                    }
                } else { item.issues.append("请填写可显示的正面内容。") }
            } catch { item.issues.append(error.localizedDescription) }
            items.append(item)
        }
        return .init(configuration:configuration,candidates:candidates,selectedIDs:selectedIDs,items:items,
                     template:configuration.preset?.noteType.flatMap { templates[$0] })
    }

    private static func cardBulkFrontKey(_ card: Card, templates: [String:NoteTemplate], in sql: Database) throws -> CardBulkFrontKey? {
        let template = card.noteType.flatMap { templates[$0] }
        var front = card.faces(using:template).front
        if let template,!card.fields.isEmpty {
            let expression = try NSRegularExpression(pattern:#"\[sound:[^\]]+\]"#)
            for index in template.front where card.fields.indices.contains(index) {
                let field = card.fields[index] as NSString
                front += expression.matches(in:field as String,range:NSRange(location:0,length:field.length))
                    .map { field.substring(with:$0.range) }.joined()
            }
        }
        return try CardFrontIdentity.make(front) { name in
            try Data.fetchOne(sql,sql:"SELECT data FROM card_media WHERE name=?",arguments:[name])
        }.map(CardBulkFrontKey.init)
    }
}
