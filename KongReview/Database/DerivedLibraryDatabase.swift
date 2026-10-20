import Foundation
import GRDB
import KongReviewCore

/// 只包含不可变值；数据库连接始终留在 GRDB 的读取闭包里。
struct DerivedLibraryRequest: @unchecked Sendable {
    let now: Date
    let dailyReviewCount: Int
    /// 3.13：牌组默认上限、全库合计与今日加量
    let limits: DailyLimitSettings
    let scope: CardLearningScope
    let session: ReviewSessionRecordStore.Snapshot?

    var newPerDay: Int { limits.newPerDay }
    var reviewsPerDay: Int { limits.reviewsPerDay }

    init(now: Date, dailyReviewCount: Int, limits: DailyLimitSettings,
         scope: CardLearningScope, session: ReviewSessionRecordStore.Snapshot?) {
        self.now = now; self.dailyReviewCount = dailyReviewCount; self.limits = limits
        self.scope = scope; self.session = session
    }

    init(now: Date, dailyReviewCount: Int, newPerDay: Int, reviewsPerDay: Int,
         scope: CardLearningScope, session: ReviewSessionRecordStore.Snapshot?) {
        self.init(now: now, dailyReviewCount: dailyReviewCount,
                  limits: DailyLimitSettings(newPerDay: newPerDay, reviewsPerDay: reviewsPerDay),
                  scope: scope, session: session)
    }
}

struct DerivedLibrarySnapshot: @unchecked Sendable {
    let stale: AppDatabase.StaleSummary
    let activity: LearningActivitySummary
    let decks: [DeckSummary]
    let globalCards: CardLearningSummary
    let scopedCards: CardLearningSummary
    let home: HomeLearningSummary
    /// 3.13：同一次读取的每日上限账本（牌组卡片标签、统计页、首页合计用）
    let ledger: DailyLimitLedger
}

