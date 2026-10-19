import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V245ArticlePagingTests: XCTestCase {
    private func article(_ index: Int, title: String? = nil, author: String? = nil, site: String? = nil) -> Article {
        Article(url: "https://example.com/article/\(index)", title: title ?? "文章\(index)", author: author,
                siteName: site, contentHTML: "<p>第\(index)篇完整正文</p>", contentText: "第\(index)篇完整正文",
                wordCount: 1000, savedAt: Date(timeIntervalSince1970: Double(1000 + index / 7)))
    }

    func testAll451ArticlesAreReachableWithStableOrderAndMetadataOnly() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var saved: [Article] = []
        for index in 0..<451 { saved.append(try db.saveArticle(article(index))) }
        let expected = saved.sorted {
            $0.savedAt == $1.savedAt ? $0.id! > $1.id! : $0.savedAt > $1.savedAt
        }
        var loaded: [Article] = []
        for page in 1...3 {
            let result = try await db.articlePage(query: "", page: page)
            XCTAssertEqual(result.total, 451)
            XCTAssertEqual(result.page, page)
            XCTAssertEqual(result.items.count, page < 3 ? 200 : 51)
            XCTAssertTrue(result.items.allSatisfy { $0.contentHTML.isEmpty && $0.contentText.isEmpty })
            loaded += result.items
        }
        XCTAssertEqual(loaded.compactMap(\.id), expected.compactMap(\.id))
        XCTAssertEqual(Set(loaded.compactMap(\.id)).count, 451)
    }

    func testSearchMatchesTitleWebsiteAuthorAndTreatsWildcardsLiterally() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let title = try db.saveArticle(article(1, title: "历史研究 50%"))
        let site = try db.saveArticle(article(2, site: "历史网站"))
        let author = try db.saveArticle(article(3, author: "历史作者 a_b"))
        try db.saveArticle(article(4, title: "无关 500", author: "axb"))

        let result = try await db.articlePage(query: "  历史\n", page: 1, pageSize: 2)
        let second = try await db.articlePage(query: "历史", page: 2, pageSize: 2)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(Set((result.items + second.items).compactMap(\.id)), Set([title.id!, site.id!, author.id!]))
        let percent = try await db.articlePage(query: "%", page: 1)
        XCTAssertEqual(percent.items.compactMap(\.id), [title.id!])
        let underscore = try await db.articlePage(query: "_", page: 1)
        XCTAssertEqual(underscore.items.compactMap(\.id), [author.id!])
        let missing = try await db.articlePage(query: "未匹配", page: 90)
        XCTAssertEqual(missing.total, 0)
        XCTAssertEqual(missing.page, 1)
        XCTAssertTrue(missing.items.isEmpty)
    }

    func testDeletingLastPageReturnsPreviousValidPageInSameSnapshot() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for index in 0..<201 { try db.saveArticle(article(index)) }
        let last = try await db.articlePage(query: "", page: 2)
        XCTAssertEqual(last.items.count, 1)
        try db.deleteArticle(id: XCTUnwrap(last.items.first?.id))
        let previous = try await db.articlePage(query: "", page: 2)
        XCTAssertEqual(previous.total, 200)
        XCTAssertEqual(previous.page, 1)
        XCTAssertEqual(previous.items.count, 200)
        let first = try await db.articlePage(query: "", page: -20)
        XCTAssertEqual(first.page, 1)
    }

    func testPageCountsOnlyHighlightsOfVisibleArticlesAndReaderGetsFullBody() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let older = try db.saveArticle(article(1))
        let newer = try db.saveArticle(article(20))
        try db.save(Highlight(sourceId: newer.sourceId, text: "当前页摘录"))
        try db.save(Highlight(sourceId: newer.sourceId, text: "已删除摘录", deletedAt: Date()))
        try db.save(Highlight(sourceId: older.sourceId, text: "其他页摘录"))
        let page = try await db.articlePage(query: "", page: 1, pageSize: 1)
        XCTAssertEqual(page.items.first?.id, newer.id)
        XCTAssertEqual(page.highlightCounts, [newer.id!: 1])
        XCTAssertEqual(page.items.first?.contentHTML, "")
        try await MainActor.run {
            let store = LibraryStore(db: db)
            store.open(try XCTUnwrap(page.items.first))
            XCTAssertEqual(store.openArticle?.contentHTML, newer.contentHTML)
            XCTAssertEqual(store.openArticle?.contentText, newer.contentText)
            XCTAssertEqual(store.selection, .articles)
        }
        XCTAssertEqual(try db.article(id: newer.id!)?.contentHTML, newer.contentHTML)
    }

    @MainActor
    func testSearchResetsPageAndRejectsOlderRequests() {
        let suite = "V245ArticlePagingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ArticleListState(persistence: ListPositionPersistence(defaults: defaults))
        state.total = 451
        state.page = 3
        state.pageInput = "3"
        let oldRequest = state.loadID
        state.query = "新搜索"
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.pageInput, "1")
        XCTAssertFalse(state.apply(ArticlePage(items: [article(1)], total: 451, page: 3, highlightCounts: [:]),
                                   requestID: oldRequest, query: "", page: 3))
        XCTAssertTrue(state.items.isEmpty)
        let newRequest = state.loadID
        XCTAssertTrue(state.apply(ArticlePage(items: [article(2)], total: 1, page: 1, highlightCounts: [:]),
                                  requestID: newRequest, query: "新搜索", page: 1))
        XCTAssertEqual(state.items.first?.title, "文章2")
        state.total = 451
        state.goToPage(999)
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(state.pageInput, "3")
        XCTAssertFalse(state.apply(ArticlePage(items: [article(3)], total: 1, page: 1, highlightCounts: [:]),
                                   requestID: newRequest, query: "新搜索", page: 1))
    }
}
