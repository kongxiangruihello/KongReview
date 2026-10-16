import AppKit
import CoreGraphics
import GRDB
import JavaScriptCore
import WebKit
import XCTest
import KongReviewCore
@testable import KongReview

@MainActor
final class V250ArticleReaderTests: XCTestCase {
    private func temporaryDefaults() -> (UserDefaults, String) {
        let suite = "V250ArticleReaderTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testPositionSurvivesNewServiceAndIsIndependentForEachArticle() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ArticleReadingPosition(ratio: 0.65, anchor: "读到的段落", anchorOffset: -18)
        ArticleReadingState(defaults: defaults).save(original, for: 21)
        ArticleReadingState(defaults: defaults).save(.init(ratio: 0.2, anchor: "另一篇"), for: 22)
        let restored = ArticleReadingState(defaults: defaults)
        XCTAssertEqual(restored.position(for: 21), original)
        XCTAssertEqual(restored.position(for: 22)?.ratio, 0.2)
        XCTAssertNil(restored.position(for: 23))
        XCTAssertNil(restored.position(for: nil))
    }

    func testPositionBoundsAndDamagedPreferencesRecoverSafely() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ArticleReadingState(defaults: defaults)
        defaults.set(Data("not JSON".utf8), forKey: "articleReading.position.v1.4")
        XCTAssertNil(state.position(for: 4))
        let value = ArticleReadingPosition(ratio: .infinity, anchor: String(repeating: "文", count: 300), anchorOffset: .nan)
        XCTAssertEqual(value.ratio, 0)
        XCTAssertEqual(value.anchor.count, 160)
        XCTAssertEqual(value.anchorOffset, 0)
        XCTAssertEqual(ArticleReadingPosition(ratio: 4).ratio, 1)
        XCTAssertEqual(ArticleReadingPosition(ratio: -0.3).ratio, 0)
    }

    func testChangingArticleClearsFindWithoutChangingSavedProgress() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ArticleReadingState(defaults: defaults)
        state.open(articleID: 1)
        state.save(.init(ratio: 0.8), for: 1)
        state.showsFind = true; state.query = "关键词"; state.matchCount = 3; state.currentMatch = 2
        state.open(articleID: 2)
        XCTAssertFalse(state.showsFind)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.matchCount, 0)
        XCTAssertEqual(state.position(for: 1)?.ratio, 0.8)
    }

    func testReaderScriptParsesAndSearchArgumentsStayLiteral() throws {
        let context = try XCTUnwrap(JSContext())
        _ = context.evaluateScript("new Function('saved', \(EditorPage.jsonString(ArticleReaderScript.script)))")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        let query = "a+b[文] ' \\\n</script>"
        _ = context.evaluateScript("var window={kgReader:{find:function(q,d){return JSON.stringify([q,d]);}}};")
        let encoded = context.evaluateScript(ArticleReaderScript.find(query, direction: -1))?.toString()
        let values = try XCTUnwrap(encoded?.data(using: .utf8)).flatMapJSON() as? [Any]
        XCTAssertEqual(values?.first as? String, query)
        XCTAssertEqual((values?.last as? NSNumber)?.intValue, -1)
        XCTAssertNil(context.exception)
    }

    func testArticleListRestoresPageQuerySizeSortAndRejectsStaleSize() {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = ListPositionPersistence(defaults: defaults)
        let state = ArticleListState(persistence: persistence)
        state.query = "近代史"; state.selectedPageSize = 50; state.sort = .title
        state.total = 160; state.goToPage(3)
        let restored = ArticleListState(persistence: persistence)
        XCTAssertEqual(restored.query, "近代史")
        XCTAssertEqual(restored.selectedPageSize, 50)
        XCTAssertEqual(restored.sort, .title)
        XCTAssertEqual(restored.page, 3)
        let request = restored.loadID
        XCTAssertFalse(restored.apply(ArticlePage(items: [], total: 160, page: 3, highlightCounts: [:]),
                                      requestID: request, query: "近代史", page: 3, pageSize: 100, sort: .title))
        restored.selectedPageSize = 100
        XCTAssertEqual(restored.page, 1)
        XCTAssertEqual(ArticleListState(persistence: persistence).selectedPageSize, 100)
    }

    func testArticleSortUsesStablePageOrder() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var old = Article(url: "https://example.com/old", title: "B", contentHTML: "<p>正文</p>", contentText: "正文", wordCount: 2, savedAt: Date(timeIntervalSince1970: 1))
        old.isRead = false
        var new = Article(url: "https://example.com/new", title: "A", contentHTML: "<p>正文</p>", contentText: "正文", wordCount: 2, savedAt: Date(timeIntervalSince1970: 2))
        new.isRead = true
        old = try db.saveArticle(old); new = try db.saveArticle(new)
        let titleFirst = try await db.articlePage(query: "", page: 1, pageSize: 1, sort: .title)
        let titleSecond = try await db.articlePage(query: "", page: 2, pageSize: 1, sort: .title)
        let unread = try await db.articlePage(query: "", page: 1, sort: .unreadFirst)
        let oldest = try await db.articlePage(query: "", page: 1, sort: .savedOldest)
        XCTAssertEqual(titleFirst.items.first?.id, new.id)
        XCTAssertEqual(titleSecond.items.first?.id, old.id)
        XCTAssertEqual(unread.items.compactMap(\.id), [old.id!, new.id!])
        XCTAssertEqual(oldest.items.compactMap(\.id), [old.id!, new.id!])
    }

    func testWebFindMatchesInlineTextPreservesMarksAndSelectionAndWraps() async throws {
        try requireDesktopSession()
        let (view, delegate) = try await webView(html: "<p>历史<strong>研究</strong>，历史研究，a+b。</p>")
        _ = delegate
        _ = try await view.evaluateJavaScript(ReaderPage.applyScript([ReaderPage.Mark(id: 1, text: "历史研究")]))
        _ = try await view.evaluateJavaScript(ArticleReaderScript.install(position: nil, session: "test"))
        let before = try await view.evaluateJavaScript("document.getElementById('kg-content').innerHTML") as? String
        _ = try await view.evaluateJavaScript("var sel=window.getSelection(),r=document.createRange();r.selectNodeContents(document.querySelector('#kg-content strong'));sel.removeAllRanges();sel.addRange(r);")
        let found = try await view.evaluateJavaScript(ArticleReaderScript.find("历史研究")) as? [String: Any]
        XCTAssertEqual((found?["total"] as? NSNumber)?.intValue, 2)
        let next = try await view.evaluateJavaScript(ArticleReaderScript.find("历史研究", direction: 1)) as? [String: Any]
        XCTAssertEqual((next?["current"] as? NSNumber)?.intValue, 2)
        let wrapped = try await view.evaluateJavaScript(ArticleReaderScript.find("历史研究", direction: 1)) as? [String: Any]
        XCTAssertEqual((wrapped?["current"] as? NSNumber)?.intValue, 1)
        let literal = try await view.evaluateJavaScript(ArticleReaderScript.find("a+b")) as? [String: Any]
        XCTAssertEqual((literal?["total"] as? NSNumber)?.intValue, 1)
        let after = try await view.evaluateJavaScript("document.getElementById('kg-content').innerHTML") as? String
        let selected = try await view.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(before, after)
        XCTAssertEqual(selected, "研究")
    }

    func testWebPositionWaitsForRestoreAndReturnsToParagraph() async throws {
        try requireDesktopSession()
        let html = (1...100).map { "<p>第\($0)段：网页阅读位置保存测试。</p>" }.joined()
        let (view, delegate) = try await webView(html: html)
        _ = delegate
        let position = ArticleReadingPosition(ratio: 0.6, anchor: "第60段：网页阅读位置保存测试。", anchorOffset: 0)
        _ = try await view.evaluateJavaScript(ArticleReaderScript.install(position: position, session: "test"))
        let pending = try await view.evaluateJavaScript("JSON.stringify(window.kgReader.snapshot())") as? String
        XCTAssertEqual(pending, "null", "恢复完成之前不能把顶部写回进度。")
        try await Task.sleep(nanoseconds: 900_000_000)
        let restored = try await view.evaluateJavaScript("window.kgReader.snapshot()") as? [String: Any]
        XCTAssertEqual(restored?["anchor"] as? String, position.anchor)
        XCTAssertEqual((restored?["anchorOffset"] as? NSNumber)?.doubleValue ?? 100, 0, accuracy: 2)
    }

    private func requireDesktopSession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["kCGSessionOnConsoleKey"] as? Bool == true else { throw XCTSkip("网页查找和阅读位置布局回归需要已登录的 macOS 图形会话。") }
        _ = NSApplication.shared
    }

    private func webView(html: String) async throws -> (WKWebView, ReaderNavigationRecorder) {
        let ready = expectation(description: "网页加载完成")
        let delegate = ReaderNavigationRecorder(ready: ready)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.navigationDelegate = delegate
        let article = Article(url: "https://example.com", title: "测试", contentHTML: html, contentText: "", wordCount: 1000)
        view.loadHTMLString(ReaderPage.html(for: article), baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        return (view, delegate)
    }
}

private extension Data {
    func flatMapJSON() throws -> Any { try JSONSerialization.jsonObject(with: self) }
}

@MainActor
private final class ReaderNavigationRecorder: NSObject, WKNavigationDelegate {
    let ready: XCTestExpectation
    init(ready: XCTestExpectation) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.fulfill() }
}
