import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class GlobalSearchTests: XCTestCase {
    private func section(_ pages: [GlobalSearchPage], _ kind: GlobalSearchKind) throws -> GlobalSearchPage {
        try XCTUnwrap(pages.first { $0.kind == kind })
    }

    func testSearchGroupsFourTypesAndKeepsSuspendedCardsButExcludesTrash() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "統一關鍵字", author: "作者"))
        let highlight = try db.save(Highlight(sourceId: source.id, text: "另一段原文", note: "统一关键字按语"))
        let card = try db.save(Card(deck: "甲", front: "另一张卡", back: "統一關鍵字答案", isSuspended: true))
        try db.save(Highlight(text: "统一关键字已删除", deletedAt: Date()))
        try db.save(Card(front: "统一关键字已删除", deletedAt: Date()))
        let article = try db.saveArticle(Article(url: "https://example.com/saved", title: "网页标题",
            contentHTML: "<p>統一關鍵字正文</p>", contentText: "統一關鍵字正文", wordCount: 7))
        let pages = try await db.globalSearch(query: "  统一关键字\n")
        XCTAssertEqual(pages.map(\.kind), GlobalSearchKind.allCases)
        XCTAssertEqual(try section(pages, .highlight).items.map(\.target.recordID), [highlight.id!])
        XCTAssertEqual(try section(pages, .card).items.map(\.target.recordID), [card.id!])
        XCTAssertEqual(try section(pages, .card).items.first?.badge, "已暂停")
        XCTAssertEqual(try section(pages, .article).items.map(\.target.recordID), [article.id!])
        XCTAssertEqual(try section(pages, .source).items.map(\.target.recordID), [source.id!])
        XCTAssertTrue(try section(pages, .highlight).items.first?.preview.contains("统一关键字按语") == true)
    }

    func testLiteralWildcardQuoteAndBackslashSearchAcrossTypes() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let literal = "50% a_b \\ '"
        let source = try db.save(Source(title: literal))
        let highlight = try db.save(Highlight(text: literal))
        let card = try db.save(Card(front: literal))
        let article = try db.saveArticle(Article(url: "https://example.com/literal", title: "网页",
            contentHTML: "<p>\(literal)</p>", contentText: literal, wordCount: 10))
        try db.save(Highlight(text: "500 axb"))
        try db.save(Card(front: "500 axb"))
        for term in ["%", "_", "\\", "'"] {
            let pages = try await db.globalSearch(query: term)
            XCTAssertEqual(try section(pages, .highlight).items.map(\.target.recordID), [highlight.id!])
            XCTAssertEqual(try section(pages, .card).items.map(\.target.recordID), [card.id!])
            XCTAssertEqual(try section(pages, .article).items.map(\.target.recordID), [article.id!])
            XCTAssertEqual(try section(pages, .source).items.map(\.target.recordID), [source.id!])
        }
    }

    func testHTMLAttributesDoNotMatchAndEncodedVisibleTextDoesMatch() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(front: "<div class='needle-attribute'>繁體 ＡＢＣ &amp; 50%</div>",
                                    back: "<b>正常答案</b>"))
        let falseHit = try await db.globalSearch(query: "needle-attribute", kind: .card)
        XCTAssertEqual(falseHit.first?.total, 0)
        let visible = try await db.globalSearch(query: "繁体 abc & 50%", kind: .card)
        XCTAssertEqual(visible.first?.items.first?.target.recordID, card.id)
        XCTAssertFalse(visible.first?.items.first?.title.contains("<") ?? true)
        XCTAssertTrue(visible.first?.items.first?.title.contains("&") == true)
    }

    func testCardTagsFieldsSectionsAndHighlightTranslationAreSearchable() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = Card(front: "主问题", back: "主答案", tags: ["标签中有_%\\"])
        card.fields = ["隐藏字段中的關鍵詞"]
        card.sections = [CardSection(name: "栏目名称", text: "栏目内容稀有词")]
        let saved = try db.save(card)
        for term in ["标签中有_%\\", "隐藏字段中的关键词", "栏目名称", "栏目内容稀有词"] {
            let pages = try await db.globalSearch(query: term, kind: .card)
            XCTAssertEqual(pages.first?.items.map(\.target.recordID), [saved.id!])
        }
        let item = try db.save(Highlight(text: "原文", translation: "译文独有詞"))
        let pages = try await db.globalSearch(query: "译文独有词", kind: .highlight)
        XCTAssertEqual(pages.first?.items.first?.target.recordID, item.id)
        XCTAssertTrue(pages.first?.items.first?.preview.contains("译文独有詞") == true)
    }

    func testLongArchivedBodyFindsLateMatchAndReturnsBoundedPlainPreview() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let body = String(repeating: "很长的开头。", count: 10_000) + "正文末尾独有关键词" + String(repeating: "结尾。", count: 500)
        let article = try db.saveArticle(Article(url: "https://example.com/long", title: "长文",
            contentHTML: "<p>\(body)</p>", contentText: body, wordCount: body.count))
        let pages = try await db.globalSearch(query: "正文末尾独有关键词", kind: .article)
        let hit = try XCTUnwrap(pages.first?.items.first)
        XCTAssertEqual(hit.target.recordID, article.id)
        XCTAssertTrue(hit.preview.contains("正文末尾独有关键词"))
        XCTAssertLessThanOrEqual(hit.preview.count, 241)
        let fetched = try await db.resolveGlobalSearchTarget(hit.target)
        let resolved = try XCTUnwrap(fetched)
        guard case .article(let full) = resolved else { return XCTFail("应读取完整文章") }
        XCTAssertEqual(full.contentText, body)
        XCTAssertEqual(full.contentHTML, article.contentHTML)
    }

    func testPagingIsBoundedStableAndEveryResultIsReachable() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var ids: [Int64] = []
        let date = Date(timeIntervalSince1970: 100)
        for index in 0..<47 {
            ids.append(try XCTUnwrap(db.save(Card(front: "分页关键词\(index)", createdAt: date)).id))
        }
        var loaded: [Int64] = []
        for offset in stride(from: 0, to: 47, by: 20) {
            let pages = try await db.globalSearch(query: "分页关键词", kind: .card, offset: offset, limit: 20)
            let page = try XCTUnwrap(pages.first)
            XCTAssertEqual(page.total, 47)
            XCTAssertEqual(page.offset, offset)
            XCTAssertEqual(page.items.count, offset < 40 ? 20 : 7)
            XCTAssertEqual(page.hasMore, offset < 40)
            loaded += page.items.map(\.target.recordID)
        }
        XCTAssertEqual(loaded, Array(ids.reversed()))
        XCTAssertEqual(Set(loaded).count, 47)
        let end = try await db.globalSearch(query: "分页关键词", kind: .card, offset: 1000)
        XCTAssertTrue(end.first?.items.isEmpty == true)
        let empty = try await db.globalSearch(query: " \n ")
        XCTAssertTrue(empty.allSatisfy { $0.total == 0 && $0.items.isEmpty })
    }

    func testResolvingDeletedResultDoesNotOpenTrashAndKeepsFullHighlightPages() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "版本"))
        let fullText = String(repeating: "完整原文", count: 1000)
        let highlight = try db.save(Highlight(text: fullText, note: "完整按语"))
        try db.setEditionPages(highlight.id!, [source.id!: "第十二页"])
        let target = GlobalSearchTarget(kind: .highlight, recordID: highlight.id!)
        let fetched = try await db.resolveGlobalSearchTarget(target)
        let resolved = try XCTUnwrap(fetched)
        guard case .highlight(let full, let pages) = resolved else { return XCTFail("应读取完整摘录") }
        XCTAssertEqual(full.text, fullText)
        XCTAssertEqual(pages, [source.id!: "第十二页"])
        var deleted = highlight
        deleted.deletedAt = Date()
        try db.save(deleted)
        let missing = try await db.resolveGlobalSearchTarget(target)
        XCTAssertNil(missing)
    }

    @MainActor
    func testStateRejectsOldQueriesAndOldLoadMoreAndRefreshesMovedPages() {
        let state = GlobalSearchState()
        state.query = "旧查询"
        let old = state.requestID
        state.query = "新查询"
        let current = state.requestID
        let hit = GlobalSearchHit(target: GlobalSearchTarget(kind: .card, recordID: 1), title: "标题", preview: "正文", context: "牌组")
        let first = GlobalSearchPage(kind: .card, items: [hit], total: 2, offset: 0)
        XCTAssertFalse(state.apply([first], requestID: old, query: "旧查询", kind: nil))
        XCTAssertTrue(state.sections.isEmpty)
        XCTAssertTrue(state.apply([first], requestID: current, query: "新查询", kind: nil))
        state.selectedKind = .card
        XCTAssertFalse(state.append(GlobalSearchPage(kind: .card, items: [hit], total: 2, offset: 1),
                                    requestID: current, query: "新查询"))
        XCTAssertTrue(state.sections.isEmpty)
        let selected = state.requestID
        XCTAssertTrue(state.apply([first], requestID: selected, query: "新查询", kind: .card))
        XCTAssertFalse(state.append(GlobalSearchPage(kind: .card, items: [hit], total: 2, offset: 1),
                                   requestID: selected, query: "新查询"))
        XCTAssertNotEqual(state.requestID, selected)
        XCTAssertTrue(state.sections.isEmpty)
        XCTAssertTrue(state.isLoading)
    }

    @MainActor
    func testOpeningSearchCannotReplaceUnsavedEditorAndTargetWaitsForDismiss() throws {
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db, positionDefaults: nil)
        let original = HighlightDraft(highlight: Highlight(text: "正在编辑且未保存"))
        store.editorDraft = original
        store.showGlobalSearch()
        XCTAssertFalse(store.globalSearch.isPresented)
        store.applyGlobalSearchTarget(.highlight(Highlight(text: "另一个结果"), [:]))
        XCTAssertEqual(store.editorDraft?.id, original.id)
        XCTAssertEqual(store.editorDraft?.highlight.text, "正在编辑且未保存")
        store.editorDraft = nil
        store.showGlobalSearch()
        XCTAssertTrue(store.globalSearch.isPresented)
        let target = GlobalSearchTarget(kind: .card, recordID: 5)
        store.globalSearch.choose(target)
        XCTAssertFalse(store.globalSearch.isPresented)
        XCTAssertNil(store.cardEditor)
        XCTAssertEqual(store.globalSearch.takePendingTarget(), target)
        XCTAssertNil(store.globalSearch.takePendingTarget())
    }

    @MainActor
    func testResolvedCardAndSourceNavigateWithoutChangingLearningRecords() throws {
        let db = try AppDatabase(DatabaseQueue())
        let store = LibraryStore(db: db, positionDefaults: nil)
        let card = try db.save(Card(deck: "目标牌组", front: "完整卡片", back: "完整答案"))
        let persisted = try XCTUnwrap(db.card(id: card.id!))
        store.applyGlobalSearchTarget(.card(persisted))
        XCTAssertEqual(store.cardEditor?.card, persisted)
        XCTAssertEqual(try db.card(id: card.id!), persisted)
        store.cardEditor = nil
        let source = try db.save(Source(title: "目标出处"))
        store.list.query = "之前列表中的过滤词"
        store.applyGlobalSearchTarget(.source(source))
        XCTAssertEqual(store.selection, .source(source.id!))
        XCTAssertEqual(store.list.query, "")
    }
}
