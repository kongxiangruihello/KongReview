import Foundation

/// 首页的学习任务与历史汇总。队列进度、去重条数和评分次数分别保存，避免混用口径。
struct HomeLearningSummary: Equatable {
    struct Day: Equatable, Identifiable {
        var date: Date
        var key: String
        var highlights: Int
        var cards: Int
        var cardRatings: Int
        var total: Int { highlights + cards }
        var id: String { key }
    }

    /// 仅当前全库当日回顾队列的进度；未生成队列时按每日目标估算待办。
    var reviewCompletedCount = 0
    var reviewPendingCount = 0
    var reviewTotalCount = 0
    var reviewCandidateCount = 0
    var reviewHasSession = false

    /// 日志中的去重卡片张数，保留已删除卡片的学习历史。
    var cardsStudiedCount = 0
    var cardsRatingCount = 0
    var cardsNewDueCount = 0
    var cardsLearningDueCount = 0
    var cardsReviewDueCount = 0
    var activeCardCount = 0
    var cardAvailability: CardStudyAvailability?
    var cardsDueCount: Int { cardsNewDueCount + cardsLearningDueCount + cardsReviewDueCount }

    var learningStreak = 0
    var longestLearningStreak = 0
    var recentDays: [Day] = []

    var reviewIsComplete: Bool {
        reviewHasSession && reviewTotalCount > 0 && reviewPendingCount == 0
    }
    var cardsIsComplete: Bool {
        guard activeCardCount > 0 && cardsDueCount == 0 else { return false }
        guard let availability = cardAvailability else { return true }
        return availability.kind == .complete || availability.kind == .scheduled
    }
    var isEmpty: Bool { reviewCandidateCount == 0 && reviewTotalCount == 0 && activeCardCount == 0 }
    var isComplete: Bool {
        !isEmpty && (cardsIsComplete || activeCardCount == 0)
            && (reviewIsComplete || (reviewCandidateCount == 0 && reviewTotalCount == 0))
    }

    static let empty = HomeLearningSummary()
}
