import Foundation
import KongReviewCore

/// Queries only the already loaded draft snapshots; never opens the library database.
struct EditorDraftQuery: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "全部", highlight = "摘录", card = "记忆卡"
        var id: String { rawValue }
    }

    var keyword = ""
    var kind: Kind = .all
    var deck: String? = nil

    func page(highlights: [SavedHighlightDraft], cards: [SavedCardDraft],
              requestedPage: Int, pageSize: Int = 50) -> EditorDraftPage {
        let terms = ChineseFold.fold(keyword).split(whereSeparator: \.isWhitespace).map(String.init)
        let all = highlights.map(EditorDraftItem.highlight) + cards.map(EditorDraftItem.card)
        let matches = all.filter { item in
            if let deck {
                guard case .card(let draft) = item, draft.card.deck == deck else { return false }
            } else {
                if kind == .highlight, case .card = item { return false }
                if kind == .card, case .highlight = item { return false }
            }
            guard !terms.isEmpty else { return true }
            let searchable = ChineseFold.fold(item.searchableText)
            return terms.allSatisfy { searchable.contains($0) }
        }.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.id < $1.id
        }
        let size = max(1, pageSize)
        let count = max(1, (matches.count + size - 1) / size)
        let current = min(max(1, requestedPage), count)
        let start = (current - 1) * size
        return EditorDraftPage(items: Array(matches.dropFirst(start).prefix(size)), total: matches.count,
                               page: current, pageCount: count, startOffset: start)
    }

    static func decks(in cards: [SavedCardDraft]) -> [String] {
        Set(cards.map { $0.card.deck }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct EditorDraftPage {
    let items: [EditorDraftItem]
    let total: Int
    let page: Int
    let pageCount: Int
    let startOffset: Int

    var rangeText: String {
        total == 0 ? "共 0 份草稿" : "第 \(startOffset + 1)–\(startOffset + items.count) 份，共 \(total) 份"
    }
}

enum EditorDraftItem: Identifiable {
    case highlight(SavedHighlightDraft)
    case card(SavedCardDraft)

    var id: String {
        switch self {
        case .highlight(let draft): return "highlight:" + draft.id.uuidString
        case .card(let draft): return "card:" + draft.id.uuidString
        }
    }
    var draftID: UUID {
        switch self {
        case .highlight(let draft): return draft.id
        case .card(let draft): return draft.id
        }
    }
    var savedAt: Date {
        switch self {
        case .highlight(let draft): return draft.savedAt
        case .card(let draft): return draft.savedAt
        }
    }
    var title: String {
        let raw: String
        switch self {
        case .highlight(let draft): raw = draft.title
        case .card(let draft): raw = draft.title
        }
        let plain = Markdown.plainText(fromHTML: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? raw : plain
    }
    var subtitle: String {
        switch self {
        case .highlight: return "摘录"
        case .card(let draft): return "记忆卡 · " + draft.card.deck
        }
    }
    var searchableText: String {
        let parts: [String]
        switch self {
        case .highlight(let draft):
            parts = [draft.highlight.text, draft.highlight.translation ?? "", draft.highlight.note ?? "",
                     draft.tagsText, draft.highlight.tags.joined(separator: " "), draft.newSourceTitle,
                     draft.newSourceAuthor, draft.newSourceURL, draft.highlight.location ?? ""]
        case .card(let draft):
            parts = [draft.card.front, draft.card.back, draft.tagsText, draft.card.tags.joined(separator: " "),
                     draft.card.deck, draft.card.noteType ?? ""] + draft.card.fields
                + (draft.card.sections ?? []).flatMap { [$0.name, $0.text] }
        }
        let raw = parts.joined(separator: "\n")
        return raw + "\n" + Markdown.plainText(fromHTML: raw)
    }

    /// A preview is intentionally frozen. The same UUID with newer contents must be previewed again.
    func matches(_ other: EditorDraftItem) -> Bool {
        guard id == other.id else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch (self, other) {
        case (.highlight(let lhs), .highlight(let rhs)):
            guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
            return left == right
        case (.card(let lhs), .card(let rhs)):
            guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
            return left == right
        default: return false
        }
    }

    func current(in highlights: [SavedHighlightDraft], cards: [SavedCardDraft]) -> EditorDraftItem? {
        switch self {
        case .highlight: return highlights.first { $0.id == draftID }.map(EditorDraftItem.highlight)
        case .card: return cards.first { $0.id == draftID }.map(EditorDraftItem.card)
        }
    }
}
