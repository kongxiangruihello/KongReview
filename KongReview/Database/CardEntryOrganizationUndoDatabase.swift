import Foundation
import GRDB
import KongReviewCore

/// A receipt for one committed organization operation. Versions are scoped to the
/// deck or individual tags it changed, so unrelated edits do not block reversal.
struct CardEntryOrganizationUndoToken: Sendable {
    struct Change: Sendable {
        let before: Card
        let after: Card
        let identityVersion: String
        let deckVersion: String?
        let tagVersions: [String: String]
    }
    let id: UUID
    let changes: [Change]
    let message: String
    var cardIDs: [Int64] { changes.compactMap { $0.after.id } }

    var legacyTagSnapshot: UndoSnapshot {
        var deltas: [Int64: CardTagUndoChange] = [:]
        for item in changes {
            let before = Set(item.before.tags), after = Set(item.after.tags)
            deltas[item.after.id!] = .init(adding:item.before.tags.filter { !after.contains($0) },
                                         removing:item.after.tags.filter { !before.contains($0) })
        }
        return .init(highlightIds:[],sourceIds:[],cardIds:cardIDs,cards:changes.map(\.before),
                     cardTagsOnly:true,cardTagUndoChanges:deltas)
    }
}

enum CardEntryOrganizationUndoError: LocalizedError, Equatable {
    case expired, unavailable, organizationChanged, backupBusy, cardBeingEdited
    var errorDescription: String? {
        switch self {
        case .expired: "这次整理已撤销，或已有更新的批量整理操作，无法再次撤销。"
        case .unavailable: "涉及的卡片已删除、恢复或替换，未执行撤销；不会重新创建卡片。"
        case .organizationChanged: "本次修改的牌组或标签后来又有变化，未执行撤销。其他卡片也保持原样。"
        case .backupBusy: "完整备份操作进行中，请完成后再撤销整理。"
        case .cardBeingEdited: "涉及的卡片正在编辑，请先保存或关闭编辑器，再撤销整理。当前输入仍保留。"
        }
    }
}

extension AppDatabase {
    private static let latestEntryOrganizationUndoKey = "card-entry-organization-undo.latest"

    /// SQL triggers observe every writer, including ordinary edits, native undo,
    /// deck renames and trash restoration. Comparing values alone misses ABA edits.
    static func installCardEntryOrganizationUndoTracking(in db: Database) throws {
        try db.execute(sql:"""
            CREATE TABLE card_entry_organization_revision (
                cardId INTEGER NOT NULL REFERENCES card(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                version TEXT NOT NULL,
                PRIMARY KEY (cardId, kind, name)
            );
            INSERT INTO card_entry_organization_revision(cardId,kind,name,version)
                SELECT id,'identity','',lower(hex(randomblob(16))) FROM card;
            CREATE TRIGGER card_entry_organization_ai AFTER INSERT ON card BEGIN
                INSERT OR REPLACE INTO card_entry_organization_revision(cardId,kind,name,version)
                    VALUES(NEW.id,'identity','',lower(hex(randomblob(16))));
            END;
            CREATE TRIGGER card_entry_organization_ad AFTER DELETE ON card BEGIN
                DELETE FROM card_entry_organization_revision WHERE cardId=OLD.id;
            END;
            CREATE TRIGGER card_entry_organization_deleted AFTER UPDATE OF deletedAt ON card
                WHEN OLD.deletedAt IS NOT NEW.deletedAt BEGIN
                INSERT OR REPLACE INTO card_entry_organization_revision(cardId,kind,name,version)
                    VALUES(NEW.id,'identity','',lower(hex(randomblob(16))));
            END;
            CREATE TRIGGER card_entry_organization_deck AFTER UPDATE OF deck ON card
                WHEN OLD.deck IS NOT NEW.deck BEGIN
                INSERT OR REPLACE INTO card_entry_organization_revision(cardId,kind,name,version)
                    VALUES(NEW.id,'deck','',lower(hex(randomblob(16))));
            END;
            CREATE TRIGGER card_entry_organization_tags AFTER UPDATE OF tags ON card
                WHEN OLD.tags IS NOT NEW.tags BEGIN
                INSERT OR REPLACE INTO card_entry_organization_revision(cardId,kind,name,version)
                    SELECT NEW.id,'tag',CAST(value AS TEXT),lower(hex(randomblob(16)))
                    FROM (
                        SELECT value FROM json_each(OLD.tags)
                            WHERE value NOT IN (SELECT value FROM json_each(NEW.tags))
                        UNION
                        SELECT value FROM json_each(NEW.tags)
                            WHERE value NOT IN (SELECT value FROM json_each(OLD.tags))
                    );
            END;
            """)
    }

