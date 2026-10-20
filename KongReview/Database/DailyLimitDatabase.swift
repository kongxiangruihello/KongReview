import Foundation
import GRDB
import KongReviewCore

// MARK: - 3.13：每日学习量（牌组上限、全库合计与今日加量的统一口径）

/// 每日学习量面板的一行：牌组的单独设置、今天已学与此刻实际有的卡（不考虑上限）
struct DailyLimitDeckRow: Identifiable, Hashable {
    var deck: String
    var override: DailyLimitOverride
    var spent: DailyAmount
    /// 未暂停的新卡总数、今天到期的复习卡数、学习中可学的卡数
    var availableNew: Int
    var dueReview: Int
    var learning: Int
    var id: String { deck }

    func available(_ kind: DailyLimitKind) -> Int { kind == .new ? availableNew : dueReview }
}

/// 面板打开时读取的一份快照；之后的预览只在内存里重算
struct DailyLimitOverview: Equatable {
    var day: String
    var rows: [DailyLimitDeckRow]
    /// 已彻底删除、无法归入牌组的卡今天学过的张数（只计入全库合计）
    var unattributedSpent: DailyAmount

    func ledger(_ settings: DailyLimitSettings, overrides: [String: DailyLimitOverride]? = nil) -> DailyLimitLedger {
        var spent = Dictionary(uniqueKeysWithValues: rows.map { ($0.deck, $0.spent) })
        if !unattributedSpent.isZero { spent[""] = (spent[""] ?? .zero) + unattributedSpent }
        return DailyLimitLedger(settings: settings, day: day,
                                overrides: overrides ?? Dictionary(uniqueKeysWithValues: rows.map { ($0.deck, $0.override) }),
                                spent: spent)
    }
}

extension AppDatabase {
    static func dailyLimitOverrides(_ options: [DeckOptions]) -> [String: DailyLimitOverride] {
        Dictionary(options.map { ($0.deck, DailyLimitOverride(new: $0.newPerDay, review: $0.reviewsPerDay)) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// 今天各牌组已学张数。新卡、复习按“今天第一次回答前的状态”区分（与 `studiedToday` 相同）；
    /// 按卡片当前所在牌组归类，已彻底删除的卡记在空字符串下。
    static func fetchSpentToday(_ db: Database, start: Date, end: Date) throws -> [String: DailyAmount] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.cardId AS id, COUNT(*) AS n,
                (SELECT e2.cardState FROM review_event e2 WHERE e2.cardId = e.cardId AND e2.kind = 'card'
                    AND e2.at >= ? AND e2.at < ? ORDER BY e2.at, e2.id LIMIT 1) AS firstState,
                EXISTS (SELECT 1 FROM review_event p WHERE p.cardId = e.cardId AND p.kind = 'card' AND p.at < ?) AS prior,
                c.reps AS reps, c.deck AS deck
            FROM review_event e LEFT JOIN card c ON c.id = e.cardId
            WHERE e.kind = 'card' AND e.cardId IS NOT NULL AND e.at >= ? AND e.at < ?
            GROUP BY e.cardId
            """, arguments: [start, end, start, start, end])
        var spent: [String: DailyAmount] = [:]
        for row in rows {
            let isNew = firstAnswerWasNew(state: row["firstState"], prior: row["prior"] ?? false,
                                          reps: row["reps"] ?? 0, answers: row["n"] ?? 0)
            let deck: String = row["deck"] ?? ""
            var value = spent[deck] ?? .zero
            if isNew { value.new += 1 } else { value.review += 1 }
            spent[deck] = value
        }
        return spent
    }

    static func fetchDailyLimitLedger(_ db: Database, now: Date, calendar: Calendar,
                                      limits: DailyLimitSettings) throws -> DailyLimitLedger {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DailyLimitLedger(settings: limits, day: DeckOverview.dayKey(now, calendar: calendar),
                                overrides: dailyLimitOverrides(try DeckOptions.fetchAll(db)),
                                spent: try fetchSpentToday(db, start: start, end: end))
    }

    func dailyLimitLedger(now: Date = Date(), calendar: Calendar = .current,
                          limits: DailyLimitSettings = CardSettings.limits()) throws -> DailyLimitLedger {
        try writer.read { db in try Self.fetchDailyLimitLedger(db, now: now, calendar: calendar, limits: limits) }
    }

    /// 每日学习量面板的数据：每个有卡的牌组一行（也包括只有单独设置、暂时没卡的牌组）
    func dailyLimitOverview(now: Date = Date(), calendar: Calendar = .current) throws -> DailyLimitOverview {
        try writer.read { db in
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            var spent = try Self.fetchSpentToday(db, start: start, end: end)
            let overrides = Self.dailyLimitOverrides(try DeckOptions.fetchAll(db))
            // 只取排程投影，不读正文
            let cards = try Row.fetchAll(db, sql: """
                SELECT id, deck, state, due, interval, reps, createdAt FROM card
                WHERE deletedAt IS NULL AND isSuspended = 0
                """).map { row in
                    Card(id: row["id"], deck: row["deck"], front: "",
                         state: Card.State(rawValue: row["state"]) ?? .new, interval: row["interval"],
                         due: row["due"], reps: row["reps"], createdAt: row["createdAt"])
                }
            var byDeck: [String: (new: Int, review: Int, learning: Int)] = [:]
            for card in cards where StudyQueue.isDue(card, now: now) {
                var value = byDeck[card.deck] ?? (0, 0, 0)
                switch card.state {
                case .new: value.new += 1
                case .review: value.review += 1
                case .learning, .relearning: value.learning += 1
                }
                byDeck[card.deck] = value
            }
            let deckNames = Set(try String.fetchAll(db, sql: "SELECT DISTINCT deck FROM card WHERE deletedAt IS NULL"))
                .union(overrides.keys)
            let unattributed = spent.removeValue(forKey: "") ?? .zero
            let rows: [DailyLimitDeckRow] = deckNames.sorted().map { deck in
                let a = byDeck[deck] ?? (0, 0, 0)
                return DailyLimitDeckRow(deck: deck, override: overrides[deck] ?? .init(),
                                         spent: spent.removeValue(forKey: deck) ?? .zero,
                                         availableNew: a.new, dueReview: a.review, learning: a.learning)
            }
            // 今天学过、但所在牌组已没有卡（卡片都已删除）：只计入合计
            let orphan = spent.values.reduce(DailyAmount.zero, +)
            return DailyLimitOverview(day: DeckOverview.dayKey(now, calendar: calendar), rows: rows,
                                      unattributedSpent: unattributed + orphan)
        }
    }

    /// 保存每日学习量面板里的牌组单独设置；只改上限两项，算法与保留率保持原样
    func saveDailyLimitOverrides(_ overrides: [String: DailyLimitOverride]) throws {
        try writer.write { db in
            for (deck, value) in overrides {
                var options = try DeckOptions.fetchOne(db, key: deck) ?? DeckOptions(deck: deck)
                guard options.newPerDay != value.new || options.reviewsPerDay != value.review else { continue }
                options.newPerDay = value.new.map(DailyLimitSettings.clamp)
                options.reviewsPerDay = value.review.map(DailyLimitSettings.clamp)
                try options.save(db)
            }
        }
    }
}
