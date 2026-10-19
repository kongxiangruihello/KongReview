import Foundation

/// Review results are deliberately absent: every restored batch is checked against current cards.
/// The complete preset is frozen so a later preset edit cannot silently reassign pasted columns.
struct CardBulkEntryDraft: Codable, Equatable, Sendable {
    var id = UUID()
    var source = ""
    var format = CardBulkEntryFormat.tabSeparated
    var firstRowIsHeader = false
    var headers: [String] = []
    var configuration = CardBulkEntryConfiguration()
    var candidates: [CardBulkEntryCandidate] = []
    var selectedIDs = Set<UUID>()
    var page = 1
    var editingCandidate: CardBulkEntryCandidate?

    var hasInput: Bool { !source.isEmpty || !candidates.isEmpty || editingCandidate != nil }

    /// New optional editor state is tolerant of drafts from the first schema revision.
    private enum CodingKeys: String, CodingKey {
        case id, source, format, firstRowIsHeader, headers, configuration, candidates, selectedIDs, page, editingCandidate
    }
    init() { }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self,forKey:.id) ?? UUID()
        source = try values.decodeIfPresent(String.self,forKey:.source) ?? ""
        format = try values.decodeIfPresent(CardBulkEntryFormat.self,forKey:.format) ?? .tabSeparated
        firstRowIsHeader = try values.decodeIfPresent(Bool.self,forKey:.firstRowIsHeader) ?? false
        headers = try values.decodeIfPresent([String].self,forKey:.headers) ?? []
        configuration = try values.decodeIfPresent(CardBulkEntryConfiguration.self,forKey:.configuration) ?? .init()
        candidates = try values.decodeIfPresent([CardBulkEntryCandidate].self,forKey:.candidates) ?? []
        selectedIDs = try values.decodeIfPresent(Set<UUID>.self,forKey:.selectedIDs) ?? Set(candidates.map(\.id))
        page = max(1,try values.decodeIfPresent(Int.self,forKey:.page) ?? 1)
        editingCandidate = try values.decodeIfPresent(CardBulkEntryCandidate.self,forKey:.editingCandidate)
        let ids = Set(candidates.map(\.id))
        guard ids.count == candidates.count, selectedIDs.isSubset(of:ids), candidates.allSatisfy({ $0.line > 0 }),
              editingCandidate == nil || ids.contains(editingCandidate!.id) else {
            throw CardBulkEntryError.changedSelection
        }
    }
}
