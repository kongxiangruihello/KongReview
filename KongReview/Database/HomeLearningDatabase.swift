import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    /// 回顾进度与日志取自同一读取快照，牌组待办复用学习队列口径；首页不生成或改写回顾队列。
    func homeLearningSummary(now: Date = Date(), calendar: Calendar = .current,
                             dailyReviewCount: Int, newCardsPerDay: Int, reviewsPerDay: Int,
                             session: ReviewSessionRecordStore.Snapshot? = ReviewSessionRecordStore.load(),
                             deckSummaries: [DeckSummary]? = nil) throws -> HomeLearningSummary {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let dayKey = ReminderPlan.dayKey(now, calendar: calendar)
        let decks = try deckSummaries ?? self.deckSummaries(now: now, newPerDay: newCardsPerDay, reviewsPerDay: reviewsPerDay)
        return try writer.read { db in
            var summary = HomeLearningSummary()
            summary.reviewCandidateCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND coalesce(s.reviewWeight, 1) > 0
                """) ?? 0

            if let session, session.day == dayKey {
                summary.reviewHasSession = true
                let ids = session.regularIds + session.masteryIds
                let position = min(ids.count, max(0, session.position))
                let existing = Set(try Highlight.filter(keys: Array(Set(ids)))
                    .filter(Column("deletedAt") == nil).select(Column("id")).asRequest(of: Int64.self).fetchAll(db))
                let completed = Set(ids.prefix(position)).intersection(existing)
                let pending = Set(ids.dropFirst(position)).intersection(existing).subtracting(completed)
                summary.reviewCompletedCount = completed.count
                summary.reviewPendingCount = pending.count
                summary.reviewTotalCount = completed.count + pending.count
            } else {
                summary.reviewPendingCount = min(max(0, dailyReviewCount), summary.reviewCandidateCount)
                summary.reviewTotalCount = summary.reviewPendingCount
            }

            // 张数按 cardId 去重，评分次数另列；不关联存活卡，删除后仍保留当天历史。
            let todayCards = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT cardId) AS studied, COUNT(*) AS ratings
                FROM review_event
                WHERE kind = 'card' AND cardId IS NOT NULL AND at >= ? AND at < ?
                """, arguments: [start, end])
            summary.cardsStudiedCount = todayCards?["studied"] ?? 0
            summary.cardsRatingCount = todayCards?["ratings"] ?? 0
            // 含每日新卡/复习上限和学习中提前20分钟；不能用已学张数抵消当前待办。
            summary.activeCardCount = decks.reduce(0) { $0 + $1.total }
            summary.cardsNewDueCount = decks.reduce(0) { $0 + $1.counts.new }
            summary.cardsLearningDueCount = decks.reduce(0) { $0 + $1.counts.learning }
            summary.cardsReviewDueCount = decks.reduce(0) { $0 + $1.counts.review }

            // Calendar 显式决定每天的边界，包括非系统时区及夏令时；只按日取汇总，不加载全部日志。
            let dayFunction = DatabaseFunction("kr_home_learning_day", argumentCount: 1, pure: true) { values in
                guard let date = Date.fromDatabaseValue(values[0]) else { return nil }
                return ReminderPlan.dayKey(date, calendar: calendar)
            }
            db.add(function: dayFunction)
            defer { db.remove(function: dayFunction) }
            let dayRows = try Row.fetchAll(db, sql: """
                SELECT kr_home_learning_day(at) AS day,
                       COUNT(DISTINCT CASE WHEN kind NOT IN ('card', 'note') THEN highlightId END) AS highlights,
                       COUNT(DISTINCT CASE WHEN kind = 'card' THEN cardId END) AS cards,
                       SUM(CASE WHEN kind = 'card' AND cardId IS NOT NULL THEN 1 ELSE 0 END) AS ratings
                FROM review_event WHERE at < ? GROUP BY day
                """, arguments: [end])
            var history: [String: ReviewStats.Day] = [:]
            var ratings: [String: Int] = [:]
            for row in dayRows {
                guard let key: String = row["day"] else { continue }
                history[key] = ReviewStats.Day(key: key, highlights: row["highlights"] ?? 0, cards: row["cards"] ?? 0)
                ratings[key] = row["ratings"] ?? 0
            }
            let streaks = ReviewStats.summarize(byDay: history, again: 0, now: now, days: 7, calendar: calendar)
            summary.learningStreak = streaks.currentStreak
            summary.longestLearningStreak = streaks.longestStreak
            summary.recentDays = (0..<7).reversed().map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: start)!
                let key = ReminderPlan.dayKey(date, calendar: calendar)
                let counts = history[key]
                return HomeLearningSummary.Day(date: date, key: key, highlights: counts?.highlights ?? 0,
                                               cards: counts?.cards ?? 0, cardRatings: ratings[key] ?? 0)
            }
            return summary
        }
    }
}