extension AppDatabase {
    /// 一次读取快照完成整组统计，查询次数不随牌组数量增加。
    /// 卡片只取排程投影，不读取正反面、图片、栏目或多字段正文。
    func derivedLibrarySnapshot(_ request: DerivedLibraryRequest) throws -> DerivedLibrarySnapshot {
        try Task.checkCancellation()
        return try writer.read { db in
            let calendar = Calendar.current
            let context = try CardStatisticsContext(db: db, now: request.now, calendar: calendar, limits: request.limits)
            try Task.checkCancellation()
            let activity = try Self.fetchLearningActivitySummary(db, now: request.now, days: 30, calendar: calendar)
            let decks = context.deckSummaries(now: request.now)
            let global = try context.summary(scope: .all, in: db, now: request.now, calendar: calendar)
            let scoped = request.scope == .all ? global : try context.summary(
                scope: request.scope, in: db, now: request.now, calendar: calendar)
            try Task.checkCancellation()
            let home = try Self.fetchHomeLearningSummary(db, now: request.now, calendar: calendar,
                dailyReviewCount: request.dailyReviewCount, session: request.session,
                decks: decks, activity: activity, availability: global.availability, pending: global.pending)
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
                         globalCards: global, scopedCards: scoped, home: home, ledger: context.ledger)
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
    let events: [Int64: DayRecord]
    /// 3.13：牌组上限、全库合计与今天已学（按牌组）
    let ledger: DailyLimitLedger

    init(db: Database, now: Date, calendar: Calendar, limits: DailyLimitSettings) throws {
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
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.cardId, COUNT(*) AS n, SUM(CASE WHEN e.answer > 1 THEN 1 ELSE 0 END) AS correct,
                (SELECT e2.cardState FROM review_event e2 WHERE e2.cardId = e.cardId AND e2.kind = 'card'
                    AND e2.at >= ? AND e2.at < ? ORDER BY e2.at, e2.id LIMIT 1) AS firstState,
                EXISTS (SELECT 1 FROM review_event p WHERE p.cardId = e.cardId AND p.kind = 'card' AND p.at < ?) AS prior
            FROM review_event e WHERE e.kind = 'card' AND e.cardId IS NOT NULL AND e.at >= ? AND e.at < ?
            GROUP BY e.cardId
            """, arguments: [start, end, start, start, end])
        var events: [Int64: DayRecord] = [:]
        var spent: [String: DailyAmount] = [:]
        for row in rows {
            let id: Int64 = row["cardId"]
            let count: Int = row["n"]
            let wasNew = AppDatabase.firstAnswerWasNew(state: row["firstState"], prior: row["prior"] ?? false,
                                                       reps: byID[id]?.reps ?? 0, answers: count)
            events[id] = .init(count: count, correct: row["correct"] ?? 0, wasNew: wasNew)
            // 已彻底删除、无法归入牌组的卡记在空字符串下，只计入全库合计（与 fetchSpentToday 相同）
            let deck = byID[id]?.deck ?? ""
            var value = spent[deck] ?? .zero
            if wasNew { value.new += 1 } else { value.review += 1 }
            spent[deck] = value
        }
        self.events = events
        ledger = DailyLimitLedger(settings: limits, day: DeckOverview.dayKey(now, calendar: calendar),
                                  overrides: AppDatabase.dailyLimitOverrides(try DeckOptions.fetchAll(db)),
                                  spent: spent)
    }

    func groups(cards: [Card]) -> [CardStudyAvailability.Group] {
        AppDatabase.dailyLimitGroups(cards, ledger: ledger)
    }

    func deckSummaries(now: Date) -> [DeckSummary] {
        groups(cards: projections.filter { $0.deletedAt == nil }).map { g in
            let deck = g.cards[0].deck
            let left = ledger.left(deck)
            return DeckSummary(name: deck, total: g.cards.count,
                               counts: StudyQueue.counts(g.cards, now: now, newLimitLeft: left.new, reviewLimitLeft: left.review),
                               maturity: DeckMaturity(g.cards), doneToday: g.studiedCards)
        }
    }

    func summary(scope: CardLearningScope, in db: Database, now: Date, calendar: Calendar) throws -> CardLearningSummary {
        let label: String
        let cards: [Card]
        let selectedEvents: [DayRecord]
        let groupValues: [CardStudyAvailability.Group]
        var ledger = self.ledger
        switch scope {
        case .all:
            label = "全部牌组"
            cards = projections.filter { $0.deletedAt == nil }
            selectedEvents = Array(events.values)
            groupValues = groups(cards: cards)
        case .deck(let name):
            label = "牌组「\(name)」"
            cards = projections.filter { $0.deck == name && $0.deletedAt == nil }
            selectedEvents = events.compactMap { byID[$0.key]?.deck == name ? $0.value : nil }
            groupValues = groups(cards: cards)
        case .notebook(let id):
            label = "笔记本「\(try Notebook.fetchOne(db, key: id)?.title ?? "未命名")」"
            let hids = Set(try Int64.fetchAll(db, sql: "SELECT highlightId FROM notebook_block WHERE notebookId = ? AND kind = 'highlight' AND highlightId IS NOT NULL", arguments: [id]))
            let liveHids = Set(try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE deletedAt IS NULL AND id IN (SELECT highlightId FROM notebook_block WHERE notebookId = ? AND kind = 'highlight')", arguments: [id]))
            cards = projections.filter { $0.deletedAt == nil && $0.highlightId.map(liveHids.contains) == true }
            selectedEvents = events.compactMap { entry in
                byID[entry.key]?.highlightId.map(hids.contains) == true ? entry.value : nil
            }
            let done = cards.compactMap { $0.id.flatMap { events[$0] } }
            let key = DailyLimitLedger.notebookKey(id)
            ledger = ledger.with(scope: key, spent: DailyAmount(new: done.filter(\.wasNew).count,
                                                                 review: done.filter { !$0.wasNew }.count))
            groupValues = [AppDatabase.dailyLimitGroup(cards, key: key, ledger: ledger)]
        }
        let total = CardStudyAvailability.TotalCap(ledger)
        let queue = CardStudyAvailability.summarize(groupValues, total: total, now: now, calendar: calendar, studiedCards: selectedEvents.count)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let tomorrowCount = cards.filter { !$0.isSuspended && $0.state != .new && $0.due >= tomorrow && $0.due < end }.count
        var byDeck: [String: CardStudyAvailability] = [:]
        if case .notebook = scope {} else {
            for g in groupValues {
                if let name = g.cards.first?.deck {
                    byDeck[name] = CardStudyAvailability.summarize([g], total: total, now: now, calendar: calendar, studiedCards: g.studiedCards).status
                }
            }
        }
        return .init(scopeLabel: label, studiedCards: selectedEvents.count,
                     ratingCount: selectedEvents.reduce(0) { $0 + $1.count }, correctRatings: selectedEvents.reduce(0) { $0 + $1.correct },
                     dueTomorrow: tomorrowCount, pending: queue.counts, availability: queue.status, deckAvailability: byDeck)
    }
}
