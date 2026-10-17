import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V270CardRatingUndoTests: XCTestCase {
    private var now: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600) }

    private func events(_ db: AppDatabase) throws -> [ReviewEvent] {
        try db.writer.read { db in try ReviewEvent.order(Column("id")).fetchAll(db) }
    }

    func testUndoRestoresEveryScheduleFieldForAllAnswersAndBothSchedulers() throws {
        let schedulers: [any CardScheduling] = [CardScheduler(), FSRS()]
        for scheduler in schedulers {
            for answer in CardAnswer.allCases {
                let db = try AppDatabase(DatabaseQueue())
                var card = Card(front: "问题", back: "答案", state: .review, interval: 12,
                                ease: 2.35, due: now.addingTimeInterval(-86_400), reps: 8, lapses: 2)
                card.stability = 10.25
                card.difficulty = 6.75
                card.lastReview = now.addingTimeInterval(-12 * 86_400)
                card.sections = [CardSection(name: "释义", text: "更多说明", folded: true)]
                let saved = try db.save(card)
                let before = try XCTUnwrap(db.card(id: saved.id!))
                let token = try db.answerRecordingUndo(saved, answer, scheduler: scheduler, now: now)
                XCTAssertNotEqual(token.after, before)
                XCTAssertEqual(token.after.reps, before.reps + 1)
                XCTAssertTrue(try db.canUndoCardRating(token))
                let restored = try db.undoCardRating(token)
                XCTAssertEqual(restored, before)
                XCTAssertEqual(try db.card(id: saved.id!), before)
                XCTAssertTrue(try events(db).isEmpty)
                XCTAssertFalse(try db.canUndoCardRating(token))
                XCTAssertThrowsError(try db.undoCardRating(token))
            }
        }
    }

    func testRepeatedRatingUndoKeepsEarlierRatingAndDoesNotInflateOrEraseUniqueCount() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "重复回答", due: now))
        let first = try db.answerRecordingUndo(card, .again, now: now)
        let second = try db.answerRecordingUndo(first.after, .good, now: now.addingTimeInterval(30))
        XCTAssertFalse(try db.canUndoCardRating(first))
        XCTAssertThrowsError(try db.undoCardRating(first))
        XCTAssertEqual(try events(db).count, 2)
        XCTAssertEqual(try db.studiedToday(now: now).new, 1)
        _ = try db.undoCardRating(second)
        XCTAssertEqual(try db.card(id: card.id!), first.after)
        XCTAssertEqual(try events(db).map(\.id), [first.event.id])
        XCTAssertEqual(try db.studiedToday(now: now).new, 1)
        XCTAssertEqual(try db.reviewSummary(now: now).today.cards, 1)
    }

    func testUndoRestoresDailyLimitAndStatsWithoutRemovingOtherEvents() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Card(deck: "甲", front: "甲一", due: now))
        _ = try db.save(Card(deck: "甲", front: "甲二", due: now))
        let b = try db.save(Card(deck: "乙", front: "乙一", due: now))
        let highlight = try db.save(Highlight(text: "摘录"))
        let token = try db.answerRecordingUndo(a, .easy, now: now)
        _ = try db.answer(b, .easy, now: now)
        db.log(ReviewEvent(kind: .keep, highlightId: highlight.id, at: now))
        let unrelatedIDs = try events(db).filter { $0.id != token.event.id }.map(\.id)
        let after = try db.deckSummaries(now: now, newPerDay: 1, reviewsPerDay: 200)
        XCTAssertEqual(after.first(where: { $0.name == "甲" })?.counts.new, 0)
        XCTAssertEqual(try db.studiedToday(deck: "甲", now: now).new, 1)
        _ = try db.undoCardRating(token)
        let restored = try db.deckSummaries(now: now, newPerDay: 1, reviewsPerDay: 200)
        XCTAssertEqual(restored.first(where: { $0.name == "甲" })?.counts.new, 1)
        XCTAssertEqual(try db.studiedToday(deck: "甲", now: now).new, 0)
        XCTAssertEqual(try db.studiedToday(deck: "乙", now: now).new, 1)
        XCTAssertEqual(try events(db).map(\.id), unrelatedIDs)
        XCTAssertEqual(try db.reviewSummary(now: now).today.cards, 1)
        XCTAssertEqual(try db.reviewSummary(now: now).today.highlights, 1)
    }

    func testEditedSuspendedMovedAndDeletedCardsRejectUndoWithoutChangingAnything() throws {
        let mutations: [(inout Card) -> Void] = [
            { $0.front = "修改后的正面" },
            { $0.back = "修改后的答案" },
            { $0.isSuspended = true },
            { $0.deck = "其他牌组" },
            { $0.deletedAt = Date() },
        ]
        for mutate in mutations {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(front: "原卡", due: now))
            let token = try db.answerRecordingUndo(card, .easy, now: now)
            var changed = token.after
            mutate(&changed)
            _ = try db.save(changed)
            let expected = try db.card(id: card.id!)
            XCTAssertFalse(try db.canUndoCardRating(token))
            XCTAssertThrowsError(try db.undoCardRating(token))
            XCTAssertEqual(try db.card(id: card.id!), expected)
            XCTAssertEqual(try events(db).map(\.id), [token.event.id])
        }
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "已删除", due: now))
        let token = try db.answerRecordingUndo(card, .easy, now: now)
        try db.deleteCards([card.id!])
        XCTAssertThrowsError(try db.undoCardRating(token))
        XCTAssertNil(try db.card(id: card.id!))
        XCTAssertEqual(try events(db).count, 1)
    }

    func testMissingOrChangedEventRejectsUndoEvenWhenCardStillMatches() throws {
        for remove in [false, true] {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(front: "日志保护", due: now))
            let token = try db.answerRecordingUndo(card, .easy, now: now)
            try db.writer.write { db in
                if remove { _ = try ReviewEvent.deleteOne(db, key: token.event.id) }
                else { try db.execute(sql: "UPDATE review_event SET answer = 1 WHERE id = ?", arguments: [token.event.id]) }
            }
            XCTAssertFalse(try db.canUndoCardRating(token))
            XCTAssertThrowsError(try db.undoCardRating(token))
            XCTAssertEqual(try db.card(id: card.id!), token.after)
        }
    }

    func testLaterLogForSameCardRejectsOlderTokenEvenWhenScheduleStillMatches() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "后续日志保护", due: now))
        let token = try db.answerRecordingUndo(card, .easy, now: now)
        db.log(ReviewEvent(kind: .card, cardId: card.id, answer: CardAnswer.good.rawValue,
                           at: now.addingTimeInterval(30)))
        XCTAssertFalse(try db.canUndoCardRating(token))
        XCTAssertThrowsError(try db.undoCardRating(token))
        XCTAssertEqual(try db.card(id: card.id!), token.after)
        XCTAssertEqual(try events(db).count, 2)
    }

    func testAnswerRejectsStaleOrDeletedInputAndEventFailureRollsBackSchedule() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "输入保护", due: now))
        var changed = card
        changed.front = "已更新"
        _ = try db.save(changed)
        XCTAssertThrowsError(try db.answerRecordingUndo(card, .easy, now: now))
        XCTAssertTrue(try events(db).isEmpty)
        let current = try XCTUnwrap(db.card(id: card.id!))
        try db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_rating BEFORE INSERT ON review_event BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        XCTAssertThrowsError(try db.answerRecordingUndo(current, .easy, now: now))
        XCTAssertEqual(try db.card(id: card.id!), current)
        XCTAssertTrue(try events(db).isEmpty)
        try db.deleteCards([card.id!])
        XCTAssertThrowsError(try db.answerRecordingUndo(current, .easy, now: now))
        XCTAssertThrowsError(try db.answerRecordingUndo(Card(front: "未保存"), .easy, now: now))
    }

    func testUndoEventFailureRollsBackRestoredCard() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "事务保护", due: now))
        let token = try db.answerRecordingUndo(card, .easy, now: now)
        try db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_rating_delete BEFORE DELETE ON review_event BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        XCTAssertThrowsError(try db.undoCardRating(token))
        XCTAssertEqual(try db.card(id: card.id!), token.after)
        XCTAssertEqual(try events(db).map(\.id), [token.event.id])
    }

    @MainActor func testStoreUndoReturnsPreviousCardWithAnswerAndRestoresDailyCounts() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(DeckOptions(deck: "学习", newPerDay: 20, reviewsPerDay: 200))
        let first = try db.save(Card(deck: "学习", front: "第一张"))
        _ = try db.save(Card(deck: "学习", front: "第二张"))
        let store = LibraryStore(db: db)
        store.selection = .cards
        store.startStudy(deck: "学习")
        XCTAssertEqual(store.study.current?.id, first.id)
        store.study.showingAnswer = true
        store.answerCurrent(.easy)
        XCTAssertNotEqual(store.study.current?.id, first.id)
        XCTAssertTrue(store.canUndoLastCardRating)
        XCTAssertEqual(try db.studiedToday(deck: "学习").new, 1)
        store.undoLastCardRating()
        XCTAssertEqual(store.study.current?.id, first.id)
        XCTAssertTrue(store.study.showingAnswer)
        XCTAssertFalse(store.study.finished)
        XCTAssertFalse(store.canUndoLastCardRating)
        XCTAssertNil(store.lastCardRating)
        XCTAssertEqual(try db.studiedToday(deck: "学习").new, 0)
        XCTAssertEqual(store.homeLearningSummary.cardsStudiedCount, 0)
        XCTAssertFalse(store.reviewedToday)
        XCTAssertTrue(try events(db).isEmpty)
    }

    @MainActor func testStoreFinishedPageCanUndoOnlyLatestRating() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(DeckOptions(deck: "学习", newPerDay: 20, reviewsPerDay: 200))
        let first = try db.save(Card(deck: "学习", front: "第一张"))
        let second = try db.save(Card(deck: "学习", front: "第二张"))
        let store = LibraryStore(db: db)
        store.selection = .cards
        store.startStudy(deck: "学习")
        store.study.showingAnswer = true
        store.answerCurrent(.easy)
        store.study.showingAnswer = true
        store.answerCurrent(.easy)
        XCTAssertNil(store.study.current)
        XCTAssertTrue(store.study.finished)
        XCTAssertTrue(store.canUndoLastCardRating)
        store.undoLastCardRating()
        XCTAssertEqual(store.study.current?.id, second.id)
        XCTAssertTrue(store.study.showingAnswer)
        XCTAssertFalse(store.study.finished)
        XCTAssertFalse(store.canUndoLastCardRating)
        XCTAssertEqual(try events(db).map(\.cardId), [first.id])
        store.undoLastCardRating()
        XCTAssertEqual(store.study.current?.id, second.id)
        XCTAssertEqual(try events(db).map(\.cardId), [first.id])
    }

    @MainActor func testStoreAnswerFailureKeepsCurrentCardAnswerAndQueuePosition() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(DeckOptions(deck: "学习", newPerDay: 20, reviewsPerDay: 200))
        _ = try db.save(Card(deck: "学习", front: "第一张"))
        _ = try db.save(Card(deck: "学习", front: "第二张"))
        let store = LibraryStore(db: db)
        store.selection = .cards
        store.startStudy(deck: "学习")
        store.study.showingAnswer = true
        let before = store.study.current
        let revision = store.revision
        try db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_rating BEFORE INSERT ON review_event BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        store.answerCurrent(.easy)
        XCTAssertEqual(store.study.current, before)
        XCTAssertTrue(store.study.showingAnswer)
        XCTAssertFalse(store.study.finished)
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.lastCardRating)
        XCTAssertFalse(store.canUndoLastCardRating)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(try events(db).isEmpty)
    }

    @MainActor func testStoreScopeChangesDisableUndoAndHomeClearsIt() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(DeckOptions(deck: "学习", newPerDay: 20, reviewsPerDay: 200))
        _ = try db.save(Card(deck: "学习", front: "第一张"))
        let store = LibraryStore(db: db)
        store.selection = .cards
        store.startStudy(deck: "学习")
        store.study.showingAnswer = true
        store.answerCurrent(.easy)
        XCTAssertTrue(store.canUndoLastCardRating)
        store.selection = .home
        XCTAssertFalse(store.canUndoLastCardRating)
        store.undoLastCardRating()
        XCTAssertEqual(try events(db).count, 1)
        store.selection = .cards
        store.study.deck = "其他牌组"
        XCTAssertFalse(store.canUndoLastCardRating)
        store.undoLastCardRating()
        XCTAssertEqual(try events(db).count, 1)
        store.openCardsHome()
        XCTAssertNil(store.lastCardRating)
        XCTAssertNil(store.lastCardRatingScope)
        XCTAssertFalse(store.canUndoLastCardRating)
    }

    @MainActor func testNotebookUndoRestoresBothScopedSummaryAndHeaderCounts() throws {
        let db = try AppDatabase(DatabaseQueue())
        let notebook = try db.createNotebook(title: "笔记本撤销")
        let highlight = try db.save(Highlight(text: "笔记本里的摘录"))
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight,
                                               highlightId: highlight.id)], into: notebook.id!, after: nil)
        // 学习中卡片不受新卡/复习每日额度影响，测试不依赖用户设置。
        let first = try db.save(Card(deck: "学习", front: "第一张", highlightId: highlight.id,
                                     state: .learning, due: Date().addingTimeInterval(-300), reps: 1))
        _ = try db.save(Card(deck: "学习", front: "第二张", highlightId: highlight.id,
                             state: .learning, due: Date().addingTimeInterval(-200), reps: 1))
        _ = try db.save(Card(deck: "学习", front: "第三张", highlightId: highlight.id,
                             state: .learning, due: Date().addingTimeInterval(-100), reps: 1))
        let store = LibraryStore(db: db)
        store.startNotebookStudy(notebook.id!)
        XCTAssertEqual(store.study.current?.id, first.id)
        XCTAssertEqual(store.study.notebookCounts.learning, 3)
        XCTAssertEqual(store.cardLearningSummary?.pending.learning, 3)
        store.study.showingAnswer = true
        store.answerCurrent(.easy)
        XCTAssertEqual(store.study.notebookCounts.learning, 2)
        XCTAssertEqual(store.cardLearningSummary?.pending.learning, 2)
        store.undoLastCardRating()
        XCTAssertEqual(store.study.current?.id, first.id)
        XCTAssertTrue(store.study.showingAnswer)
        XCTAssertEqual(store.study.notebookCounts.learning, 3)
        XCTAssertEqual(store.cardLearningSummary?.pending.learning, 3)
        XCTAssertEqual(store.homeLearningSummary.cardsLearningDueCount, 3)
        XCTAssertEqual(store.cardLearningSummary?.studiedCards, 0)
        XCTAssertEqual(store.cardLearningSummary?.ratingCount, 0)
    }
}
