import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class CardLearningSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 17, hour: 12))! }
    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }
    private func summary(_ db: AppDatabase, _ scope: CardLearningScope = .all,
                         new: Int = 20, review: Int = 200, at: Date? = nil) throws -> CardLearningSummary {
        try db.cardLearningSummary(scope: scope, now: at ?? now, calendar: calendar,
                                   newPerDay: new, reviewsPerDay: review)
    }

    func testScopeStatisticsSeparateUniqueCardsFromRatingsAndExcludeOtherDeck() throws {
        let db = try AppDatabase(DatabaseQueue())
        var a = try db.save(Card(deck: "甲", front: "甲", due: now))
        a = try db.answer(a, .again, now: now)
        _ = try db.answer(a, .good, now: now)
        let b = try db.save(Card(deck: "乙", front: "乙", due: now))
        _ = try db.answer(b, .easy, now: now)
        let local = try summary(db, .deck("甲"))
        XCTAssertEqual(local.scopeLabel, "牌组「甲」")
        XCTAssertEqual(local.studiedCards, 1)
        XCTAssertEqual(local.ratingCount, 2)
        XCTAssertEqual(local.correctRatings, 1)
        XCTAssertEqual(local.accuracy, 0.5)
        let global = try summary(db)
        XCTAssertEqual(global.studiedCards, 2)
        XCTAssertEqual(global.ratingCount, 3)
        XCTAssertEqual(global.correctRatings, 2)
    }

    func testHistoryRetainsSoftDeletedCardsAndGlobalPermanentDeletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try db.save(Card(deck: "历史", front: "学习历史", due: now))
        card = try db.answer(card, .easy, now: now)
        card.deletedAt = now
        _ = try db.save(card)
        XCTAssertEqual(try summary(db, .deck("历史")).studiedCards, 1)
        XCTAssertEqual(try summary(db, .deck("历史")).pending.total, 0)
        XCTAssertEqual(try summary(db, .deck("历史")).availability.kind, .noCards)
        try db.deleteCards([card.id!])
        XCTAssertEqual(try summary(db).studiedCards, 1)
        XCTAssertEqual(try summary(db).ratingCount, 1)
    }

    func testTomorrowUsesBothBoundsAndOnlyActiveScheduledCards() throws {
        let db = try AppDatabase(DatabaseQueue())
        let variants: [(Card.State, Date, Bool, Date?)] = [
            (.review, day(-1), false, nil), (.review, day(0), false, nil),
            (.review, day(1), false, nil), (.learning, day(2).addingTimeInterval(-1), false, nil),
            (.review, day(2), false, nil), (.new, day(1), false, nil),
            (.review, day(1), true, nil), (.relearning, day(1), false, now)
        ]
        for (index, value) in variants.enumerated() {
            _ = try db.save(Card(deck: "边界", front: "\(index)", state: value.0,
                                 due: value.1, isSuspended: value.2, deletedAt: value.3))
        }
        _ = try db.save(Card(deck: "另组", front: "不混入", state: .review, due: day(1)))
        XCTAssertEqual(try summary(db, .deck("边界")).dueTomorrow, 2)
        XCTAssertEqual(try summary(db).dueTomorrow, 3)
    }

    func testRatingHistoryHasExclusiveEndOfDayBoundary() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "边界评分", state: .review, due: day(5)))
        for date in [day(0).addingTimeInterval(-1), day(0), day(1).addingTimeInterval(-1), day(1)] {
            try db.writer.write { db in
                var event = ReviewEvent(kind: .card, cardId: card.id, answer: CardAnswer.good.rawValue, at: date)
                try event.insert(db)
            }
        }
        let result = try summary(db)
        XCTAssertEqual(result.studiedCards, 1)
        XCTAssertEqual(result.ratingCount, 2)
        XCTAssertEqual(result.correctRatings, 2)
    }

    func testNotebookStatisticsAndQueueUseNotebookGlobalLimits() throws {
        let db = try AppDatabase(DatabaseQueue())
        let notebook = try db.createNotebook(title: "经学")
        let highlight = try db.save(Highlight(text: "学而时习之"))
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight,
                                              highlightId: highlight.id)], into: notebook.id!, after: nil)
        _ = try db.save(Card(deck: "甲", front: "笔记本卡", highlightId: highlight.id, due: now))
        _ = try db.save(Card(deck: "甲", front: "其他卡", due: now))
        try db.save(DeckOptions(deck: "甲", newPerDay: 0, reviewsPerDay: 0))
        let result = try summary(db, .notebook(notebook.id!), new: 1)
        XCTAssertEqual(result.scopeLabel, "笔记本「经学」")
        XCTAssertEqual(result.pending.new, 1, "笔记本学习使用全局额度，不套用单个牌组选项")
        XCTAssertEqual(result.availability.kind, .ready)
        XCTAssertEqual(try summary(db, .deck("甲")).pending.new, 0)
    }

    func testGlobalQueueRespectsEachDeckLimitAndPublishesSameStatus() throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(deck: "甲", front: "甲"))
        _ = try db.save(Card(deck: "乙", front: "乙"))
        try db.save(DeckOptions(deck: "甲", newPerDay: 0))
        try db.save(DeckOptions(deck: "乙", newPerDay: 1))
        let result = try summary(db)
        XCTAssertEqual(result.pending.new, 1)
        XCTAssertEqual(result.deckAvailability["甲"]?.kind, .dailyLimit)
        XCTAssertEqual(result.deckAvailability["乙"]?.kind, .ready)
        XCTAssertEqual(result.availability.blockedNew, 1)
    }

    func testLearningWaitReportsActualDueAndEarlierEligibility() throws {
        let db = try AppDatabase(DatabaseQueue())
        let due = now.addingTimeInterval(1_800)
        _ = try db.save(Card(front: "等半小时", state: .learning, due: due))
        let result = try summary(db)
        XCTAssertEqual(result.pending.learning, 0)
        XCTAssertEqual(result.availability.kind, .waitingLearning)
        XCTAssertEqual(result.availability.learningDueAt, due)
        XCTAssertEqual(result.availability.nextAvailableAt, now.addingTimeInterval(600))
        XCTAssertTrue(result.availability.detail.contains("提前 20 分钟"))
        XCTAssertEqual(try summary(db, at: now.addingTimeInterval(600)).pending.learning, 1)
        XCTAssertEqual(try summary(db, at: now.addingTimeInterval(600)).availability.kind, .ready)
    }

    func testRepeatedLearningCardIsPendingEvenAfterAlreadyStudied() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "重来", due: now))
        _ = try db.answer(card, .again, now: now)
        let result = try summary(db)
        XCTAssertEqual(result.studiedCards, 1)
        XCTAssertEqual(result.pending.learning, 1)
        XCTAssertEqual(result.availability.kind, .ready)
    }

    func testDailyLimitDoesNotPretendCompletedAndResetsTomorrow() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try db.save(Card(deck: "限额", front: "已学", due: now))
        _ = try db.answer(first, .easy, now: now)
        _ = try db.save(Card(deck: "限额", front: "受限", due: now))
        let result = try summary(db, .deck("限额"), new: 1)
        XCTAssertEqual(result.pending.total, 0)
        XCTAssertEqual(result.availability.kind, .dailyLimit)
        XCTAssertEqual(result.availability.blockedNew, 1)
        XCTAssertEqual(result.availability.nextAvailableAt, day(1))
        XCTAssertEqual(try summary(db, .deck("限额"), new: 1, at: day(1)).pending.new, 1)
    }

    func testZeroQuotaDoesNotPromiseResetWillOpenLearning() throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(front: "上限为零"))
        let result = try summary(db, new: 0)
        XCTAssertEqual(result.availability.kind, .dailyLimit)
        XCTAssertNil(result.availability.nextAvailableAt)
        XCTAssertTrue(result.availability.detail.contains("每日上限为 0"))
    }

    func testReviewQuotaAndLearningWaitReportBothReasons() throws {
        let db = try AppDatabase(DatabaseQueue())
        let reviewed = try db.save(Card(deck: "限额", front: "已复习", state: .review, interval: 5, due: day(-1)))
        _ = try db.answer(reviewed, .good, now: now)
        _ = try db.save(Card(deck: "限额", front: "复习受限", state: .review, due: day(0)))
        _ = try db.save(Card(deck: "限额", front: "稍后学习", state: .learning,
                             due: now.addingTimeInterval(1_800)))
        let result = try summary(db, .deck("限额"), review: 1)
        XCTAssertEqual(result.availability.kind, .waitingLearning)
        XCTAssertEqual(result.availability.blockedReview, 1)
        XCTAssertEqual(result.availability.nextAvailableAt, now.addingTimeInterval(600))
        XCTAssertTrue(result.availability.detail.contains("到期复习卡受每日上限限制"))
        let eligible = try summary(db, .deck("限额"), review: 1, at: now.addingTimeInterval(600))
        XCTAssertEqual(eligible.pending.learning, 1, "学习步骤不占每日复习额度")
        XCTAssertEqual(eligible.availability.kind, .ready)
    }

    func testEmptySuspendedAndFutureScheduledStatesStayDistinct() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(try summary(db).availability.kind, .noCards)
        var card = try db.save(Card(front: "暂停", isSuspended: true))
        XCTAssertEqual(try summary(db).availability.kind, .allSuspended)
        card.isSuspended = false
        card.state = .review
        card.due = day(3).addingTimeInterval(3_600)
        _ = try db.save(card)
        let scheduled = try summary(db)
        XCTAssertEqual(scheduled.availability.kind, .scheduled)
        XCTAssertEqual(scheduled.availability.nextAvailableAt, day(3), "复习卡到期当天即可学习")
        _ = try db.answer(card, .easy, now: now)
        XCTAssertEqual(try summary(db).availability.kind, .complete)
    }
}
