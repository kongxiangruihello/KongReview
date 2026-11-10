import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.3.3：添加网页——整篇存为一条摘录，出处按网址认；同一网页不重复；同名而网址不同的不并入
final class V633WebPageTests: XCTestCase {
    private func page(_ title: String, url: String, paragraphs: Int = 40) -> ArticleExtraction {
        let body = (1...paragraphs).map { "第\($0)段：士不可以不弘毅，任重而道远。仁以为己任，不亦重乎？死而后已，不亦远乎？" }.joined(separator: "\n\n")
        let json: [String: Any] = ["title": title, "byline": "钱穆", "siteName": "某网站", "content": "<p>…</p>",
                                   "textContent": body, "lang": "zh", "h1": title, "url": url]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! ArticleExtraction.decode(String(decoding: data, as: UTF8.self))
    }

    func testSaveWebPage() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 已有一个同名的书（没有网址）：网页不并入它
        let book = try db.save(Source(title: "士与中国文化", author: "", kind: .book))

        let first = try db.saveWebPage(page("士与中国文化", url: "https://example.com/a"), url: "https://example.com/a")
        XCTAssertFalse(first.existed)
        XCTAssertNotEqual(first.source.id, book.id, "按网址认出处，不按标题并入同名的书")
        XCTAssertEqual(first.source.kind, .web)
        XCTAssertEqual(first.source.url, "https://example.com/a")
        XCTAssertEqual(first.source.author, "钱穆")
        XCTAssertEqual(first.highlight.sourceId, first.source.id)
        XCTAssertTrue(first.highlight.text.hasPrefix("第1段："))
        XCTAssertGreaterThanOrEqual(first.highlight.text.count, AnnotateSettings.minimumRawLength, "够长，进今日标注的待标文章")
        let candidates = try db.writer.read { try AppDatabase.annotateCandidates($0) }
        XCTAssertTrue(candidates.contains(first.highlight.id!))

        // 同一网址再存一次：不重复
        let again = try db.saveWebPage(page("士与中国文化", url: "https://example.com/a"), url: "https://example.com/a")
        XCTAssertTrue(again.existed)
        XCTAssertEqual(again.highlight.id, first.highlight.id)
        XCTAssertEqual(try db.writer.read { try Highlight.fetchCount($0) }, 1)

        // 另一个网址：新出处、新摘录
        let other = try db.saveWebPage(page("士与中国文化", url: "https://example.com/b"), url: "https://example.com/b")
        XCTAssertFalse(other.existed)
        XCTAssertNotEqual(other.source.id, first.source.id)

        // 已有这个网址的出处（如快速录入时记过一句），但还没有整篇：照样存整篇，用那个出处
        let s = try db.findOrCreateSource(title: "论语讲义", kind: .web, url: "https://example.com/c")
        _ = try db.save(Highlight(sourceId: s.id, text: "学而时习之"))
        let c = try db.saveWebPage(page("论语讲义", url: "https://example.com/c"), url: "https://example.com/c")
        XCTAssertFalse(c.existed)
        XCTAssertEqual(c.source.id, s.id)
    }
}
