import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V241NavigationTests: XCTestCase {
    @MainActor
    private func withIsolatedSession(_ work: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = ReviewSessionRecord.key(theme: nil)
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        try work()
    }

    func testTodayEntryLeavesEveryScopeAndKeepsUnfinishedProgress() throws {
        try MainActor.assumeIsolated {
            try withIsolatedSession {
                let db = try AppDatabase(DatabaseQueue())
                let first = try db.save(Highlight(text: "第一条"))
                let second = try db.save(Highlight(text: "第二条"))
                let record = ReviewSessionRecord(day: ReminderPlan.dayKey(Date()),
                    regularIds: [first.id!, second.id!], masteryIds: [], position: 1)
                let key = ReviewSessionRecord.key(theme: nil)
                record.save(key: key)
                let original = UserDefaults.standard.data(forKey: key)
                let store = LibraryStore(db: db)
                for theme in ["儒家", ReviewScope.notebook(1), ReviewScope.source(1),
                              ReviewScope.chapter(1, "学而"), ReviewScope.stale] {
                    store.selection = .review
                    store.review.theme = theme
                    store.review.noteDraft = "尚未保存的批注"
                    store.review.inlineDraft = InlineEditDraft(id: first.id, text: "编辑中", translation: "", note: "")
                    let token = store.review.sessionToken
                    store.openTodayReview()
                    XCTAssertNil(store.review.theme)
                    XCTAssertNil(store.review.noteDraft)
                    XCTAssertNil(store.review.inlineDraft)
                    XCTAssertEqual(store.selection, .review)
                    XCTAssertEqual(store.review.sessionToken, token + 1)
                    XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
                    XCTAssertEqual(store.todayCounts().highlights, 1)
                    XCTAssertFalse(store.todayReviewIsComplete)
                }
            }
        }
    }

    func testCompletedTodayEntryStaysCompletedAndDoesNotRestart() throws {
        try MainActor.assumeIsolated {
            try withIsolatedSession {
                let db = try AppDatabase(DatabaseQueue())
                let highlight = try db.save(Highlight(text: "已经回顾过"))
                let key = ReviewSessionRecord.key(theme: nil)
                ReviewSessionRecord(day: ReminderPlan.dayKey(Date()), regularIds: [highlight.id!],
                                    masteryIds: [], position: 1).save(key: key)
                let original = UserDefaults.standard.data(forKey: key)
                let store = LibraryStore(db: db)
                store.selection = .home
                for _ in 0..<3 {
                    store.openTodayReview()
                    XCTAssertEqual(store.selection, .review)
                    XCTAssertTrue(store.todayReviewIsComplete)
                    XCTAssertEqual(store.todayCounts().highlights, 0)
                    XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
                }
            }
        }
    }

    func testYesterdayDoesNotMarkTodayComplete() throws {
        try MainActor.assumeIsolated {
            try withIsolatedSession {
                let db = try AppDatabase(DatabaseQueue())
                let highlight = try db.save(Highlight(text: "新一天的摘录"))
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                ReviewSessionRecord(day: ReminderPlan.dayKey(yesterday), regularIds: [highlight.id!],
                                    masteryIds: [], position: 1).save(key: ReviewSessionRecord.key(theme: nil))
                let store = LibraryStore(db: db)
                store.today = ReminderPlan.dayKey(yesterday)
                store.openTodayReview()
                XCTAssertEqual(store.today, ReminderPlan.dayKey(Date()))
                XCTAssertFalse(store.todayReviewIsComplete)
                XCTAssertEqual(store.todayCounts().highlights, 1)
            }
        }
    }

    func testHomeQuoteIsStableAndDoesNotCreateOrChangeTheReviewSession() throws {
        try MainActor.assumeIsolated {
            try withIsolatedSession {
                let db = try AppDatabase(DatabaseQueue())
                let source = try db.save(Source(title: "论语", author: "孔子"))
                let first = try db.save(Highlight(sourceId: source.id, text: "学而时习之"))
                let favorite = try db.save(Highlight(sourceId: source.id, text: "温故而知新", isFavorite: true))
                let store = LibraryStore(db: db)
                XCTAssertEqual(store.dailyReviewQuote()?.text, store.dailyReviewQuote()?.text)
                let key = ReviewSessionRecord.key(theme: nil)
                XCTAssertNil(UserDefaults.standard.data(forKey: key))
                ReviewSessionRecord(day: ReminderPlan.dayKey(Date()), regularIds: [first.id!, favorite.id!],
                                    masteryIds: [], position: 1).save(key: key)
                let original = UserDefaults.standard.data(forKey: key)
                XCTAssertEqual(store.dailyReviewQuote()?.text, "温故而知新")
                XCTAssertEqual(store.dailyReviewQuote()?.source, "孔子《论语》")
                XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
                XCTAssertNil(store.review.theme)
            }
        }
    }

    func testSuggestedStudyDirectlyEntersPendingDeck() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(deck: "今日牌组", front: "问题", back: "答案"))
            let store = LibraryStore(db: db)
            store.study.lastDeck = "没有待学卡的旧牌组"
            store.startSuggestedStudy()
            XCTAssertEqual(store.selection, .cards)
            XCTAssertEqual(store.study.deck, "今日牌组")
            XCTAssertEqual(store.study.current?.id, card.id)
        }
    }
}
