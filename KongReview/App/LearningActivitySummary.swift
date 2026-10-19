import Foundation
import KongReviewCore

/// 学习记录按天去重，评分保留次数；首页、完成页与统计页共用同一口径。
struct LearningActivitySummary: Equatable {
    var recentDays: [HomeLearningSummary.Day] = []
    var currentStreak = 0
    var longestStreak = 0
    var activeDays = 0
    var eventSummary: ReviewStats.Summary = .empty
    var today: HomeLearningSummary.Day {
        recentDays.last ?? .init(date: Date(timeIntervalSince1970: 0), key: "", highlights: 0, cards: 0, cardRatings: 0)
    }

    static let empty = LearningActivitySummary()
}
