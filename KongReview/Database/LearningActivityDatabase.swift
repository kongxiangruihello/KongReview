import Foundation
import GRDB
import KongReviewCore

extension AppDatabase {
    func learningActivitySummary(now: Date = Date(), days: Int = 30,
                                 calendar: Calendar = .current) throws -> LearningActivitySummary {
        try writer.read { db in
            try Self.fetchLearningActivitySummary(db, now: now, days: days, calendar: calendar)
        }
    }

    static func fetchLearningActivitySummary(_ db: Database, now: Date, days: Int,
                                            calendar: Calendar) throws -> LearningActivitySummary {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let dayFunction = DatabaseFunction("kr_home_learning_day", argumentCount: 1, pure: true) { values in
            guard let date = Date.fromDatabaseValue(values[0]) else { return nil }
            return ReminderPlan.dayKey(date, calendar: calendar)
        }
        db.add(function: dayFunction)
        defer { db.remove(function: dayFunction) }
        let rows = try Row.fetchAll(db, sql: """
            SELECT kr_home_learning_day(at) AS day,
                   COUNT(DISTINCT CASE WHEN kind NOT IN ('card', 'note') THEN highlightId END) AS highlights,
                   COUNT(DISTINCT CASE WHEN kind = 'card' THEN cardId END) AS cards,
                   SUM(CASE WHEN kind = 'card' AND cardId IS NOT NULL THEN 1 ELSE 0 END) AS ratings,
                   SUM(CASE WHEN kind NOT IN ('card', 'note') THEN 1 ELSE 0 END) AS actions,
                   SUM(CASE WHEN kind = 'card' THEN 1 ELSE 0 END) AS attempts,
                   SUM(CASE WHEN kind = 'card' AND answer = 1 THEN 1 ELSE 0 END) AS again
            FROM review_event WHERE at < ? GROUP BY day
            """, arguments: [end])
        var history: [String: ReviewStats.Day] = [:]
        var ratings: [String: Int] = [:]
        var eventDays: [String: ReviewStats.Day] = [:]
        var again = 0
        for row in rows {
            guard let key: String = row["day"] else { continue }
            history[key] = ReviewStats.Day(key: key, highlights: row["highlights"] ?? 0, cards: row["cards"] ?? 0)
            ratings[key] = row["ratings"] ?? 0
            eventDays[key] = ReviewStats.Day(key: key, highlights: row["actions"] ?? 0, cards: row["attempts"] ?? 0)
            again += (row["again"] as Int?) ?? 0
        }
        let count = max(1, days)
        let streaks = ReviewStats.summarize(byDay: history, again: 0, now: now, days: count, calendar: calendar)
        let recentDays = (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: start)!
            let key = ReminderPlan.dayKey(date, calendar: calendar)
            let day = history[key]
            return HomeLearningSummary.Day(date: date, key: key, highlights: day?.highlights ?? 0,
                                           cards: day?.cards ?? 0, cardRatings: ratings[key] ?? 0)
        }
        return LearningActivitySummary(recentDays: recentDays, currentStreak: streaks.currentStreak,
                                       longestStreak: streaks.longestStreak, activeDays: streaks.activeDays,
                                       eventSummary: ReviewStats.summarize(byDay: eventDays, again: again,
                                                                          now: now, days: count, calendar: calendar))
    }
}
