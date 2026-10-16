import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V243NavigationTests: XCTestCase {
    func testCardsHomeLeavesStudyWithoutChangingStoredCard() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(deck: "旧牌组", front: "问题", back: "答案"))
            let storedCard = try db.card(id: card.id!)
            let store = LibraryStore(db: db)
            store.startStudy(deck: card.deck)
            store.study.showingAnswer = true
            store.study.notebookId = 42
            store.selection = .home

            store.openCardsHome()

            XCTAssertEqual(store.selection, .cards)
            XCTAssertNil(store.study.deck)
            XCTAssertNil(store.study.browsingDeck)
            XCTAssertNil(store.study.notebookId)
            XCTAssertNil(store.study.current)
            XCTAssertFalse(store.study.showingAnswer)
            XCTAssertFalse(store.study.finished)
            XCTAssertEqual(store.study.lastDeck, card.deck)
            XCTAssertEqual(try db.card(id: card.id!), storedCard)
            XCTAssertEqual(store.dueCardCount(), 1)
        }
    }

    func testCardsHomeLeavesPagedBrowserAndInvalidatesPendingRequest() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(deck: "浏览牌组", front: "问题"))
            let store = LibraryStore(db: db)
            store.study.openCardBrowser(card.deck)
            store.study.browseItems = [card]
            store.study.browseSelection = [card.id!]
            store.study.browseQuery = "问题"
            store.study.browseTotal = 401
            store.study.browsePage = 3
            store.study.browsePageInput = "3"
            store.study.browseIsLoading = true
            let previousRequest = store.study.browseLoadID

            store.openCardsHome()

            XCTAssertEqual(store.selection, .cards)
            XCTAssertNil(store.study.deck)
            XCTAssertNil(store.study.browsingDeck)
            XCTAssertNotEqual(store.study.browseLoadID, previousRequest)
            XCTAssertFalse(store.study.browseIsLoading)
            XCTAssertTrue(store.study.browseItems.isEmpty)
            XCTAssertTrue(store.study.browseSelection.isEmpty)
            XCTAssertEqual(store.study.browsePage, 1)
            XCTAssertEqual(store.study.browseTotal, 0)

            store.study.openCardBrowser(card.deck)
            XCTAssertEqual(store.study.browsingDeck, card.deck)
            XCTAssertEqual(store.study.browseQuery, "")
            XCTAssertEqual(store.study.browsePage, 1)
        }
    }
}
