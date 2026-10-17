import Foundation
import GRDB
import KongReviewCore

enum CardBrowseStateFilter: String, CaseIterable, Codable, Sendable {
    case all, new, learning, review, suspended

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .new: return "新卡"
        case .learning: return "学习中"
        case .review: return "复习卡"
        case .suspended: return "已暂停"
        }
    }
}

enum CardTagBatchMode: String, Sendable {
    case add, remove
    var title: String { self == .add ? "批量添加标签" : "批量移除标签" }
}

struct CardTagEditRequest: Identifiable, Sendable {
    let id = UUID()
    var cardIDs: [Int64]
    var deck: String
    var mode: CardTagBatchMode
    var text = ""
    var processing = false
    var error: String?
}

enum CardTagBatchError: LocalizedError {
    case emptyTags, staleSelection
    var errorDescription: String? {
        switch self {
        case .emptyTags: return "请输入至少一个标签。"
        case .staleSelection: return "选中的卡片已移动或删除，请返回列表重新选择。"
        }
    }
}

extension AppDatabase {
    func cardTagOptions(deck: String) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT CAST(j.value AS TEXT) FROM card, json_each(card.tags) j
                WHERE card.deletedAt IS NULL AND card.deck = ? AND trim(CAST(j.value AS TEXT)) != ''
                ORDER BY CAST(j.value AS TEXT) COLLATE NOCASE
                """, arguments: [deck])
        }
    }

    static func parsedCardTags(_ text: String) -> [String] {
        let pieces = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
        var seen: Set<String> = []
        return pieces.map { String($0.drop(while: { $0 == "#" })) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 当前数据库值上增删标签；不回写浏览快照，保留排程、牌组和所有不相关标签。
    /// 改动和撤销快照来自同一事务，任一选中项被移走/删除则全部停止。
    func updateCardTags(ids: [Int64], deck: String, tags: [String], mode: CardTagBatchMode,
                        now: Date = Date()) throws -> UndoSnapshot {
        guard !tags.isEmpty else { throw CardTagBatchError.emptyTags }
        let uniqueIDs = Array(Set(ids)).sorted()
        return try writer.write { db in
            let cards = try Card.fetchAll(db, keys: uniqueIDs)
            guard !uniqueIDs.isEmpty, cards.count == uniqueIDs.count,
                  cards.allSatisfy({ $0.deletedAt == nil && $0.deck == deck }) else {
                throw CardTagBatchError.staleSelection
            }
            var changed: [Card] = []
            var undoChanges: [Int64: CardTagUndoChange] = [:]
            let removed = Set(tags)
            for card in cards {
                var updated = card
                switch mode {
                case .add:
                    var seen = Set(card.tags)
                    updated.tags += tags.filter { seen.insert($0).inserted }
                case .remove:
                    updated.tags.removeAll { removed.contains($0) }
                }
                guard updated.tags != card.tags else { continue }
                changed.append(card)
                if let id = card.id {
                    let before = Set(card.tags), after = Set(updated.tags)
                    undoChanges[id] = CardTagUndoChange(adding: card.tags.filter { !after.contains($0) },
                                                       removing: updated.tags.filter { !before.contains($0) })
                }
                updated.updatedAt = now
                try updated.update(db, columns: ["tags", "updatedAt"])
            }
            return UndoSnapshot(highlightIds: [], sourceIds: [], cardIds: changed.compactMap(\.id), cards: changed,
                                cardTagsOnly: true, cardTagUndoChanges: undoChanges)
        }
    }
}
