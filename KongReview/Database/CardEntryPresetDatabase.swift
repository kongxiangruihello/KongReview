import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    static let cardEntryPresetProgressKey = "cards.entry-presets.v1"

    func cardEntryPresetLibrary() throws -> CardEntryPresetLibrary {
        try writer.read { try Self.cardEntryPresetLibrary(in: $0) }
    }

    /// expected is supplied by the manager when updating, to reject stale edits.
    func saveCardEntryPreset(_ preset: CardEntryPreset, expected: CardEntryPreset? = nil) throws {
        try writer.write { db in
            var library = try Self.cardEntryPresetLibrary(in: db)
            if let expected, library.presets.first(where: { $0.id == preset.id }) != expected {
                throw CardEntryPresetError.changedPreset
            }
            let value = preset.cleaned
            let templates = Dictionary(uniqueKeysWithValues: try NoteTemplate.fetchAll(db).map { ($0.name, $0) })
            try value.validate(templates: templates)
            guard !library.presets.contains(where: { $0.id != value.id && $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) else {
                throw CardEntryPresetError.duplicateName
            }
            library.presets.removeAll { $0.id == value.id }
            library.presets.append(value)
            library.presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try Self.saveCardEntryPresetLibrary(library, in: db)
        }
    }

    func deleteCardEntryPreset(id: UUID) throws {
        try writer.write { db in
            var library = try Self.cardEntryPresetLibrary(in: db)
            library.presets.removeAll { $0.id == id }
            library.deckPresetIDs = library.deckPresetIDs.filter { $0.value != id }
            try Self.saveCardEntryPresetLibrary(library, in: db)
        }
    }

    /// Always adds independent copies. A failed item rolls back the entire selection.
    @discardableResult
    func importCardEntryPresets(_ presets: [CardEntryPreset]) throws -> [CardEntryPreset] {
        try writer.write { db in
            guard !presets.isEmpty, presets.count <= CardEntryPresetTransfer.maximumPresetCount else {
                throw CardEntryPresetTransferError.invalidCount
            }
            var library = try Self.cardEntryPresetLibrary(in: db)
            let templates = Dictionary(uniqueKeysWithValues: try NoteTemplate.fetchAll(db).map { ($0.name, $0) })
            var added: [CardEntryPreset] = []
            for preset in presets {
                let source = preset.cleaned
                try CardEntryPresetTransfer.checkLimits(source)
                try source.validate(templates: templates)
                let value = source.copied()
                guard !(library.presets + added).contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) else {
                    throw CardEntryPresetError.duplicateName
                }
                added.append(value)
            }
            library.presets.append(contentsOf: added)
            library.presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try Self.saveCardEntryPresetLibrary(library, in: db)
            return added
        }
    }

    func setDeckEntryPreset(deck: String, presetID: UUID?) throws {
        try writer.write { db in
            var library = try Self.cardEntryPresetLibrary(in: db)
            let name = deck.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "默认"
            if let presetID {
                guard let preset = library.presets.first(where: { $0.id == presetID }) else { throw CardEntryPresetError.missingPreset }
                let templates = Dictionary(uniqueKeysWithValues: try NoteTemplate.fetchAll(db).map { ($0.name, $0) })
                try preset.validate(templates: templates)
                library.deckPresetIDs[name] = presetID
            } else {
                library.deckPresetIDs[name] = nil
            }
            try Self.saveCardEntryPresetLibrary(library, in: db)
        }
    }

    /// Invoke in the existing renameDeck transaction. A merge retains the destination binding.
    static func renameDeckEntryPresets(_ db: Database, from old: String, to new: String) throws {
        guard old != new else { return }
        var library = try cardEntryPresetLibrary(in: db)
        if library.deckPresetIDs[new] == nil { library.deckPresetIDs[new] = library.deckPresetIDs[old] }
        library.deckPresetIDs[old] = nil
        for i in library.presets.indices where library.presets[i].deck == old { library.presets[i].deck = new }
        try saveCardEntryPresetLibrary(library, in: db)
    }

    private static func cardEntryPresetLibrary(in db: Database) throws -> CardEntryPresetLibrary {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key=?", arguments: [cardEntryPresetProgressKey]) else { return .init() }
        return try JSONDecoder().decode(CardEntryPresetLibrary.self, from: data)
    }

    private static func saveCardEntryPresetLibrary(_ value: CardEntryPresetLibrary, in db: Database) throws {
        try db.execute(sql: "INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",
                       arguments: [cardEntryPresetProgressKey, try JSONEncoder().encode(value), Date()])
    }
}
