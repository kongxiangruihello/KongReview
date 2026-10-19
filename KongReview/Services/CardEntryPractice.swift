import Foundation
import GRDB
import KongReviewCore

enum CardEntryPracticeError: LocalizedError, Equatable {
    case selectionChanged, materialsChanged, libraryChanged
    var errorDescription: String? {
        switch self {
        case .selectionChanged: return "所选卡片已不在当前页或当前筛选范围内，请刷新后重新选择。"
        case .materialsChanged: return "练习中的卡片或显示模板已发生变化，请关闭练习后重新开始。"
        case .libraryChanged: return "资料已重新载入或正在备份，请关闭本次练习。"
        }
    }
}

/// A fixed read-only set of cards plus disposable responses. None of these methods
/// save a Card, create ReviewEvent, or call the normal study scheduler.
struct CardEntryPracticeSession: Identifiable, Sendable {
    let id: UUID
    let generation: UUID
    let query: CardEntryHistoryQuery
    let cards: [Card]
    let templates: [String:NoteTemplate]
    private(set) var position = 0
    private(set) var responses: [Int64:CardSelfAnswerDraft] = [:]
    private(set) var revealed = Set<Int64>()
    private(set) var isFinished = false

    init(generation: UUID, query: CardEntryHistoryQuery, cards: [Card], templates: [String:NoteTemplate]) {
        id = UUID();self.generation = generation;self.query = query;self.cards = cards;self.templates = templates
    }
    var current: Card? { cards.indices.contains(position) ? cards[position] : nil }
    var showingAnswer: Bool { current?.id.map { revealed.contains($0) } ?? false }
    var currentResponse: CardSelfAnswerDraft { current?.id.flatMap { responses[$0] } ?? .init() }
    var answeredCount: Int { responses.values.filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.count }
    var assessedCount: Int { responses.values.filter { $0.assessment != nil }.count }

    mutating func setResponse(_ response: CardSelfAnswerDraft) {
        guard let id = current?.id,!isFinished else { return }
        var response = response
        if !showingAnswer { response.assessment = nil }
        responses[id] = response
    }
    mutating func revealAnswer() { if let id = current?.id,!isFinished { revealed.insert(id) } }
    mutating func previous() { guard position > 0 else { return };position -= 1;isFinished = false }
    mutating func next() {
        guard !cards.isEmpty else { return }
        if position + 1 < cards.count { position += 1 }
        else { isFinished = true }
    }
    mutating func revisit() { position = 0;isFinished = false }
}

extension AppDatabase {
    /// A single read transaction rechecks the actual page/query and captures the
    /// latest active records and rendering templates, rather than stale list rows.
    func cardEntryPracticeSession(ids: [Int64], allowedIDs: [Int64], query: CardEntryHistoryQuery,
                                  page: Int, generation: UUID) throws -> CardEntryPracticeSession {
        try writer.read { sql in
            let selected = Set(ids)
            guard !selected.isEmpty,selected.count == ids.count,selected.isSubset(of:Set(allowedIDs)) else { throw CardEntryPracticeError.selectionChanged }
            let latest = try Self.cardEntryHistoryPage(query:query,page:page,in:sql)
            guard latest.page == page,selected.isSubset(of:Set(latest.items.map(\.id))) else { throw CardEntryPracticeError.selectionChanged }
            let cards = latest.items.filter { selected.contains($0.id) }.map(\.card)
            let names = Set(cards.compactMap(\.noteType))
            let templates = Dictionary(uniqueKeysWithValues:try NoteTemplate.fetchAll(sql).filter { names.contains($0.name) }.map { ($0.name,$0) })
            return .init(generation:generation,query:query,cards:cards,templates:templates)
        }
    }

    /// Validate every selected card, including cards not reached yet. Any library
    /// mutation requires starting a fresh snapshot, so deleted/retargeted content
    /// cannot be silently used as another card's answer.
    func validateCardEntryPractice(_ session: CardEntryPracticeSession) throws {
        try writer.read { sql in
            let ids = session.cards.compactMap(\.id)
            guard !ids.isEmpty,ids.count == session.cards.count else { throw CardEntryPracticeError.materialsChanged }
            do { try Self.validateCardEntryHistorySelection(ids,query:session.query,in:sql) }
            catch { throw CardEntryPracticeError.materialsChanged }
            for card in session.cards {
                guard let latest = try Card.fetchOne(sql,key:card.id!),latest == card else { throw CardEntryPracticeError.materialsChanged }
            }
            let names = Set(session.cards.compactMap(\.noteType))
            let templates = Dictionary(uniqueKeysWithValues:try NoteTemplate.fetchAll(sql).filter { names.contains($0.name) }.map { ($0.name,$0) })
            guard templates == session.templates else { throw CardEntryPracticeError.materialsChanged }
        }
    }
}

extension LibraryStore {
    func validateCardEntryPractice(_ session: CardEntryPracticeSession) throws {
        guard !fullBackupBusy,cardEntryHistory.generation == session.generation else { throw CardEntryPracticeError.libraryChanged }
        try db.validateCardEntryPractice(session)
    }
}
