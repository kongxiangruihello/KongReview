import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V250ListPositionTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "KongReview.ListPositionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testMenusRestoreTheirOwnSearchFiltersPageSizeAndAnchorAfterRestart() throws {
        let defaults = try defaults()
        let state = ListState(defaults: defaults)
        let keys = ["highlights.all", "highlights.unsorted", "highlights.favorites", "highlights.trash"]
        for (index, key) in keys.enumerated() {
            state.activate(key: key)
            XCTAssertEqual(state.query, "", "新菜单不能带入其他菜单的搜索词")
            state.query = "检索\(index)"
            state.extra = ListFilter(sourceId: Int64(index + 1), tags: ["专题\(index)"])
            state.showFilters = true
            state.changePageSize(index.isMultiple(of: 2) ? 50 : 100)
            state.page = index + 2
            state.items = [Highlight(id: Int64(index + 10), text: "摘录")]
            state.selection = [Int64(index + 10)]
        }
        let reopened = ListState(defaults: defaults)
        for (index, key) in keys.enumerated() {
            reopened.activate(key: key)
            XCTAssertEqual(reopened.query, "检索\(index)")
            XCTAssertEqual(reopened.extra.sourceId, Int64(index + 1))
            XCTAssertEqual(reopened.extra.tags, ["专题\(index)"])
            XCTAssertEqual(reopened.page, index + 2)
            XCTAssertEqual(reopened.pageInput, String(index + 2))
            XCTAssertEqual(reopened.pageSize, index.isMultiple(of: 2) ? 50 : 100)
            XCTAssertEqual(reopened.anchorID, Int64(index + 10))
            XCTAssertTrue(reopened.selection.isEmpty, "恢复定位不恢复批量操作选择")
            XCTAssertNil(reopened.lastQuery, "首次查询应保留恢复页码")
        }
    }

    @MainActor
    func testSourcePagesRememberSortAndSavedSearchInitialCriteriaOnlyApplyOnce() throws {
        let defaults = try defaults()
        let state = ListState(defaults: defaults)
        state.activate(key: "highlights.source.11")
        state.sourceByPage = false
        state.query = "书甲"
        state.limit = 600
        state.activate(key: "highlights.source.22")
        XCTAssertTrue(state.sourceByPage)
        XCTAssertEqual(state.query, "")
        state.activate(key: "highlights.source.11")
        XCTAssertFalse(state.sourceByPage)
        XCTAssertEqual(state.query, "书甲")
        XCTAssertEqual(state.limit, 600)

        let initial = HighlightListPosition(query: "已存关键词", extra: ListFilter(tags: ["历史"]), showFilters: true)
        state.activate(key: "highlights.saved.fixed-id", initial: initial)
        XCTAssertEqual(state.query, "已存关键词")
        state.query = "继续细查"
        state.page = 3
        state.activate(key: "highlights.all")
        state.activate(key: "highlights.saved.fixed-id", initial: initial)
        XCTAssertEqual(state.query, "继续细查")
        XCTAssertEqual(state.page, 3)
    }

    @MainActor
    func testChangingCriteriaOrPageSizeInvalidatesOldPageAndBatchSelection() throws {
        let state = ListState(defaults: try defaults())
        state.activate(key: "highlights.all")
        state.total = 251
        state.page = 2
        state.items = [Highlight(id: 8, text: "当前页")]
        state.selection = [8]
        let loadID = state.loadID
        state.changePageSize(50)
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.pageCount, 6)
        XCTAssertEqual(state.limit, 50)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertNil(state.anchorID)
        XCTAssertNotEqual(state.loadID, loadID)
        state.page = 4
        state.query = "新检索"
        XCTAssertEqual(state.page, 1)
        state.page = 3
        state.extra.tags = ["新筛选"]
        XCTAssertEqual(state.page, 1)
    }

    @MainActor
    func testCardDecksRestorePositionsIndependentlyAndCleanupDoesNotOverwriteThem() throws {
        let defaults = try defaults()
        let state = StudyState(defaults: defaults)
        state.openCardBrowser("甲")
        state.browseQuery = "甲关键词"
        state.changeBrowsePageSize(50)
        state.browsePage = 4
        state.browseItems = [Card(id: 9, deck: "甲", front: "问题")]
        state.rememberBrowsingCard(9)
        state.browseSelection = [9]
        state.openCardBrowser("乙")
        XCTAssertEqual(state.browseQuery, "")
        XCTAssertEqual(state.browsePage, 1)
        XCTAssertEqual(state.browsePageSize, 200)
        state.browseQuery = "乙关键词"
        state.changeBrowsePageSize(100)
        state.browsePage = 2
        state.clearBrowsePositionOwner()
        state.browseQuery = ""
        state.browsePage = 1

        let reopened = StudyState(defaults: defaults)
        reopened.openCardBrowser("甲")
        XCTAssertEqual(reopened.browseQuery, "甲关键词")
        XCTAssertEqual(reopened.browsePage, 4)
        XCTAssertEqual(reopened.browsePageInput, "4")
        XCTAssertEqual(reopened.browsePageSize, 50)
        XCTAssertEqual(reopened.browseAnchorID, 9)
        XCTAssertEqual(reopened.browseOwnerDeck, "甲")
        XCTAssertEqual(reopened.browseLoadedQuery, "甲关键词")
        XCTAssertTrue(reopened.browseSelection.isEmpty)
        reopened.openCardBrowser("乙")
        XCTAssertEqual(reopened.browseQuery, "乙关键词")
        XCTAssertEqual(reopened.browsePage, 2)
        XCTAssertEqual(reopened.browsePageSize, 100)
    }

    @MainActor
    func testCardSearchAndPageSizeResetPageWithoutChangingStudyProgress() throws {
        let state = StudyState(defaults: try defaults())
        state.lastDeck = "上次学习牌组"
        state.current = Card(id: 3, deck: "学习中", front: "学习题")
        state.openCardBrowser("浏览牌组")
        state.browseTotal = 251
        state.browsePage = 4
        state.browseItems = [Card(id: 9, deck: "浏览牌组", front: "问题")]
        state.browseSelection = [9]
        let loadID = state.browseLoadID
        state.changeBrowsePageSize(100)
        XCTAssertEqual(state.browsePageCount, 3)
        XCTAssertEqual(state.browsePage, 1)
        XCTAssertTrue(state.browseSelection.isEmpty)
        XCTAssertTrue(state.browseItems.isEmpty)
        XCTAssertNotEqual(state.browseLoadID, loadID)
        state.browsePage = 2
        state.browseQuery = "搜索"
        XCTAssertEqual(state.browsePage, 1)
        XCTAssertEqual(state.current?.id, 3)
        XCTAssertEqual(state.lastDeck, "上次学习牌组")
    }

    @MainActor
    func testSourceManagerRestoresFullSortCriteriaWithoutRestoringBatchSelection() throws {
        let defaults = try defaults()
        let state = SourceManagerState(defaults: defaults)
        state.activate()
        state.filter = "历史"
        state.onlyDuplicates = true
        let sorts = [SourcePageSort(.title), SourcePageSort(.createdAt, descending: true)]
        state.sortOrder = sorts.map(\.comparator)
        state.changePageSize(50)
        state.page = 3
        state.selection = [19]
        let reopened = SourceManagerState(defaults: defaults)
        XCTAssertEqual(reopened.filter, "历史")
        XCTAssertTrue(reopened.onlyDuplicates)
        XCTAssertEqual(reopened.sortOrder.compactMap(SourcePageSort.init), sorts)
        XCTAssertEqual(reopened.page, 3)
        XCTAssertEqual(reopened.pageInput, "3")
        XCTAssertEqual(reopened.pageSize, 50)
        XCTAssertEqual(reopened.anchorID, 19)
        XCTAssertTrue(reopened.selection.isEmpty)
        XCTAssertEqual(reopened.loadedCriteria?.query, "历史")
        XCTAssertEqual(reopened.loadedCriteria?.sorts, sorts)
        reopened.activate()
        reopened.filter = "另一检索"
        XCTAssertEqual(reopened.page, 1)
        XCTAssertNil(reopened.anchorID)
    }

    @MainActor
    func testInvalidSavedPageSizeAndPageAreNormalized() throws {
        let defaults = try defaults()
        let persistence = ListPositionPersistence(defaults: defaults)
        persistence.save(HighlightListPosition(page: -5, pageSize: 0), for: "highlights.all")
        persistence.save(CardBrowsePosition(page: -1, pageSize: 77), for: "cards.deck.甲")
        persistence.save(SourceManagerPosition(page: -9, pageSize: 300), for: "sources.manager")
        let list = ListState(defaults: defaults)
        list.activate(key: "highlights.all")
        XCTAssertEqual(list.page, 1)
        XCTAssertEqual(list.pageSize, 200)
        let cards = StudyState(defaults: defaults)
        cards.openCardBrowser("甲")
        XCTAssertEqual(cards.browsePage, 1)
        XCTAssertEqual(cards.browsePageSize, 200)
        let sources = SourceManagerState(defaults: defaults)
        XCTAssertEqual(sources.page, 1)
        XCTAssertEqual(sources.pageSize, 200)
    }

    func testAllRecordsRemainReachableAtEveryOfferedPageSize() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save((0..<251).map { Highlight(text: "摘录\($0)") })
        for index in 0..<251 { try db.save(Card(deck: "分页", front: "卡片\(index)")) }
        for size in [50, 100, 200] {
            var highlights: [Int64] = []
            var cards: [Int64] = []
            for offset in stride(from: 0, to: 251, by: size) {
                let h = try await db.highlightPage(HighlightQuery(), limit: size, offset: offset)
                let c = try await db.cardPage(deck: "分页", query: "", limit: size, offset: offset)
                XCTAssertEqual(h.total, 251)
                XCTAssertEqual(c.total, 251)
                highlights += h.items.compactMap(\.id)
                cards += c.items.compactMap(\.id)
            }
            XCTAssertEqual(highlights.count, 251)
            XCTAssertEqual(Set(highlights).count, 251)
            XCTAssertEqual(cards.count, 251)
            XCTAssertEqual(Set(cards).count, 251)
        }
    }
}
