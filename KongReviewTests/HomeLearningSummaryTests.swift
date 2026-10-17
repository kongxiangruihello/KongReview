import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class HomeLearningSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
    }

    private func summary(_ db: AppDatabase, session: ReviewSessionRecordStore.Snapshot? = nil,
                         daily: Int = 5, now: Date? = nil, calendar: Calendar? = nil,
                         decks: [DeckSummary]? = nil) throws -> HomeLearningSummary {
        try db.homeLearningSummary(now: now ?? self.now, calendar: calendar ?? self.calendar,
                                   dailyReviewCount: daily, newCardsPerDay: 20, reviewsPerDay: 200,
                                   session: session, deckSummaries: decks)
    }

    private func session(_ ids: [Int64], position: Int, date: Date? = nil) -> ReviewSessionRecordStore.Snapshot {
        .init(day: ReminderPlan.dayKey(date ?? now, calendar: calendar), regularIds: ids,
              masteryIds: [], position: position)
    }

    func testEmptyLibraryShowsNoLearningContentWithoutCelebratingCompletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let result = try summary(db)
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.reviewIsComplete)
        XCTAssertFalse(result.cardsIsComplete)
        XCTAssertEqual(result.recentDays.count, 7)
        XCTAssertTrue(result.recentDays.allSatisfy { $0.total == 0 && $0.cardRatings == 0 })
    }

    func testUngeneratedQueueEstimatesOnlyEligibleInventoryAndDoesNotSaveSession() throws {
        let db = try AppDatabase(DatabaseQueue())
        let excludedSource = try db.save(Source(title: "不回顾的书", reviewWeight: 0))
        _ = try db.save(Highlight(text: "正常摘录一"))
        _ = try db.save(Highlight(text: "正常摘录二"))
        _ = try db.save(Highlight(sourceId: excludedSource.id, text: "出处不参与回顾"))
        _ = try db.save(Highlight(text: "弃置", isDiscarded: true))
        _ = try db.save(Highlight(text: "已删除", deletedAt: now))
        let key = ReviewSessionRecord.key(theme: nil)
        let original = UserDefaults.standard.data(forKey: key)
        let result = try summary(db, daily: 1)
        XCTAssertFalse(result.reviewHasSession)
        XCTAssertEqual(result.reviewCandidateCount, 2)
        XCTAssertEqual(result.reviewCompletedCount, 0)
        XCTAssertEqual(result.reviewPendingCount, 1)
        XCTAssertEqual(result.reviewTotalCount, 1)
        XCTAssertFalse(result.reviewIsComplete)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
    }

    func testQueueProgressCountsVisitedAndPendingSeparatelyAfterDeletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let visited = try db.save(Highlight(text: "已看"))
        let removedVisited = try db.save(Highlight(text: "已看后删除", deletedAt: now))
        let removedPending = try db.save(Highlight(text: "未看已删除", deletedAt: now))
        let pending = try db.save(Highlight(text: "待回顾"))
        let record = session([visited.id!, removedVisited.id!, removedPending.id!, pending.id!, visited.id!], position: 2)
        let result = try summary(db, session: record)
        XCTAssertTrue(result.reviewHasSession)
        XCTAssertEqual(result.reviewCompletedCount, 1)
        XCTAssertEqual(result.reviewPendingCount, 1)
        XCTAssertEqual(result.reviewTotalCount, 2)
        XCTAssertEqual(result.reviewCompletedCount + result.reviewPendingCount, result.reviewTotalCount)
        XCTAssertFalse(result.reviewIsComplete)
    }

    func testYesterdayQueueDoesNotCompleteTodayAndPositionsAreClamped() throws {
        let db = try AppDatabase(DatabaseQueue())
        let highlight = try db.save(Highlight(text: "每天重新回顾"))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let old = try summary(db, session: session([highlight.id!], position: 1, date: yesterday))
        XCTAssertFalse(old.reviewHasSession)
        XCTAssertEqual(old.reviewCompletedCount, 0)
        XCTAssertEqual(old.reviewPendingCount, 1)
        XCTAssertFalse(old.reviewIsComplete)
        let negative = try summary(db, session: session([highlight.id!], position: -10))
        XCTAssertEqual(negative.reviewPendingCount, 1)
        let beyondEnd = try summary(db, session: session([highlight.id!], position: 100))
        XCTAssertEqual(beyondEnd.reviewCompletedCount, 1)
        XCTAssertTrue(beyondEnd.reviewIsComplete)
    }

    func testEmptyQueueAndZeroTargetNeverPretendToBeCompleted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let removed = try db.save(Highlight(text: "从队列中删除", deletedAt: now))
        _ = try db.save(Highlight(text: "后来新增"))
        for record in [session([], position: 0), session([removed.id!], position: 1)] {
            let result = try summary(db, session: record)
            XCTAssertEqual(result.reviewTotalCount, 0)
            XCTAssertFalse(result.reviewIsComplete)
            XCTAssertFalse(result.isComplete)
        }
        let zeroTarget = try summary(db, daily: 0)
        XCTAssertEqual(zeroTarget.reviewPendingCount, 0)
        XCTAssertFalse(zeroTarget.reviewIsComplete)
        XCTAssertFalse(zeroTarget.isComplete)
        let negativeTarget = try summary(db, daily: -5)
        XCTAssertEqual(negativeTarget.reviewTotalCount, 0)
    }

    func testReviewAndCardsCompleteIndependently() throws {
        let db = try AppDatabase(DatabaseQueue())
        let highlight = try db.save(Highlight(text: "今日摘录"))
        var card = try db.save(Card(front: "今日新卡", due: now))
        let completeReview = session([highlight.id!], position: 1)
        let cardsRemain = try summary(db, session: completeReview)
        XCTAssertTrue(cardsRemain.reviewIsComplete)
        XCTAssertFalse(cardsRemain.cardsIsComplete)
        XCTAssertFalse(cardsRemain.isComplete)
        card.state = .review
        card.due = calendar.date(byAdding: .day, value: 2, to: now)!
        _ = try db.save(card)
        let allDone = try summary(db, session: completeReview)
        XCTAssertTrue(allDone.reviewIsComplete)
        XCTAssertTrue(allDone.cardsIsComplete)
        XCTAssertTrue(allDone.isComplete)
        let reviewRemains = try summary(db, session: session([highlight.id!], position: 0))
        XCTAssertFalse(reviewRemains.reviewIsComplete)
        XCTAssertTrue(reviewRemains.cardsIsComplete)
        XCTAssertFalse(reviewRemains.isComplete)
    }

    func testRepeatedRatingsCountOneStudiedCardAndLearningCardStillRemainsDue() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try db.save(Card(front: "反复重来", due: now))
        for _ in 0..<3 { card = try db.answer(card, .again, now: now) }
        let result = try summary(db)
        XCTAssertEqual(result.cardsStudiedCount, 1)
        XCTAssertEqual(result.cardsRatingCount, 3)
        XCTAssertEqual(result.cardsLearningDueCount, 1)
        XCTAssertEqual(result.cardsDueCount, 1)
        XCTAssertFalse(result.cardsIsComplete)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.recentDays.last?.cards, 1)
        XCTAssertEqual(result.recentDays.last?.cardRatings, 3)
    }

    func testCardAndHistoryTotalsSurviveSoftAndPermanentDeletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        var softDeleted = try db.save(Card(front: "删除后保留历史"))
        let hardDeleted = try db.save(Card(front: "彻底删除后保留历史"))
        db.log(ReviewEvent(kind: .card, cardId: softDeleted.id, answer: 1, at: now))
        db.log(ReviewEvent(kind: .card, cardId: softDeleted.id, answer: 3, at: now))
        db.log(ReviewEvent(kind: .card, cardId: hardDeleted.id, answer: 3, at: now))
        db.log(ReviewEvent(kind: .card, cardId: nil, answer: 3, at: now))
        softDeleted.deletedAt = now
        _ = try db.save(softDeleted)
        try db.deleteCards([hardDeleted.id!])
        let result = try summary(db)
        XCTAssertEqual(result.cardsStudiedCount, 2)
        XCTAssertEqual(result.cardsRatingCount, 3)
        XCTAssertEqual(result.activeCardCount, 0)
        XCTAssertEqual(result.cardsDueCount, 0)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.recentDays.last?.cards, 2)
    }

    func testPendingCountsMatchDeckLimitsSuspensionAndLearningAhead() throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<3 {
            _ = try db.save(Card(deck: "自定限额", front: "新卡\(i)", due: now))
            _ = try db.save(Card(deck: "自定限额", front: "复习\(i)", state: .review, due: now))
        }
        _ = try db.save(Card(deck: "自定限额", front: "20分钟内", state: .learning, due: now.addingTimeInterval(1200)))
        _ = try db.save(Card(deck: "自定限额", front: "21分钟后", state: .learning, due: now.addingTimeInterval(1260)))
        _ = try db.save(Card(deck: "自定限额", front: "暂停卡", isSuspended: true))
        try db.save(DeckOptions(deck: "自定限额", newPerDay: 1, reviewsPerDay: 2))
        let decks = try db.deckSummaries(now: now, newPerDay: 20, reviewsPerDay: 200)
        let normal = try summary(db)
        let cached = try summary(db, decks: decks)
        XCTAssertEqual(normal, cached)
        XCTAssertEqual(normal.cardsNewDueCount, 1)
        XCTAssertEqual(normal.cardsReviewDueCount, 2)
        XCTAssertEqual(normal.cardsLearningDueCount, 1)
        let newCard = try XCTUnwrap(db.cards(deck: "自定限额").first { $0.state == .new && !$0.isSuspended })
        _ = try db.answer(newCard, .again, now: now)
        let afterAnswer = try summary(db)
        XCTAssertEqual(afterAnswer.cardsNewDueCount, 0)
        XCTAssertEqual(afterAnswer.cardsReviewDueCount, 2)
        XCTAssertEqual(afterAnswer.cardsLearningDueCount, 2)
    }

    func testSevenDayHistoryDeduplicatesBothKindsAndStreakCombinesThem() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try db.save(Highlight(text: "一天反复回顾"))
        let second = try db.save(Highlight(text: "另一条"))
        let card = try db.save(Card(front: "仅记忆卡的学习日"))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
        db.log(ReviewEvent(kind: .keep, highlightId: first.id, at: now))
        db.log(ReviewEvent(kind: .favorite, highlightId: first.id, at: now))
        db.log(ReviewEvent(kind: .discard, highlightId: second.id, at: now))
        db.log(ReviewEvent(kind: .note, highlightId: second.id, at: now))
        db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 1, at: yesterday))
        db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 3, at: yesterday))
        db.log(ReviewEvent(kind: .keep, highlightId: first.id, at: twoDaysAgo))
        let result = try summary(db)
        XCTAssertEqual(result.learningStreak, 3)
        XCTAssertEqual(result.longestLearningStreak, 3)
        XCTAssertEqual(result.recentDays.last?.highlights, 2)
        XCTAssertEqual(result.recentDays[5].cards, 1)
        XCTAssertEqual(result.recentDays[5].cardRatings, 2)
        XCTAssertEqual(result.recentDays.map(\.key), result.recentDays.map(\.key).sorted())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let next = try summary(db, now: tomorrow)
        XCTAssertEqual(next.cardsStudiedCount, 0)
        XCTAssertEqual(next.learningStreak, 3, "今天还未学习时连续天数从昨天起算")
    }

    func testDayBoundariesExcludeFutureAndCalendarFunctionDoesNotLeakBetweenReads() throws {
        let db = try AppDatabase(DatabaseQueue())
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let springDay = losAngeles.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let start = losAngeles.startOfDay(for: springDay)
        let end = losAngeles.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        db.log(ReviewEvent(kind: .card, cardId: 1, answer: 3, at: start.addingTimeInterval(-1)))
        db.log(ReviewEvent(kind: .card, cardId: 2, answer: 3, at: start))
        db.log(ReviewEvent(kind: .card, cardId: 2, answer: 3, at: end.addingTimeInterval(-1)))
        db.log(ReviewEvent(kind: .card, cardId: 3, answer: 3, at: end))
        let west = try summary(db, now: springDay, calendar: losAngeles)
        XCTAssertEqual(west.cardsStudiedCount, 1)
        XCTAssertEqual(west.cardsRatingCount, 2)
        XCTAssertEqual(west.recentDays.last?.cards, 1)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let universal = try summary(db, now: springDay, calendar: utc)
        XCTAssertEqual(universal.cardsStudiedCount, 2)
        XCTAssertEqual(universal.cardsRatingCount, 2)
        XCTAssertEqual(try summary(db, now: springDay, calendar: losAngeles), west)
        XCTAssertThrowsError(try db.writer.read { connection in
            try String.fetchOne(connection, sql: "SELECT kr_home_learning_day(?)", arguments: [springDay])
        })
    }
}
