import Foundation
import GRDB

extension AppDatabase {
    static let cardBulkEntryDraftProgressKey = "cards.bulk-entry-draft.v1"
    static func cardBulkEntryClosedKey(_ id: UUID) -> String { "cards.bulk-entry-closed.v1." + id.uuidString }

    func cardBulkEntryDraft() throws -> CardBulkEntryDraft? {
        try writer.read { try Self.cardBulkEntryDraft(in:$0) }
    }

    /// Exact-value compare-and-swap prevents an old window or delayed autosave from replacing newer input.
    func saveCardBulkEntryDraft(_ value: CardBulkEntryDraft, expected: CardBulkEntryDraft?) throws {
        try writer.write { sql in
            guard try Self.cardBulkEntryDraft(in:sql) == expected else { throw CardBulkEntryError.draftChanged }
            guard try !Self.cardBulkEntryWasClosed(value.id,in:sql) else { throw CardBulkEntryError.alreadySaved }
            try sql.execute(sql:"INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",
                            arguments:[Self.cardBulkEntryDraftProgressKey,try JSONEncoder().encode(value),Date()])
        }
    }

    func clearCardBulkEntryDraft(expectedID: UUID) throws {
        try writer.write { sql in
            if let current = try Self.cardBulkEntryDraft(in:sql),current.id != expectedID { throw CardBulkEntryError.draftChanged }
            try Self.closeCardBulkEntryDraft(expectedID,in:sql)
        }
    }

    static func cardBulkEntryDraft(in sql: Database) throws -> CardBulkEntryDraft? {
        guard let payload = try Data.fetchOne(sql,sql:"SELECT payload FROM app_progress WHERE key=?",arguments:[cardBulkEntryDraftProgressKey]) else { return nil }
        return try JSONDecoder().decode(CardBulkEntryDraft.self,from:payload)
    }
    static func cardBulkEntryWasClosed(_ id: UUID,in sql: Database) throws -> Bool {
        try Bool.fetchOne(sql,sql:"SELECT EXISTS(SELECT 1 FROM app_progress WHERE key=?)",arguments:[cardBulkEntryClosedKey(id)]) ?? false
    }
    static func closeCardBulkEntryDraft(_ id: UUID,in sql: Database) throws {
        try sql.execute(sql:"INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO NOTHING",
                        arguments:[cardBulkEntryClosedKey(id),Data("{}".utf8),Date()])
        if try cardBulkEntryDraft(in:sql)?.id == id {
            try sql.execute(sql:"DELETE FROM app_progress WHERE key=?",arguments:[cardBulkEntryDraftProgressKey])
        }
    }
}
