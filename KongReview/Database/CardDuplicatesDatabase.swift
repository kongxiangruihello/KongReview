import Foundation
import CryptoKit
import GRDB
import KongReviewCore

/// 签名只描述内容；牌组、标签和学习进度留给用户比较后选择。
/// 多字段模板名和字段内容采用精确比较，避免仅正反面缓存相同就误删不同笔记。
struct CardDuplicateSignature: Codable, Hashable, Sendable {
    struct Section: Codable, Hashable, Sendable {
        var name: String
        var text: String
    }
    var front: String
    var back: String
    var sections: [Section]
    var noteType: String?
    var fields: [String]

    init(_ card: Card) {
        front = Self.normalized(card.front)
        back = Self.normalized(card.back)
        sections = (card.sections ?? []).map {
            Section(name: Self.normalized($0.name), text: Self.normalized($0.text))
        }.filter { !$0.name.isEmpty || !$0.text.isEmpty }
        noteType = card.noteType
        fields = card.fields
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    var stableID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 这里只含可编码的字符串和数组，不存在不支持的浮点值。
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CardDuplicateGroup: Identifiable, Sendable, Codable {
    var signature: CardDuplicateSignature
    /// 保存完整扫描快照；确认前连学习进度也要重读校验。
    var cards: [Card]
    /// nil 为原有完全重复组；相似组永远是两张卡，仅作为人工比较建议。
    var similarityScore: Double?
    var id: String {
        similarityScore == nil ? signature.stableID : "similar:" + ids.sorted().map(String.init).joined(separator: ":")
    }
    var ids: [Int64] { cards.compactMap(\.id) }
}

enum CardDuplicateCleanupError: LocalizedError, Equatable {
    case invalidKeeper
    case staleScan

    var errorDescription: String? {
        switch self {
        case .invalidKeeper: return "请先选择本组中要保留的记忆卡。"
        case .staleScan: return "这组卡片在扫描后已更新或删除，尚未进行整理。请重新扫描后再比较。"
        }
    }
}

extension AppDatabase {
    /// 全库查重独立于浏览列表分页；查询和分组在后台任务中调用。
    func cardDuplicateGroups(deck: String? = nil) async throws -> [CardDuplicateGroup] {
        let cards = try await writer.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM card WHERE deletedAt IS NULL"
                              + (deck == nil ? "" : " AND deck = ?") + " ORDER BY id",
                              arguments: deck.map { StatementArguments([$0]) } ?? StatementArguments())
        }
        return Dictionary(grouping: cards, by: CardDuplicateSignature.init)
            .filter { $0.value.count > 1 }
            .map { CardDuplicateGroup(signature: $0.key, cards: $0.value) }
            .sorted { ($0.ids.min() ?? 0) < ($1.ids.min() ?? 0) }
    }

    /// 一次事务验证并整理：保留卡完全不写，其余软删除；历史作答记录继续保留。
    /// 完整快照校验阻止过期扫描覆盖刚发生的编辑、复习、标签或牌组调整。
    func resolveCardDuplicateGroup(_ group: CardDuplicateGroup, keeperID: Int64,
                                   now: Date = Date()) throws -> UndoSnapshot {
        try writer.write { db in
            let ids = group.ids
            guard ids.count > 1, Set(ids).count == ids.count, ids.contains(keeperID) else {
                throw CardDuplicateCleanupError.invalidKeeper
            }
            let current = try Card.fetchAll(db, keys: ids)
            let original = Dictionary(uniqueKeysWithValues: group.cards.compactMap { card in
                card.id.map { ($0, card) }
            })
            guard current.count == ids.count,
                  current.allSatisfy({ card in
                      card.deletedAt == nil && card == original[card.id ?? -1]
                          && (group.similarityScore != nil || CardDuplicateSignature(card) == group.signature)
                  }) else {
                throw CardDuplicateCleanupError.staleScan
            }
            if group.similarityScore != nil {
                guard current.count == 2, CardSimilarity.score(current[0], current[1]) != nil else {
                    throw CardDuplicateCleanupError.staleScan
                }
            }
            let removed = current.filter { $0.id != keeperID }
            let removedIDs = removed.compactMap(\.id)
            try db.execute(sql: "UPDATE card SET deletedAt = ?, updatedAt = ? WHERE id IN ("
                           + removedIDs.map { _ in "?" }.joined(separator: ",") + ")",
                           arguments: StatementArguments([now, now] + removedIDs.map { $0 as any DatabaseValueConvertible }))
            return UndoSnapshot(highlightIds: [], sourceIds: [], cardIds: removedIDs, cards: removed)
        }
    }
}

/// 将备份与数据库操作的先后约束做成可注入的小接口，测试使用临时库与假备份。
enum CardDuplicateCleanup {
    static func resolve(db: AppDatabase, group: CardDuplicateGroup, keeperID: Int64,
                        backupRequired: Bool, backup: () throws -> Void) throws -> UndoSnapshot {
        if backupRequired { try backup() }
        return try db.resolveCardDuplicateGroup(group, keeperID: keeperID)
    }
}
