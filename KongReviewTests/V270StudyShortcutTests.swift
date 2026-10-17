import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V270StudyShortcutTests: XCTestCase {
    func testRatingUndoLeavesSourceAndNotebookTextEditorsAlone() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let card = try db.save(Card(deck: "快捷键核对", front: "问题"))
            try db.save(DeckOptions(deck: card.deck, newPerDay: 5, reviewsPerDay: 20))
            let store = LibraryStore(db: db)
            store.selection = .cards
            store.startStudy(deck: card.deck)
            store.answerCurrent(.good)
            XCTAssertTrue(store.canUndoLastCardRating)
            let after = try db.card(id: card.id!)
            store.editingSource = Source(title: "正在输入出处")
            XCTAssertFalse(store.cardRatingShortcutIsAvailable)
            XCTAssertFalse(store.canUndoLastCardRating)
            store.undoLastCardRating()
            XCTAssertEqual(try db.card(id: card.id!), after)
            store.editingSource = nil
            store.newNotebookRequest = NewNotebookRequest()
            XCTAssertFalse(store.cardRatingShortcutIsAvailable)
            store.undoLastCardRating()
            XCTAssertEqual(try db.card(id: card.id!), after)
            store.newNotebookRequest = nil
            XCTAssertTrue(store.canUndoLastCardRating)
            store.undoLastCardRating()
            XCTAssertEqual(store.study.current?.id, card.id)
            XCTAssertEqual(store.globalCardLearningSummary?.ratingCount, 0)
        }
    }
}
