import Foundation
import GRDB
import KongReviewCore

/// 只包含不可变值；数据库连接始终留在 GRDB 的读取闭包里。
struct DerivedLibraryRequest: @unchecked Sendable {
    let now: Date
    let dailyReviewCount: Int
    let newPerDay: Int
    let reviewsPerDay: Int
    let scope: CardLearningScope
    let session: ReviewSessionRecordStore.Snapshot?
}

struct DerivedLibrarySnapshot: @unchecked Sendable {
    let stale: AppDatabase.StaleSummary
    let activity: LearningActivitySummary
    let decks: [DeckSummary]
    let globalCards: CardLearningSummary
    let scopedCards: CardLearningSummary
    let home: HomeLearningSummary
}

extension AppDatabase {
    /// 一次读取快照完成整组统计，查询次数不随牌组数量增加。
    /// 卡片只取排程投影，不读取正反面、图片、栏目或多字段正文。
    func derivedLibrarySnapshot(_ request: DerivedLibraryRequest) throws -> DerivedLibrarySnapshot {
        try Task.checkCancellation()
        return try writer.read { db in
            let calendar = Calendar.current
            let context = try CardStatisticsContext(db: db, now: request.now, calendar: calendar)
            try Task.checkCancellation()
            let activity = try Self.fetchLearningActivitySummary(db, now: request.now, days: 30, calendar: calendar)
            let decks = context.deckSummaries(now: request.now, newPerDay: request.newPerDay, reviewsPerDay: request.reviewsPerDay)
            let global = try context.summary(scope: .all, in: db, now: request.now, calendar: calendar,
                                             newPerDay: request.newPerDay, reviewsPerDay: request.reviewsPerDay)
            let scoped = request.scope == .all ? global : try context.summary(
                scope: request.scope, in: db, now: request.now, calendar: calendar,
                newPerDay: request.newPerDay, reviewsPerDay: request.reviewsPerDay)
            try Task.checkCancellation()
            let home = try Self.fetchHomeLearningSummary(db, now: request.now, calendar: calendar,
                dailyReviewCount: request.dailyReviewCount, session: request.session,
                decks: decks, activity: activity, availability: global.availability)
            let cutoff = request.now.addingTimeInterval(-180 * 86_400)
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                    SUM(CASE WHEN surfacedCount = 0 OR lastSurfacedAt IS NULL THEN 1 ELSE 0 END) AS never,
                    SUM(CASE WHEN surfacedCount > 0 AND lastSurfacedAt < ? THEN 1 ELSE 0 END) AS old
                FROM highlight WHERE deletedAt IS NULL AND isDiscarded = 0
                """, arguments: [cutoff])
            var stale = StaleSummary()
            stale.total = row?["total"] ?? 0
            stale.never = row?["never"] ?? 0
            stale.old = row?["old"] ?? 0
            stale.bySource = try Row.fetchAll(db, sql: """
                SELECT sourceId, COUNT(*) AS n FROM highlight
                WHERE deletedAt IS NULL AND isDiscarded = 0 AND (surfacedCount = 0 OR lastSurfacedAt IS NULL)
                GROUP BY sourceId ORDER BY n DESC LIMIT 8
                """).map { ($0["sourceId"], $0["n"]) }
            return .init(stale: stale, activity: activity, decks: decks,
                         globalCards: global, scopedCards: scoped, home: home)
        }
    }
}

private struct CardStatisticsContext {
    struct DayRecord {
        let count: Int
        let correct: Int
        let wasNew: Bool
    }
    /// 这些 Card 是调度投影，只供统计，不能用于显示正文或写回数据库。
    let projections: [Card]
    let byID: [Int64: Card]
    let options: [String: DeckOptions]
    let events: [Int64: DayRecord]
    let spentByDeck: [String: (new: Int, review: Int)]

    init(db: Database, now: Date, calendar: Calendar) throws {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        projections = try Row.fetchAll(db, sql: """
            SELECT id, deck, highlightId, state, due, interval, reps, isSuspended, createdAt, deletedAt
            FROM card WHERE deletedAt IS NULL OR id IN
                (SELECT cardId FROM review_event WHERE kind = 'card' AND at >= ? AND at < ?)
            """, arguments: [start, end]).map { row in
                Card(id: row["id"], deck: row["deck"], front: "", highlightId: row["highlightId"],
                     state: Card.State(rawValue: row["state"]) ?? .new, interval: row["interval"],
                     due: row["due"], reps: row["reps"], isSuspended: row["isSuspended"],
                     createdAt: row["createdAt"], deletedAt: row["deletedAt"])
            }
        byID = Dictionary(uniqueKeysWithValues: projections.compactMap { c in c.id.map { ($0, c) } })
        options = Dictionary(uniqueKeysWithValues: try DeckOptions.fetchAll(db).map { ($0.deck, $0) })
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.cardId, COUNT(*) AS n, SUM(CASE WHEN e.answer > 1 THEN 1 ELSE 0 END) AS correct,
                (SELECT e2.cardState FROM review_event e2 WHERE e2.cardId = e.cardId AND e2.kind = 'card'
                    AND e2.at >= ? AND e2.at < ? ORDER BY e2.at, e2.id LIMIT 1) AS firstState,
                EXISTS (SELECT 1 FROM review_event p WHERE p.cardId = e.cardId AND p.kind = 'card' AND p.at < ?) AS prior
            FROM review_event e WHERE e.kind = 'card' AND e.cardId IS NOT NULL AND e.at >= ? AND e.at < ?
            GROUP BY e.cardId
            """, arguments: [start, end, start, start, end])
        var events: [Int64: DayRecord] = [:]
        var spent: [String: (new: Int, review: Int)] = [:]
        for row in rows {
            let id: Int64 = row["cardId"]
            let count: Int = row["n"]
            let wasNew = AppDatabase.firstAnswerWasNew(state: row["firstState"], prior: row["prior"] ?? false,
                                                       reps: byID[id]?.reps ?? 0, answers: count)
            events[id] = .init(count: count, correct: row["correct"] ?? 0, wasNew: wasNew)
            if let deck = byID[id]?.deck {
                var value = spent[deck] ?? (0, 0)
                if wasNew { value.new += 1 } else { value.review += 1 }
                spent[deck] = value
            }
        }
        self.events = events
        spentByDeck = spent
    }

