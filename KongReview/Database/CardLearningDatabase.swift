import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    /// 历史统计保留软删除卡片；全库也保留永久删除后的日志。
    /// 范围按卡片当前牌组/笔记本归属关联，已永久删除卡片无法再归入原牌组。
    func cardLearningSummary(scope: CardLearningScope = .all, now: Date = Date(),
                             calendar: Calendar = .current,
                             newPerDay: Int, reviewsPerDay: Int) throws -> CardLearningSummary {
        try cardLearningSummary(scope: scope, now: now, calendar: calendar,
                                limits: DailyLimitSettings(newPerDay: newPerDay, reviewsPerDay: reviewsPerDay))
    }

    /// 3.13：牌组上限与全库合计一起生效；笔记本学习仍以牌组默认值为本笔记本额度，并同样受全库合计约束。
    func cardLearningSummary(scope: CardLearningScope = .all, now: Date = Date(),
                             calendar: Calendar = .current,
                             limits: DailyLimitSettings = CardSettings.limits()) throws -> CardLearningSummary {
        let start = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let result = try writer.read { db -> (String, [Card], Int, Int, Int, DailyLimitLedger) in
            let filter: String
            let args: [any DatabaseValueConvertible]
            let label: String
            switch scope {
            case .all: filter = ""; args = []; label = "全部牌组"
            case .deck(let name): filter = " AND c.deck = ?"; args = [name]; label = "牌组「\(name)」"
            case .notebook(let id):
                filter = " AND c.highlightId IN (SELECT highlightId FROM notebook_block WHERE notebookId = ? AND kind = 'highlight')"
                args = [id]
                let name = try Notebook.fetchOne(db, key: id)?.title ?? "未命名"
                label = "笔记本「\(name)」"
            }
            let event = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT e.cardId) AS cards, COUNT(*) AS ratings,
                       SUM(CASE WHEN e.answer > 1 THEN 1 ELSE 0 END) AS correct
                FROM review_event e LEFT JOIN card c ON c.id = e.cardId
                WHERE e.kind = 'card' AND e.cardId IS NOT NULL AND e.at >= ? AND e.at < ?
                """ + filter, arguments: StatementArguments([start, tomorrow] + args))
            // 笔记本学习仅使用仍存在且未删除的摘录，和 nextNotebookCard 相同。
            let activeHighlight = scope.isNotebook ? " AND EXISTS (SELECT 1 FROM highlight h WHERE h.id = c.highlightId AND h.deletedAt IS NULL)" : ""
            let cards = try Card.fetchAll(db, sql: "SELECT c.* FROM card c WHERE c.deletedAt IS NULL" + filter + activeHighlight,
                                          arguments: StatementArguments(args))
            let ledger = try Self.fetchDailyLimitLedger(db, now: now, calendar: calendar, limits: limits)
            return (label, cards, event?["cards"] ?? 0, event?["ratings"] ?? 0, event?["correct"] ?? 0, ledger)
        }
        let (label, cards, studied, ratings, correct, baseLedger) = result
        var ledger = baseLedger
        let groups: [CardStudyAvailability.Group]
        if case .notebook(let id) = scope {
            // 笔记本学习沿用原设计：以牌组默认值作为本笔记本的额度；3.13 起同时受全库合计约束
            let key = DailyLimitLedger.notebookKey(id)
            let done = try studiedToday(cardIds: cards.compactMap(\.id), now: now)
            ledger = ledger.with(scope: key, spent: DailyAmount(new: done.new, review: done.review))
            groups = [Self.dailyLimitGroup(cards, key: key, ledger: ledger)]
        } else {
            groups = Self.dailyLimitGroups(cards, ledger: ledger)
        }
        let total = CardStudyAvailability.TotalCap(ledger)
        let queue = CardStudyAvailability.summarize(groups, total: total, now: now, calendar: calendar, studiedCards: studied)
        let dueTomorrow = cards.filter {
            !$0.isSuspended && $0.state != .new && $0.due >= tomorrow && $0.due < tomorrowEnd
        }.count
        var byDeck: [String: CardStudyAvailability] = [:]
        if !scope.isNotebook {
            for group in groups {
                guard let deck = group.cards.first?.deck else { continue }
                byDeck[deck] = CardStudyAvailability.summarize([group], total: total, now: now, calendar: calendar,
                                                              studiedCards: group.studiedCards).status
            }
        }
        return .init(scopeLabel: label, studiedCards: studied, ratingCount: ratings,
                     correctRatings: correct, dueTomorrow: dueTomorrow,
                     pending: queue.counts, availability: queue.status, deckAvailability: byDeck)
    }
}

extension AppDatabase {
    /// 按牌组分组；每组用牌组自己的上限与今天已学（含仅今天加量），全库合计另由 TotalCap 约束。
    static func dailyLimitGroups(_ cards: [Card], ledger: DailyLimitLedger) -> [CardStudyAvailability.Group] {
        Dictionary(grouping: cards, by: \.deck).sorted { $0.key < $1.key }.map { deck, deckCards in
            dailyLimitGroup(deckCards, key: deck, ledger: ledger)
        }
    }

    static func dailyLimitGroup(_ cards: [Card], key: String, ledger: DailyLimitLedger) -> CardStudyAvailability.Group {
        let limit = ledger.deckLimit(key), spent = ledger.spent(key)
        return .init(cards: cards, newLimit: limit.new, reviewLimit: limit.review,
                     newLimitLeft: limit.new - spent.new, reviewLimitLeft: limit.review - spent.review,
                     studiedCards: spent.new + spent.review)
    }
}

private extension CardLearningScope {
    var isNotebook: Bool { if case .notebook = self { return true }; return false }
}
