import Foundation
import CryptoKit
import GRDB
import KongReviewCore

/// Input validation is deliberately independent from destructive duplicate cleanup.
struct CardFrontIdentity: Equatable {
    var text: String
    var media: [String]

    static func make(_ source: String, mediaData: (String) throws -> Data?) rethrows -> Self? {
        let html = Markdown.html(source)
            .replacingOccurrences(of:#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,with:"",options:.regularExpression)
        var media: [String] = []
        let pattern = #"(?is)<(?:img|audio|video|source)\b[^>]*?\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))|\[sound:([^\]]+)\]"#
        let ns = html as NSString
        let matches = (try? NSRegularExpression(pattern:pattern))?.matches(in:html,range:NSRange(location:0,length:ns.length)) ?? []
        for match in matches {
            let raw = (1..<match.numberOfRanges).first { match.range(at:$0).location != NSNotFound }.map { ns.substring(with:match.range(at:$0)) } ?? ""
            let ref = Markdown.plainText(fromHTML:raw)
            let name: String
            if ref.hasPrefix("kr-media://"), let url = URL(string:ref) { name = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst()) }
            else { name = ref.removingPercentEncoding ?? ref }
            if let data = try mediaData(name) {
                media.append("sha256:" + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
            } else { media.append("ref:" + ref) }
        }
        let visible = decodeNumericEntities(Markdown.plainText(fromHTML:html.replacingOccurrences(of:#"\[sound:[^\]]+\]"#,with:"",options:.regularExpression)))
        let text = visible.folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            .precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator:" ")
        guard !text.isEmpty || !media.isEmpty else { return nil }
        return Self(text:text,media:media)
    }
    private static func decodeNumericEntities(_ value: String) -> String {
        let re = try! NSRegularExpression(pattern:#"&#(x?)([0-9a-fA-F]+);"#,options:.caseInsensitive)
        let ns = value as NSString
        var result = value
        for m in re.matches(in:value,range:NSRange(location:0,length:ns.length)).reversed() {
            let radix = m.range(at:1).length == 0 ? 10 : 16
            if let n = UInt32(ns.substring(with:m.range(at:2)),radix:radix), let scalar = Unicode.Scalar(n) {
                result = (result as NSString).replacingCharacters(in:m.range,with:String(scalar))
            }
        }
        return result
    }

}

enum CardInputDuplicateError: LocalizedError {
    case active(Card), deleted(Card), batch(Card)
    var card: Card { switch self { case .active(let c), .deleted(let c), .batch(let c): c } }
    var errorDescription: String? {
        switch self {
        case .active(let c): "已有相同正面的记忆卡（牌组：\(c.deck)）。请查看已有卡片或修改正面。"
        case .batch(let c): "本批生成的卡片中有相同正面（牌组：\(c.deck)），尚未保存本批卡片。请调整题面。"
        case .deleted(let c): "最近删除中有相同正面的卡片（牌组：\(c.deck)）。可以恢复，也可以继续新建。"
        }
    }
}

extension AppDatabase {
    private static func frontIdentity(_ card: Card, in db: Database) throws -> CardFrontIdentity? {
        let template = try card.noteType.flatMap { try NoteTemplate.fetchOne(db,key:$0) }
        var front = card.faces(using:template).front
        // Templates omit playback markers from rendered text; retain front audio in identity.
        if let template, !card.fields.isEmpty {
            for index in template.front where card.fields.indices.contains(index) {
                let field = card.fields[index] as NSString
                let re = try NSRegularExpression(pattern:#"\[sound:[^\]]+\]"#)
                front += re.matches(in:field as String,range:NSRange(location:0,length:field.length)).map { field.substring(with:$0.range) }.joined()
            }
        }
        return try CardFrontIdentity.make(front) { name in
            try Data.fetchOne(db,sql:"SELECT data FROM card_media WHERE name = ?",arguments:[name])
        }
    }
    static func matchingFront(_ card: Card, deleted: Bool, in db: Database) throws -> Card? {
        guard let target = try frontIdentity(card,in:db) else { return nil }
        let rows = try Card.fetchCursor(db,sql:"SELECT * FROM card WHERE deletedAt IS " + (deleted ? "NOT NULL" : "NULL") + " ORDER BY id")
        while let existing = try rows.next() {
            if existing.id != card.id, try frontIdentity(existing,in:db) == target { return existing }
        }
        return nil
    }
    /// All cards in a batch either save together or remain unchanged (including cloze batches).
    func saveInputCards(_ cards: [Card], allowDeleted: Bool = false) throws -> [Card] {
        try writer.write { db in
            var result: [Card] = []
            for var card in cards {
                if let found = try Self.matchingFront(card,deleted:false,in:db) {
                    if result.contains(where: { $0.id == found.id }) { throw CardInputDuplicateError.batch(found) }
                    throw CardInputDuplicateError.active(found)
                }
                if !allowDeleted, let found = try Self.matchingFront(card,deleted:true,in:db) { throw CardInputDuplicateError.deleted(found) }
                let before = try card.id.flatMap { try Card.fetchOne(db,key:$0) }
                card.updatedAt = Date(); try card.save(db)
                if let before {
                    try Self.recordCareAdjustment(before:before,after:card,in:db)
                    try Self.recordTopicCardEdit(before:before,after:card,in:db)
                }
                result.append(card)
            }
            return result
        }
    }
    func restoreInputDuplicate(id: Int64) throws {
        try writer.write { db in
            guard var card = try Card.fetchOne(db,key:id), card.deletedAt != nil else { return }
            if let found = try Self.matchingFront(card,deleted:false,in:db) { throw CardInputDuplicateError.active(found) }
            card.deletedAt = nil; card.updatedAt = Date(); try card.save(db)
        }
    }
}
