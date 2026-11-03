import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.0：HTML 模板存取、卡片样式、普通卡片样式、样式清理
final class V600TemplateHTMLTests: XCTestCase {
    func testSaveAndLoadTemplateHTML() throws {
        let db = try AppDatabase(DatabaseQueue())
        var t = NoteTemplate.defaultTemplate(name: "论语", fieldNames: ["正文", "注释"])
        try db.save(t)
        XCTAssertNil(try db.noteTemplates()["论语"]?.html)
        t.html = NoteTemplateHTML(front: "{{正文}}", back: "{{FrontSide}}<hr id=answer>{{注释}}", css: ".face { font-size: 30px; }")
        try db.save(t)
        XCTAssertEqual(try db.noteTemplates()["论语"]?.html, t.html)
        t.html = nil
        try db.save(t)
        XCTAssertNil(try db.noteTemplates()["论语"]?.html, "改回放置")
    }

    func testCardCSSAndPlainStyle() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            var t = NoteTemplate.defaultTemplate(name: "论语", fieldNames: ["正文", "注释"])
            t.html = NoteTemplateHTML(front: "{{正文}}", back: "{{注释}}", css: ".q{}")
            try db.save(t)
            var noted = Card(deck: "默认", front: "", back: "")
            noted.noteType = "论语"; noted.fields = ["学而", "注"]
            noted = try db.save(noted)
            let plain = try db.save(Card(deck: "默认", front: "问", back: "答"))
            let store = LibraryStore(db: db)
            XCTAssertEqual(store.cardCSS(for: noted), ".q{}")
            XCTAssertEqual(store.cardCSS(for: plain), "")
            store.savePlainCardCSS(".face{font-size:24px}")
            XCTAssertEqual(store.cardCSS(for: plain), ".face{font-size:24px}")
            XCTAssertEqual(store.cardCSS(for: noted), ".q{}", "有 HTML 模板的不用普通样式")
            XCTAssertEqual(LibraryStore(db: db).plainCardCSS, ".face{font-size:24px}", "存在学习库里，重开还在")
            XCTAssertEqual(store.faces(of: noted).front, "学而")
            XCTAssertEqual(try db.sampleCards(noteType: "论语").map(\.id), [noted.id])
            XCTAssertEqual(try db.samplePlainCard()?.id, plain.id)
        }
    }

    func testUserStyleIsCleaned() {
        XCTAssertEqual(CardWebView.userStyle("  "), "")
        XCTAssertEqual(CardWebView.userStyle(".a{}"), "<style>.a{}</style>")
        let bad = CardWebView.userStyle(".a{}</style><script>alert(1)</script>@import url(http://x.com/a.css); .b{background:url('https://x.com/i.png')}")
        XCTAssertFalse(bad.lowercased().contains("</style><script"), "不能跳出样式")
        XCTAssertFalse(bad.contains("@import"))
        XCTAssertFalse(bad.contains("https://x.com"))
        XCTAssertTrue(bad.hasPrefix("<style>") && bad.hasSuffix("</style>"))
        XCTAssertTrue(CardWebView.page(front: "a", back: nil, css: ".z{}").contains("<style>.z{}</style></head>"))
    }
}
