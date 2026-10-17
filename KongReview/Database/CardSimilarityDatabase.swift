import Foundation
import GRDB
import KongReviewCore

enum CardDuplicateScanMode: String, CaseIterable, Sendable {
    case exact, similar
    var title: String { self == .exact ? "完全重复" : "高度相似" }
}

struct CardSimilarityScan: Sendable {
    var groups: [CardDuplicateGroup]
    var scannedCount: Int
    var omittedCount: Int
    var comparisonsLimited: Bool
    var suggestionsLimited: Bool
    var textBudgetLimited = false
}

/// 候选有界：最多读取最近 5000 张；长文本不截断作相似判断；小型哈希桶限制候选对数。
/// 正反面均需高度相似；模板/字段/自定义栏目及媒体引用不一致时不提供整理建议。
enum CardSimilarity {
    static let cardLimit = 5_000
    static let textLimit = 4_000
    static let comparisonLimit = 150_000
    static let suggestionLimit = 100
    static let totalTextLimit = 4_000_000

    struct TextFace {
        var text: String
        var grams: Set<String>
        var media: [String]
    }
    struct Candidate {
        var card: Card
        var front: TextFace
        var back: TextFace
        var metadata: String
        var signature: CardDuplicateSignature
    }

    static func face(_ raw: String) -> TextFace? {
        // 超长 HTML 也不进入渲染，避免单张卡片占满后台任务。
        guard raw.utf8.count <= 48_000 else { return nil }
        let rendered = Card.renderHTML(raw)
        let text = Markdown.plainText(fromHTML: rendered)
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= textLimit else { return nil }
        let chars = Array(text)
        let grams = Set(chars.indices.dropLast().map { String(chars[$0...($0 + 1)]) })
        // 相同文字但不同图片、音频、链接不能因为去掉 HTML 而被视为相似。
        let pattern = #"(?i)(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))|\[sound:([^\]]+)\]"#
        let re = try? NSRegularExpression(pattern: pattern)
        let ns = rendered as NSString
        let media = (re?.matches(in: rendered, range: NSRange(location: 0, length: ns.length)) ?? []).map { match in
            (1..<match.numberOfRanges).compactMap { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }.joined()
        }
        return TextFace(text: text, grams: grams, media: media)
    }

    static func candidate(_ card: Card) -> Candidate? {
        guard let front = face(card.front), let back = face(card.back) else { return nil }
        let signature = CardDuplicateSignature(card)
        var metadata = signature
        metadata.front = ""
        metadata.back = ""
        return Candidate(card: card, front: front, back: back, metadata: metadata.stableID, signature: signature)
    }

    static func faceScore(_ a: TextFace, _ b: TextFace) -> Double? {
        guard a.media == b.media else { return nil }
        if a.text == b.text { return 1 }
        let small = min(a.text.count, b.text.count), large = max(a.text.count, b.text.count)
        guard small >= 12, Double(small) / Double(large) >= 0.88, !a.grams.isEmpty, !b.grams.isEmpty else { return nil }
        let score = 2 * Double(a.grams.intersection(b.grams).count) / Double(a.grams.count + b.grams.count)
        return score >= 0.92 ? score : nil
    }

    static func score(_ a: Candidate, _ b: Candidate) -> Double? {
        guard a.metadata == b.metadata,
              let front = faceScore(a.front, b.front), let back = faceScore(a.back, b.back) else { return nil }
        return min(front, back)
    }

    static func score(_ a: Card, _ b: Card) -> Double? {
        guard let first = candidate(a), let second = candidate(b) else { return nil }
        return score(first, second)
    }

    private static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    static func scan(_ cards: [Card], total: Int) throws -> CardSimilarityScan {
        var candidates: [Candidate] = []
        var buckets: [String: [Int]] = [:]
        var groups: [CardDuplicateGroup] = []
        var comparisons = 0
        var limited = false
        var suggestionLimited = false
        var omitted = max(0, total - cards.count)
        var visited = 0
        var skipped = 0
        var textSize = 0
        var textBudgetLimited = false
        for card in cards {
            try Task.checkCancellation()
            visited += 1
            guard let item = candidate(card) else { omitted += 1; skipped += 1; continue }
            let size = item.front.text.count + item.back.text.count
            guard textSize + size <= totalTextLimit else {
                omitted += 1
                skipped += 1
                textBudgetLimited = true
                continue
            }
            textSize += size
            // 取最小的 16 个稳定二元组哈希；高度重合文本通常共享多个桶。
            let keys = item.front.grams.map(stableHash).sorted().prefix(16).map { item.metadata + ":" + String($0) }
            var overlaps: [Int: Int] = [:]
            for key in keys { for index in buckets[key] ?? [] { overlaps[index, default: 0] += 1 } }
            let ordered = overlaps.sorted { $0.value == $1.value ? $0.key > $1.key : $0.value > $1.value }.prefix(64)
            for match in ordered {
                if comparisons >= comparisonLimit { limited = true; break }
                comparisons += 1
                let previous = candidates[match.key]
                guard previous.signature != item.signature,
                      let similarity = score(previous, item) else { continue }
                if groups.count >= suggestionLimit { suggestionLimited = true; break }
                groups.append(CardDuplicateGroup(signature: item.signature,
                    cards: [previous.card, card].sorted { ($0.id ?? 0) < ($1.id ?? 0) }, similarityScore: similarity))
            }
            if limited || suggestionLimited { break }
            let index = candidates.count
            candidates.append(item)
            for key in keys {
                buckets[key, default: []].append(index)
                if buckets[key, default: []].count > 64 { buckets[key]?.removeFirst() }
            }
        }
        groups.sort {
            let a = $0.similarityScore ?? 0, b = $1.similarityScore ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
        omitted += max(0, cards.count - visited)
        return CardSimilarityScan(groups: groups, scannedCount: visited - skipped, omittedCount: omitted,
                                  comparisonsLimited: limited, suggestionsLimited: suggestionLimited,
                                  textBudgetLimited: textBudgetLimited)
    }
}

extension AppDatabase {
    func similarCardGroups(deck: String? = nil) async throws -> CardSimilarityScan {
        let snapshot = try await writer.read { db in
            let filter = " WHERE deletedAt IS NULL" + (deck == nil ? "" : " AND deck = ?")
            let values: [any DatabaseValueConvertible] = deck.map { [$0] } ?? []
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card" + filter,
                                         arguments: StatementArguments(values)) ?? 0
            let sizeFilter = " AND length(CAST(front AS BLOB)) <= 48000 AND length(CAST(back AS BLOB)) <= 48000"
                + " AND length(CAST(coalesce(fields, '') AS BLOB)) <= 128000"
                + " AND length(CAST(coalesce(sections, '') AS BLOB)) <= 128000"
            let cards = try Card.fetchAll(db, sql: "SELECT * FROM card" + filter + sizeFilter + " ORDER BY updatedAt DESC, id DESC LIMIT ?",
                                          arguments: StatementArguments(values + [CardSimilarity.cardLimit]))
            return (cards, total)
        }
        return try CardSimilarity.scan(snapshot.0, total: snapshot.1)
    }
}
