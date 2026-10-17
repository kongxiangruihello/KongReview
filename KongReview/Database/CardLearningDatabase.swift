import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    /// 历史统计保留软删除卡片；全库也保留永久删除后的日志。
    /// 范围按卡片当前牌组/笔记本归属关联，已永久删除卡片无法再归入原牌组。
    func cardLearningSummary(scope: CardLearningScope = .all, now: Date = Date(),
                             calendar: Calendar = .current,
                             newPerDay: Int = CardSettings.newPerDay,
                             reviewsPerDay: Int = CardSettings.reviewsPerDay) throws -> CardLearningSummary {
        let start = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let result = try writer.read { db -> (String, [Card], Int, Int, Int) in
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
            return (label, cards, event?["cards"] ?? 0, event?["ratings"] ?? 0, event?["correct"] ?? 0)
        }
        let (label, cards, studied, ratings, correct) = result
        var groups: [CardStudyAvailability.Group] = []
        if case .notebook = scope {
            let done = try studiedToday(cardIds: cards.compactMap(\.id), now: now)
            groups = [.init(cards: cards, newLimit: newPerDay, reviewLimit: reviewsPerDay,
                            newLimitLeft: newPerDay - done.new, reviewLimitLeft: reviewsPerDay - done.review)]
        } else {
            for (deck, deckCards) in Dictionary(grouping: cards, by: \.deck) {
                let options = try effectiveOptions(deck, defaults: (newPerDay, reviewsPerDay))
                let newLimit = options.newPerDay ?? newPerDay
                let reviewLimit = options.reviewsPerDay ?? reviewsPerDay
                let done = try studiedToday(deck: deck, now: now)
                groups.append(.init(cards: deckCards, newLimit: newLimit, reviewLimit: reviewLimit,
                                    newLimitLeft: newLimit - done.new, reviewLimitLeft: reviewLimit - done.review,
                                    studiedCards: done.new + done.review))
            }
        }
        let queue = CardStudyAvailability.summarize(groups, now: now, calendar: calendar, studiedCards: studied)
        let dueTomorrow = cards.filter {
            !$0.isSuspended && $0.state != .new && $0.due >= tomorrow && $0.due < tomorrowEnd
        }.count
        var byDeck: [String: CardStudyAvailability] = [:]
        if !scope.isNotebook {
            for group in groups {
                guard let deck = group.cards.first?.deck else { continue }
                byDeck[deck] = CardStudyAvailability.summarize([group], now: now, calendar: calendar,
                                                              studiedCards: group.studiedCards).status
            }
        }
        return .init(scopeLabel: label, studiedCards: studied, ratingCount: ratings,
                     correctRatings: correct, dueTomorrow: dueTomorrow,
                     pending: queue.counts, availability: queue.status, deckAvailability: byDeck)
    }
}

private extension CardLearningScope {
    var isNotebook: Bool { if case .notebook = self { return true }; return false }
}
