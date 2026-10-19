import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class DerivedLibraryTests: XCTestCase {
    func testCombinedSnapshotMatchesIndependentSummariesAcrossDecks() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = Date()
        for index in 0..<30 {
            let deck = "牌组\(index)"
            let card = try db.save(Card(deck: deck, front: String(repeating: "长正文", count: 1000), back: "答案\(index)", due: now))
            _ = try db.save(Card(deck: deck, front: "复习\(index)", state: .review, due: now))
            _ = try db.save(Card(deck: deck, front: "暂停\(index)", isSuspended: true))
            if index % 2 == 0 { _ = try db.answer(card, .again, now: now) }
            try db.save(DeckOptions(deck: deck, newPerDay: 2, reviewsPerDay: 3))
        }
        for scope in [CardLearningScope.all, .deck("牌组0"), .deck("牌组1")] {
            let snapshot = try db.derivedLibrarySnapshot(.init(now: now, dailyReviewCount: 5,
                newPerDay: 20, reviewsPerDay: 200, scope: scope, session: nil))
            XCTAssertEqual(snapshot.globalCards, try db.cardLearningSummary(now: now, newPerDay: 20, reviewsPerDay: 200))
            XCTAssertEqual(snapshot.scopedCards, try db.cardLearningSummary(scope: scope, now: now, newPerDay: 20, reviewsPerDay: 200))
            XCTAssertEqual(snapshot.home, try db.homeLearningSummary(now: now, dailyReviewCount: 5,
                newCardsPerDay: 20, reviewsPerDay: 200, session: nil))
            XCTAssertEqual(snapshot.decks.count, 30)
        }
    }

    @MainActor
    func testBackgroundRefreshCoalescesAndInvalidationRejectsLateResult() async throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(front: "后台统计"))
        let gate = SnapshotGate()
        let store = LibraryStore(db: db, backgroundStatistics: true, derivedSnapshotLoader: { request in
            await gate.wait()
            return try db.derivedLibrarySnapshot(request)
        })
        let generation = store.derivedRefreshGeneration
        store.refreshDerivedLibrary()
        XCTAssertEqual(store.derivedRefreshGeneration, generation)
        XCTAssertTrue(store.derivedIsLoading)
        for _ in 0..<20 { await Task.yield() }
        store.invalidateDerivedStatistics()
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.derivedIsLoading)
        XCTAssertEqual(store.homeLearningSummary.activeCardCount, 0)
        store.derivedSnapshotLoader = { request in try db.derivedLibrarySnapshot(request) }
        store.refreshDerivedLibrary()
        await store.derivedRefreshTask?.value
        XCTAssertEqual(store.homeLearningSummary.activeCardCount, 1)
        XCTAssertNil(store.derivedStatisticsError)
    }
}

private actor SnapshotGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
