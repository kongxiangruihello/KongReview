import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    /// 回顾进度与日志取自同一读取快照，牌组待办复用学习队列口径；首页不生成或改写回顾队列。
    func homeLearningSummary(now: Date = Date(), calendar: Calendar = .current,
                             dailyReviewCount: Int, newCardsPerDay: Int, reviewsPerDay: Int,
                             session: ReviewSessionRecordStore.Snapshot? = ReviewSessionRecordStore.load(),
                             deckSummaries: [DeckSummary]? = nil,
                             activitySummary: LearningActivitySummary? = nil,
                             cardAvailability: CardStudyAvailability? = nil) throws -> HomeLearningSummary {
        try homeLearningSummary(now: now, calendar: calendar, dailyReviewCount: dailyReviewCount,
                                limits: DailyLimitSettings(newPerDay: newCardsPerDay, reviewsPerDay: reviewsPerDay),
                                session: session, deckSummaries: deckSummaries, activitySummary: activitySummary,
                                cardAvailability: cardAvailability)
    }

    func homeLearningSummary(now: Date = Date(), calendar: Calendar = .current,
                             dailyReviewCount: Int, limits: DailyLimitSettings,
                             session: ReviewSessionRecordStore.Snapshot? = ReviewSessionRecordStore.load(),
                             deckSummaries: [DeckSummary]? = nil,
                             activitySummary: LearningActivitySummary? = nil,
                             cardAvailability: CardStudyAvailability? = nil) throws -> HomeLearningSummary {
        let decks = try deckSummaries ?? self.deckSummaries(now: now, calendar: calendar, limits: limits)
        let global = try cardLearningSummary(scope: .all, now: now, calendar: calendar, limits: limits)
        return try writer.read { db in
            let activity = try activitySummary ?? Self.fetchLearningActivitySummary(db, now: now, days: 7, calendar: calendar)
            return try Self.fetchHomeLearningSummary(db, now: now, calendar: calendar, dailyReviewCount: dailyReviewCount,
                                                    session: session, decks: decks, activity: activity,
                                                    availability: cardAvailability ?? global.availability,
                                                    pending: global.pending)
        }
    }

    static func fetchHomeLearningSummary(_ db: Database, now: Date, calendar: Calendar,
                                         dailyReviewCount: Int, session: ReviewSessionRecordStore.Snapshot?,
                                         decks: [DeckSummary], activity: LearningActivitySummary,
                                         availability: CardStudyAvailability,
                                         pending: StudyQueue.Counts? = nil) throws -> HomeLearningSummary {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let dayKey = ReminderPlan.dayKey(now, calendar: calendar)
        var summary = HomeLearningSummary()
        summary.cardAvailability = availability
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
        // 3.13：有全库合计上限时，各牌组可学张数之和可能超过合计余额，待办以全库队列为准。
        summary.activeCardCount = decks.reduce(0) { $0 + $1.total }
        let due = pending ?? decks.reduce(StudyQueue.Counts()) { c, d in
            StudyQueue.Counts(new: c.new + d.counts.new, learning: c.learning + d.counts.learning, review: c.review + d.counts.review)
        }
        summary.cardsNewDueCount = due.new
        summary.cardsLearningDueCount = due.learning
        summary.cardsReviewDueCount = due.review

        summary.learningStreak = activity.currentStreak
        summary.longestLearningStreak = activity.longestStreak
        summary.recentDays = Array(activity.recentDays.suffix(7))
        return summary
    }
}
