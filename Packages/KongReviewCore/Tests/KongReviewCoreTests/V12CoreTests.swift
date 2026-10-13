import XCTest
@testable import KongReviewCore

final class V12CoreTests: XCTestCase {
    // 繁简归一
    func testChineseFold() {
        XCTAssertEqual(ChineseFold.fold("紅衛兵與張春橋"), "红卫兵与张春桥")
        XCTAssertEqual(ChineseFold.fold("ＡＢＣ　Def"), "abc def")
        XCTAssertEqual(ChineseFold.fold("红卫兵").unicodeScalars.count, "红卫兵".unicodeScalars.count)
        XCTAssertTrue(ChineseFold.changes("學而"))
        XCTAssertFalse(ChineseFold.changes("学而"))
    }

    func testSearchTermsAcrossScripts() {
        let text = "上海還有一支紅衛兵力量"
        let r = SearchTerms.ranges(of: ["红卫兵"], in: text)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(String(text[r[0]]), "紅衛兵")
        let r2 = SearchTerms.ranges(of: ["還有"], in: "还有还有")
        XCTAssertEqual(r2.count, 2)
    }

    func testRelatedTermsFolded() {
        XCTAssertEqual(RelatedIndex.terms("學而"), RelatedIndex.terms("学而"))
    }

    // 记忆卡背面栏目
    func testCardSectionsRender() {
        var c = Card(front: "仁", back: "**爱人**")
        XCTAssertEqual(c.faces(using: nil).back, "**爱人**")
        c.sections = [CardSection(name: "出处", text: "《论语·颜渊》"),
                      CardSection(name: "注释", text: "樊迟问仁", folded: true),
                      CardSection(name: "空", text: "  ")]
        let back = c.faces(using: nil).back
        XCTAssertTrue(back.contains("<strong>爱人</strong>"))
        XCTAssertTrue(back.contains("<div class=\"kr-label\">出处</div>"))
        XCTAssertTrue(back.contains("<details class=\"kr-field\"><summary>注释</summary>"))
        XCTAssertFalse(back.contains("空"))
        // 编码 / 解码（存进数据库的 JSON）
        let data = try! JSONEncoder().encode(c)
        let d = try! JSONDecoder().decode(Card.self, from: data)
        XCTAssertEqual(d.sections?.count, 3)
        XCTAssertEqual(d.sections?[1].folded, true)
    }

    // 编辑器
    func testEditorDisplayHTMLRewritesImages() {
        let (html, isHTML) = EditorPage.displayHTML(for: "<div>x<img src=\"a b.jpg\"></div>", mode: .card)
        XCTAssertTrue(isHTML)
        XCTAssertTrue(html.contains("src=\"kr-media://media/a%20b.jpg\" data-kr-src=\"a b.jpg\""), html)
        let (h2, _) = EditorPage.displayHTML(for: "![](https://e.com/p.png)", mode: .markdown)
        XCTAssertTrue(h2.contains("kr-img://img?u=https://e.com/p.png"), h2)
        XCTAssertTrue(h2.contains("data-kr-src=\"https://e.com/p.png\""), h2)
        let (h3, _) = EditorPage.displayHTML(for: "![](kr-media://media/x.png)", mode: .markdown)
        XCTAssertFalse(h3.contains("data-kr-src"))
    }

    func testEditorPageEscapesScript() {
        let page = EditorPage.page(text: "</script><b>x</b>", mode: .markdown)
        XCTAssertFalse(page.contains("</script><b>x"))
        XCTAssertTrue(page.contains("window.__krCfg"))
    }

    // 编辑器输出的 Markdown 能被渲染器正确显示
    func testEditorMarkdownRenders() {
        let html = Markdown.html("普通**加粗***倾斜***样式粗**红")
        XCTAssertTrue(html.contains("<strong>加粗</strong><em>倾斜</em><strong>样式粗</strong>"), html)
        let h2 = Markdown.html("# 大标题\n\n- 项目一\n- 项目二\n\n> 名言\n\n1. 第一\n2. 第二\n\n~~删~~")
        XCTAssertTrue(h2.contains("<h1>大标题</h1>"))
        XCTAssertTrue(h2.contains("<ol>"))
        XCTAssertTrue(h2.contains("<del>删</del>"))
    }

    // GB/T 7714 参考文献表
    func testBibliography() {
        let a = Source(title: "严复集", author: "严复", kind: .book, publisher: "中华书局", year: "1986")
        let b = Source(title: "革命造反年代：上海文革运动史稿", author: "李逊", kind: .book, publisher: "中文大学出版社", year: "2015")
        let list = Bibliography.entries([b, a, a])
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].hasPrefix("[1] "))
        XCTAssertTrue(list.joined().contains("[M]"))
    }
}

final class V12ClipboardTests: XCTestCase {
    func testClipboardHTMLFromWebPage() {
        let html = """
        <html><head><meta charset="utf-8"><style>p{color:red}</style></head><body>
        <!--StartFragment--><h2 style="font-size:20px">學而第一</h2>
        <p>子曰：<b>學而時習之</b>，不亦說乎？
        有朋自遠方來，<i>不亦樂乎</i>？</p>
        <ul><li>甲</li><li>乙</li></ul>
        <p><a href="https://example.com/x">鏈接</a> <s>刪</s></p><!--EndFragment-->
        </body></html>
        """
        let md = Markdown.markdown(fromClipboardHTML: html)
        XCTAssertTrue(md.hasPrefix("## 學而第一"), md)
        XCTAssertTrue(md.contains("子曰：**學而時習之**，不亦說乎？有朋自遠方來，*不亦樂乎*？"), md)
        XCTAssertTrue(md.contains("- 甲\n- 乙"), md)
        XCTAssertTrue(md.contains("[鏈接](https://example.com/x) ~~刪~~"), md)
        XCTAssertFalse(md.contains("color"), md)
        XCTAssertFalse(md.contains("StartFragment"), md)
    }

    func testClipboardHTMLFromWord() {
        let html = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><!--[if gte mso 9]><xml><o:OfficeDocumentSettings></o:OfficeDocumentSettings></xml><![endif]--></head>
        <body lang=ZH-CN><p class=MsoNormal><span style='font-weight:bold'>重點</span><span lang=EN-US>English
        words</span><o:p></o:p></p></body></html>
        """
        let md = Markdown.markdown(fromClipboardHTML: html)
        XCTAssertEqual(md, "**重點**English words")
    }
}

final class V12RTFTests: XCTestCase {
    func testEscapeAndFootnote() {
        XCTAssertEqual(RTFWriter.escape("a{b}\\c"), "a\\{b\\}\\\\c")
        XCTAssertEqual(RTFWriter.escape("學"), "\\u23416?")
        XCTAssertEqual(RTFWriter.escape("𠀀"), "\\u-10176?\\u-9216?")
        let doc = RTFWriter.document([[.text("“學而時習之”"), .footnote("《論語·學而》。")]])
        XCTAssertTrue(doc.hasPrefix("{\\rtf1"))
        XCTAssertTrue(doc.contains("\\footnote"))
        XCTAssertTrue(doc.allSatisfy { $0.isASCII })
        if let out = ProcessInfo.processInfo.environment["KR_RTF_OUT"] {
            try? doc.write(toFile: out, atomically: true, encoding: .ascii)
        }
    }
}
