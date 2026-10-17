import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class LearningActivitySummaryTests: XCTestCase {
    func testThirtyDayHistoryUsesTheSameDailyDeduplicationAsHome() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        db.log(ReviewEvent(kind: .keep, highlightId: 1, at: now))
        db.log(ReviewEvent(kind: .favorite, highlightId: 1, at: now))
        db.log(ReviewEvent(kind: .note, highlightId: 2, at: now))
        db.log(ReviewEvent(kind: .keep, highlightId: 1, at: yesterday))
        db.log(ReviewEvent(kind: .card, cardId: 3, answer: 1, at: now))
        db.log(ReviewEvent(kind: .card, cardId: 3, answer: 3, at: now))
        let activity = try db.learningActivitySummary(now: now)
        let home = try db.homeLearningSummary(now: now, dailyReviewCount: 10,
                                             newCardsPerDay: 20, reviewsPerDay: 200, session: nil)
        XCTAssertEqual(activity.recentDays.count, 30)
        XCTAssertEqual(activity.today.highlights, 1)
        XCTAssertEqual(activity.today.cards, 1)
        XCTAssertEqual(activity.today.cardRatings, 2)
        XCTAssertEqual(activity.currentStreak, 2)
        XCTAssertEqual(activity.activeDays, 2)
        XCTAssertEqual(Array(activity.recentDays.suffix(7)), home.recentDays)
        let cachedHome = try db.homeLearningSummary(now: now, dailyReviewCount: 10,
                                                   newCardsPerDay: 20, reviewsPerDay: 200,
                                                   session: nil, activitySummary: activity)
        XCTAssertEqual(home, cachedHome)
    }

    func testStoreRefreshUpdatesHomeAndStatisticsTogether() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            let card = try db.save(Card(front: "同步统计"))
            db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 1))
            db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 3))
            store.revisionBump()
            XCTAssertEqual(store.learningActivitySummary.today.cards, 1)
            XCTAssertEqual(store.learningActivitySummary.today.cardRatings, 2)
            XCTAssertEqual(store.homeLearningSummary.cardsStudiedCount, 1)
            XCTAssertEqual(store.homeLearningSummary.cardsRatingCount, 2)
            XCTAssertEqual(store.cardLearningSummary?.studiedCards, 1)
            XCTAssertEqual(store.cardLearningSummary?.ratingCount, 2)
        }
    }

    func testHomeDoesNotCelebrateCardsBlockedByLimitsWaitingOrSuspension() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = Date()
        var card = try db.save(Card(deck: "状态核对", front: "学习安排"))
        try db.save(DeckOptions(deck: card.deck, newPerDay: 0, reviewsPerDay: 0))
        func home() throws -> HomeLearningSummary {
            try db.homeLearningSummary(now: now, dailyReviewCount: 10, newCardsPerDay: 20,
                                       reviewsPerDay: 200, session: nil)
        }
        let limited = try home()
        XCTAssertEqual(limited.cardsDueCount, 0)
        XCTAssertEqual(limited.cardAvailability?.kind, .dailyLimit)
        XCTAssertFalse(limited.cardsIsComplete)
        XCTAssertFalse(limited.isComplete)
        card.state = .learning
        card.due = now.addingTimeInterval(25 * 60)
        card = try db.save(card)
        let waiting = try home()
        XCTAssertEqual(waiting.cardAvailability?.kind, .waitingLearning)
        XCTAssertFalse(waiting.cardsIsComplete)
        XCTAssertFalse(waiting.isComplete)
        card.isSuspended = true
        _ = try db.save(card)
        let paused = try home()
        XCTAssertEqual(paused.cardAvailability?.kind, .allSuspended)
        XCTAssertFalse(paused.cardsIsComplete)
        XCTAssertFalse(paused.isComplete)
    }
}