    private static func entryOrganizationVersion(cardID: Int64, kind: String, name: String = "", in db: Database) throws -> String? {
        try String.fetchOne(db,sql:"SELECT version FROM card_entry_organization_revision WHERE cardId=? AND kind=? AND name=?",
                            arguments:[cardID,kind,name])
    }

    /// Reads latest rows, commits the whole selection, and records one replacement
    /// receipt in the same transaction. The caller supplies its authorized list.
    func changeCardEntryOrganizationRecordingUndo(ids: [Int64], allowedIDs: [Int64], change: CardEntryBatchChange,
                                                  historyQuery: CardEntryHistoryQuery? = nil) throws -> CardEntryOrganizationUndoToken? {
        let selected = Set(ids)
        guard !selected.isEmpty,selected.isSubset(of:Set(allowedIDs)) else { throw CardEntryBatchError.stale }
        return try writer.write { db in
            if let historyQuery { try Self.validateCardEntryHistorySelection(ids,query:historyQuery,in:db) }
            let cards = try Card.fetchAll(db,keys:Array(selected).sorted())
            guard cards.count == selected.count,cards.allSatisfy({ $0.deletedAt == nil }) else { throw CardEntryBatchError.stale }
            var changes: [CardEntryOrganizationUndoToken.Change] = []
            let now = Date()
            for before in cards {
                var next = before
                let columns: [String]
                switch change {
                case .move(let value):
                    let deck = value.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !deck.isEmpty else { throw CardEntryBatchError.emptyDeck }
                    guard deck != before.deck else { continue }
                    next.deck = deck;columns = ["deck","updatedAt"]
                case .tags(let values,let mode):
                    let tags = TagParser.parse(values.joined(separator:" "))
                    guard !tags.isEmpty else { throw CardEntryBatchError.emptyTags }
                    switch mode {
                    case .add:
                        var seen = Set(next.tags)
                        next.tags += tags.filter { seen.insert($0).inserted }
                    case .remove:
                        let removed = Set(tags);next.tags.removeAll { removed.contains($0) }
                    }
                    guard next.tags != before.tags else { continue }
                    columns = ["tags","updatedAt"]
                }
                next.updatedAt = now;try next.update(db,columns:columns)
                guard let after = try Card.fetchOne(db,key:before.id!),
                      let identity = try Self.entryOrganizationVersion(cardID:before.id!,kind:"identity",in:db) else {
                    throw CardEntryBatchError.stale
                }
                let deckVersion: String?
                var tagVersions: [String:String] = [:]
                switch change {
                case .move:
                    guard let version = try Self.entryOrganizationVersion(cardID:before.id!,kind:"deck",in:db) else { throw CardEntryBatchError.stale }
                    deckVersion = version
                case .tags:
                    deckVersion = nil
                    for tag in Set(before.tags).symmetricDifference(Set(after.tags)) {
                        guard let version = try Self.entryOrganizationVersion(cardID:before.id!,kind:"tag",name:tag,in:db) else { throw CardEntryBatchError.stale }
                        tagVersions[tag] = version
                    }
                }
                changes.append(.init(before:before,after:after,identityVersion:identity,deckVersion:deckVersion,tagVersions:tagVersions))
            }
            // Even a successful no-op supersedes the previous organization action.
            guard !changes.isEmpty else {
                try db.execute(sql:"DELETE FROM app_progress WHERE key=?",arguments:[Self.latestEntryOrganizationUndoKey])
                return nil
            }
            let message: String
            switch change {
            case .move(let deck): message = "已将 \(changes.count) 张卡片移动到「\(deck.trimmingCharacters(in:.whitespacesAndNewlines))」。"
            case .tags(_,let mode): message = "已为 \(changes.count) 张卡片\(mode == .add ? "添加" : "移除")标签。"
            }
            let token = CardEntryOrganizationUndoToken(id:UUID(),changes:changes,message:message)
            try Self.putProgress(token.id,key:Self.latestEntryOrganizationUndoKey,in:db)
            return token
        }
    }