    func groups(cards: [Card], newPerDay: Int, reviewsPerDay: Int) -> [CardStudyAvailability.Group] {
        Dictionary(grouping: cards, by: \.deck).sorted { $0.key < $1.key }.map { deck, cards in
            let option = options[deck]
            let n = option?.newPerDay ?? newPerDay
            let r = option?.reviewsPerDay ?? reviewsPerDay
            let spent = spentByDeck[deck] ?? (0, 0)
            return .init(cards: cards, newLimit: n, reviewLimit: r,
                         newLimitLeft: n - spent.new, reviewLimitLeft: r - spent.review,
                         studiedCards: spent.new + spent.review)
        }
    }

    func deckSummaries(now: Date, newPerDay: Int, reviewsPerDay: Int) -> [DeckSummary] {
        groups(cards: projections.filter { $0.deletedAt == nil }, newPerDay: newPerDay, reviewsPerDay: reviewsPerDay).map { g in
            DeckSummary(name: g.cards[0].deck, total: g.cards.count,
                        counts: StudyQueue.counts(g.cards, now: now, newLimitLeft: g.newLimitLeft, reviewLimitLeft: g.reviewLimitLeft),
                        maturity: DeckMaturity(g.cards), doneToday: g.studiedCards)
        }
    }

    func summary(scope: CardLearningScope, in db: Database, now: Date, calendar: Calendar,
                 newPerDay: Int, reviewsPerDay: Int) throws -> CardLearningSummary {
        let label: String
        let cards: [Card]
        let selectedEvents: [DayRecord]
        let groupValues: [CardStudyAvailability.Group]
        switch scope {
        case .all:
            label = "全部牌组"
            cards = projections.filter { $0.deletedAt == nil }
            selectedEvents = Array(events.values)
            groupValues = groups(cards: cards, newPerDay: newPerDay, reviewsPerDay: reviewsPerDay)
        case .deck(let name):
            label = "牌组「\(name)」"
            cards = projections.filter { $0.deck == name && $0.deletedAt == nil }
            selectedEvents = events.compactMap { byID[$0.key]?.deck == name ? $0.value : nil }
            groupValues = groups(cards: cards, newPerDay: newPerDay, reviewsPerDay: reviewsPerDay)
        case .notebook(let id):
            label = "笔记本「\(try Notebook.fetchOne(db, key: id)?.title ?? "未命名")」"
            let hids = Set(try Int64.fetchAll(db, sql: "SELECT highlightId FROM notebook_block WHERE notebookId = ? AND kind = 'highlight' AND highlightId IS NOT NULL", arguments: [id]))
            let liveHids = Set(try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE deletedAt IS NULL AND id IN (SELECT highlightId FROM notebook_block WHERE notebookId = ? AND kind = 'highlight')", arguments: [id]))
            cards = projections.filter { $0.deletedAt == nil && $0.highlightId.map(liveHids.contains) == true }
            selectedEvents = events.compactMap { entry in
                byID[entry.key]?.highlightId.map(hids.contains) == true ? entry.value : nil
            }
            let done = cards.compactMap { $0.id.flatMap { events[$0] } }
            groupValues = [.init(cards: cards, newLimit: newPerDay, reviewLimit: reviewsPerDay,
                                 newLimitLeft: newPerDay - done.filter(\.wasNew).count,
                                 reviewLimitLeft: reviewsPerDay - done.filter { !$0.wasNew }.count)]
        }
        let queue = CardStudyAvailability.summarize(groupValues, now: now, calendar: calendar, studiedCards: selectedEvents.count)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let tomorrowCount = cards.filter { !$0.isSuspended && $0.state != .new && $0.due >= tomorrow && $0.due < end }.count
        var byDeck: [String: CardStudyAvailability] = [:]
        if case .notebook = scope {} else {
            for g in groupValues {
                if let name = g.cards.first?.deck {
                    byDeck[name] = CardStudyAvailability.summarize([g], now: now, calendar: calendar, studiedCards: g.studiedCards).status
                }
            }
        }
        return .init(scopeLabel: label, studiedCards: selectedEvents.count,
                     ratingCount: selectedEvents.reduce(0) { $0 + $1.count }, correctRatings: selectedEvents.reduce(0) { $0 + $1.correct },
                     dueTomorrow: tomorrowCount, pending: queue.counts, availability: queue.status, deckAvailability: byDeck)
    }
}
