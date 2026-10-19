import Foundation
import GRDB
import KongReviewCore

struct CardEntryHistoryQuery: Equatable, Sendable {
    var date: Date? = Date()
    /// Inclusive local end date. Nil preserves the original single-day filter.
    var endDate: Date? = nil
    var text = ""
    var deck = ""
    var calendar = Calendar.current
}

struct CardEntryHistoryItem: Identifiable, Sendable {
    var card: Card
    var recordedAt: Date
    var id: Int64 { card.id! }
}

struct CardEntryHistoryPage: Sendable {
    var items: [CardEntryHistoryItem]
    var total: Int
    var page: Int
    var pageCount: Int
    static let size = 50
}

extension AppDatabase {
    /// Call in the same transaction as a newly entered card. Updating or restoring a card
    /// never creates another entry record; imported cards retain their separate import flow.
    static func recordCardEntry(_ card: Card, at date: Date = Date(), in sql: Database) throws {
        guard let id = card.id else { return }
        try sql.execute(sql:"INSERT OR IGNORE INTO card_entry_record(cardId,recordedAt) VALUES (?,?)",arguments:[id,date])
    }

    private static func entryHistoryFilter(_ query: CardEntryHistoryQuery) -> (String, StatementArguments) {
        var filter = "c.deletedAt IS NULL"
        var values: [(any DatabaseValueConvertible)?] = []
        if let date = query.date {
            let start = query.calendar.startOfDay(for:date)
            let last = query.calendar.startOfDay(for:max(date,query.endDate ?? date))
            let end = query.calendar.date(byAdding:.day,value:1,to:last)!
            filter += " AND e.recordedAt >= ? AND e.recordedAt < ?"
            values += [start,end]
        }
        if !query.deck.isEmpty { filter += " AND c.deck = ?";values.append(query.deck) }
        let words = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in words {
            let pattern = SearchQuery.likePattern(ChineseFold.fold(word))
            filter += " AND (kr_fold(c.front) LIKE ? ESCAPE '\\' OR kr_fold(c.back) LIKE ? ESCAPE '\\' OR kr_fold(coalesce(c.sections,'')) LIKE ? ESCAPE '\\' OR kr_fold(c.deck) LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM json_each(c.tags) WHERE kr_fold(value) LIKE ? ESCAPE '\\'))"
            values += Array(repeating:pattern,count:5)
        }
        return (filter,StatementArguments(values))
    }

    func cardEntryHistoryPage(query: CardEntryHistoryQuery, page: Int) throws -> CardEntryHistoryPage {
        try writer.read { try Self.cardEntryHistoryPage(query:query,page:page,in:$0) }
    }

    static func cardEntryHistoryPage(query: CardEntryHistoryQuery, page: Int, in sql: Database) throws -> CardEntryHistoryPage {
        let (filter,args) = Self.entryHistoryFilter(query)
        let from = " FROM card_entry_record e JOIN card c ON c.id=e.cardId WHERE " + filter
        let total = try Int.fetchOne(sql,sql:"SELECT COUNT(*)" + from,arguments:args) ?? 0
        let pages = max(1,(total + CardEntryHistoryPage.size - 1) / CardEntryHistoryPage.size)
        let current = min(max(1,page),pages)
        let rows = try Row.fetchAll(sql,sql:"SELECT c.*, e.recordedAt AS entryRecordedAt" + from + " ORDER BY e.recordedAt DESC,c.id DESC LIMIT ? OFFSET ?",arguments:args + [CardEntryHistoryPage.size,(current - 1) * CardEntryHistoryPage.size])
        let items = try rows.map { CardEntryHistoryItem(card:try Card(row:$0),recordedAt:$0["entryRecordedAt"]) }
        return .init(items:items,total:total,page:current,pageCount:pages)
    }

    func validateCardEntryHistorySelection(_ ids: [Int64], query: CardEntryHistoryQuery) throws {
        try writer.read { try Self.validateCardEntryHistorySelection(ids,query:query,in:$0) }
    }

    static func validateCardEntryHistorySelection(_ ids: [Int64], query: CardEntryHistoryQuery, in sql: Database) throws {
        guard !ids.isEmpty else { throw CardEntryBatchError.stale }
        let (filter,args) = Self.entryHistoryFilter(query)
        let json = String(decoding:try JSONEncoder().encode(Array(Set(ids))),as:UTF8.self)
        let count = try Int.fetchOne(sql,sql:"SELECT COUNT(*) FROM card_entry_record e JOIN card c ON c.id=e.cardId WHERE " + filter + " AND c.id IN (SELECT value FROM json_each(?))",arguments:args + [json]) ?? 0
        guard count == Set(ids).count else { throw CardEntryBatchError.stale }
    }
}
