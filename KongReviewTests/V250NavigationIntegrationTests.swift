import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V250NavigationIntegrationTests: XCTestCase {
    func testArticleAnchorSurvivesRestartAndQueryChangeClearsIt() throws {
        try MainActor.assumeIsolated {
            let suite = "KongReview.article-anchor." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = ArticleListState(persistence: ListPositionPersistence(defaults: defaults))
            state.total = 451
            state.goToPage(2)
            var article = Article(url: "https://example.com/a", title: "返回位置", contentHTML: "正文", contentText: "正文", wordCount: 2)
            article.id = 42
            state.items = [article]
            state.rememberArticle(article.id)
            let restarted = ArticleListState(persistence: ListPositionPersistence(defaults: defaults))
            XCTAssertEqual(restarted.page, 2)
            XCTAssertEqual(restarted.anchorID, 42)
            restarted.query = "新查询"
            XCTAssertEqual(restarted.page, 1)
            XCTAssertNil(restarted.anchorID)
        }
    }

    func testReturningToCardsHomeDoesNotOverwriteRememberedDeckQueryOrPage() throws {
        try MainActor.assumeIsolated {
            let suite = "KongReview.deck-return." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db, positionDefaults: defaults)
            store.study.openCardBrowser("位置记忆牌组")
            store.study.browseQuery = "保留搜索"
            store.study.changeBrowsePageSize(50)
            store.study.browsePage = 3
            store.openCardsHome()
            XCTAssertNil(store.study.browseOwnerDeck)
            XCTAssertFalse(store.study.browseIsLoading)
            store.study.openCardBrowser("位置记忆牌组")
            XCTAssertEqual(store.study.browseQuery, "保留搜索")
            XCTAssertEqual(store.study.browsePage, 3)
            XCTAssertEqual(store.study.browsePageSize, 50)
        }
    }
}