    /// Validate every touched field before writing any row. Restore just that
    /// field/tag delta into the latest row, retaining subsequent content and scores.
    @discardableResult
    func undoCardEntryOrganization(_ token: CardEntryOrganizationUndoToken) throws -> [Card] {
        try writer.write { db in
            guard try Self.readProgress(UUID.self,key:Self.latestEntryOrganizationUndoKey,in:db) == token.id else {
                throw CardEntryOrganizationUndoError.expired
            }
            var plans: [(Card,[String])] = []
            for item in token.changes {
                guard let id = item.after.id,let current = try Card.fetchOne(db,key:id),current.deletedAt == nil,
                      try Self.entryOrganizationVersion(cardID:id,kind:"identity",in:db) == item.identityVersion else {
                    throw CardEntryOrganizationUndoError.unavailable
                }
                var restored = current
                let columns: [String]
                if let deckVersion = item.deckVersion {
                    guard current.deck == item.after.deck,
                          try Self.entryOrganizationVersion(cardID:id,kind:"deck",in:db) == deckVersion else {
                        throw CardEntryOrganizationUndoError.organizationChanged
                    }
                    restored.deck = item.before.deck;columns = ["deck","updatedAt"]
                } else {
                    let currentTags = Set(current.tags),afterTags = Set(item.after.tags)
                    for (tag,version) in item.tagVersions {
                        guard currentTags.contains(tag) == afterTags.contains(tag),
                              try Self.entryOrganizationVersion(cardID:id,kind:"tag",name:tag,in:db) == version else {
                            throw CardEntryOrganizationUndoError.organizationChanged
                        }
                    }
                    let beforeTags = Set(item.before.tags)
                    let added = afterTags.subtracting(beforeTags),removed = beforeTags.subtracting(afterTags)
                    restored.tags.removeAll { added.contains($0) }
                    // Reinsert removed tags beside their surviving original neighbors.
                    for (index,tag) in item.before.tags.enumerated() where removed.contains(tag) {
                        if let anchor = item.before.tags.dropFirst(index + 1).first(where:{ restored.tags.contains($0) }),
                           let position = restored.tags.firstIndex(of:anchor) { restored.tags.insert(tag,at:position) }
                        else if let anchor = item.before.tags.prefix(index).reversed().first(where:{ restored.tags.contains($0) }),
                                let position = restored.tags.firstIndex(of:anchor) { restored.tags.insert(tag,at:position + 1) }
                        else { restored.tags.insert(tag,at:0) }
                    }
                    columns = ["tags","updatedAt"]
                }
                restored.updatedAt = Date();plans.append((restored,columns))
            }
            for (restored,columns) in plans { try restored.update(db,columns:columns) }
            let saved = try plans.map { try Card.fetchOne(db,key:$0.0.id!)! }
            try db.execute(sql:"DELETE FROM app_progress WHERE key=?",arguments:[Self.latestEntryOrganizationUndoKey])
            return saved
        }
    }
}
