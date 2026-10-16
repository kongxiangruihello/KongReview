import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V245HighlightPagingTests: XCTestCase {
    func testFavoritesAndTrashUsePagesWithoutChangingSourceOrTagLists() {
        XCTAssertTrue(HighlightFilter().usesPagination)
        XCTAssertTrue(HighlightFilter(favoritesOnly: true).usesPagination)
        XCTAssertTrue(HighlightFilter(unsortedOnly: true).usesPagination)
        XCTAssertTrue(HighlightFilter(deletedOnly: true).usesPagination)
        XCTAssertFalse(HighlightFilter(sourceId: 1).usesPagination)
        XCTAssertFalse(HighlightFilter(tag: "专题").usesPagination)
        XCTAssertFalse(HighlightFilter(masteryOnly: true).usesPagination)
    }

    func testAll451FavoritesAndTrashRecordsAreReachableWithoutDuplicates() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let favorites = (0..<451).map {
            Highlight(text: "收藏摘录第\($0)条", isFavorite: true, createdAt: timestamp)
        }
        let trash = (0..<451).map {
            Highlight(text: "回收站摘录第\($0)条", isFavorite: true,
                      createdAt: timestamp, deletedAt: timestamp)
        }
        try db.save(favorites + trash + [Highlight(text: "普通摘录")])

        for query in [HighlightQuery(favoritesOnly: true), HighlightQuery(deletedOnly: true)] {
            let expected = try db.highlights(query).compactMap(\.id)
            XCTAssertEqual(expected.count, 451)
            var loaded: [Int64] = []
            var sizes: [Int] = []
            for offset in stride(from: 0, to: 451, by: ListState.pageSize) {
                let page = try await db.highlightPage(query, limit: ListState.pageSize, offset: offset)
                XCTAssertEqual(page.total, 451)
                sizes.append(page.items.count)
                loaded += page.items.compactMap(\.id)
            }
            XCTAssertEqual(sizes, [200, 200, 51])
            XCTAssertEqual(loaded, expected, "相同时间的条目也必须有稳定分页顺序")
            XCTAssertEqual(Set(loaded).count, 451)
        }
    }

    @MainActor
    func testUnfavoriteAndRestoreUpdateCountsWhenLastPageBecomesEmpty() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save((0..<201).map { Highlight(text: "收藏\($0)", isFavorite: true) }
            + (0..<201).map { Highlight(text: "已删除\($0)", deletedAt: Date()) })
        let store = LibraryStore(db: db)
        let favoriteQuery = HighlightQuery(favoritesOnly: true)
        let trashQuery = HighlightQuery(deletedOnly: true)
        let favoriteLastPage = try await db.highlightPage(favoriteQuery, limit: 200, offset: 200)
        let trashLastPage = try await db.highlightPage(trashQuery, limit: 200, offset: 200)
        var favorite = try XCTUnwrap(favoriteLastPage.items.first)
        store.list.total = favoriteLastPage.total
        XCTAssertEqual(store.list.pageCount, 2)
        favorite.isFavorite = false
        store.save(favorite)
        store.restore(try XCTUnwrap(trashLastPage.items.first))

        for query in [favoriteQuery, trashQuery] {
            let emptied = try await db.highlightPage(query, limit: 200, offset: 200)
            XCTAssertEqual(emptied.total, 200)
            XCTAssertTrue(emptied.items.isEmpty)
            store.list.total = emptied.total
            XCTAssertEqual(store.list.pageCount, 1)
            let remaining = try await db.highlightPage(query, limit: 200, offset: 0)
            XCTAssertEqual(remaining.items.count, 200)
        }
        XCTAssertEqual(store.trashCount, 200)
        XCTAssertNil(store.errorMessage)
    }

    func testFavoriteSearchKeepsSourceTagsDatesAndDeletedStateFilters() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "选定出处"))
        let other = try db.save(Source(title: "其他出处"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let wanted = Highlight(sourceId: source.id, text: "分页检索目标", tags: ["专题"],
                               isFavorite: true, createdAt: date)
        var nonFavorite = wanted
        nonFavorite.isFavorite = false
        var otherSource = wanted
        otherSource.sourceId = other.id
        var otherTag = wanted
        otherTag.tags = ["另一专题"]
        var otherDate = wanted
        otherDate.createdAt = date.addingTimeInterval(-86_400 * 3)
        var deleted = wanted
        deleted.deletedAt = date
        try db.save([wanted, nonFavorite, otherSource, otherTag, otherDate, deleted])
        let query = HighlightQuery(text: "分页检索", sourceId: source.id, favoritesOnly: true,
                                   tags: ["专题"], dateFrom: date, dateTo: date)
        let page = try await db.highlightPage(query, limit: 200, offset: 0)
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.map(\.text), [wanted.text])
        XCTAssertEqual(page.items.first?.sourceId, source.id)
    }

    @MainActor
    func testEmptyTrashClearsAllPagesAndSearchResultsButKeepsActiveHighlights() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save((0..<451).map {
            Highlight(text: $0 == 0 ? "唯一搜索结果" : "其他删除摘录\($0)", deletedAt: Date())
        })
        let active = try db.save(Highlight(text: "仍在使用的摘录"))
        let store = LibraryStore(db: db)
        let searched = try await db.highlightPage(HighlightQuery(text: "唯一搜索结果", deletedOnly: true),
                                                  limit: 200, offset: 0)
        store.list.items = searched.items
        store.list.total = searched.total
        XCTAssertEqual(store.list.total, 1)
        XCTAssertEqual(store.trashCount, 451, "清空确认必须使用全库回收站总数")
        store.emptyTrash()
        XCTAssertEqual(try db.trashCount(), 0)
        XCTAssertEqual(store.trashCount, 0)
        XCTAssertEqual(try db.highlights().compactMap(\.id), [active.id!])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testFavoriteAndTrashPageEditingRetainsEntireOriginal() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = String(repeating: "分页中的长原文不能被预览截断。", count: 1000)
        try db.save([Highlight(text: original, translation: "完整译文", note: "完整按语", isFavorite: true),
                     Highlight(text: original, translation: "完整译文", note: "完整按语", deletedAt: Date())])
        let store = LibraryStore(db: db)
        for query in [HighlightQuery(favoritesOnly: true), HighlightQuery(deletedOnly: true)] {
            let page = try await db.highlightPage(query, limit: 200, offset: 0)
            store.edit(try XCTUnwrap(page.items.first))
            XCTAssertEqual(store.editorDraft?.highlight.text, original)
            XCTAssertEqual(store.editorDraft?.highlight.translation, "完整译文")
            XCTAssertEqual(store.editorDraft?.highlight.note, "完整按语")
        }
    }
}
