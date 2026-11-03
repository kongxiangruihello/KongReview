import XCTest
import AppKit
import GRDB
import KongReviewCore
@testable import KongReview

final class V35HTMLSourceTests: XCTestCase {
    func testReadingRendersBareDomainHTMLLinksAsClickableHTTPS() {
        for source in ["<p><a href=\"gemini.google.com\">gemini</a></p>",
                       "[gemini](gemini.google.com)",
                       "<a href='https://gemini.google.com'>gemini</a>"] {
            let html = RichWebText.bodyHTML(source)
            XCTAssertTrue(html.contains("<a href=\"https://gemini.google.com\">gemini</a>"),html)
            XCTAssertFalse(html.contains("[gemini]"))
        }
        let query = Markdown.richHTML("<a href=\"example.com/search?q=史料&amp;page=2\">检索</a>")
        XCTAssertTrue(query.contains("https://example.com/search?q=史料&amp;page=2"))
        XCTAssertFalse(Markdown.html("[bad](javascript:alert)").contains("<a "))
        XCTAssertFalse(Markdown.html("[relative](notes/page)").contains("<a "))
    }
    func testLegacyConversionAndExactSourcePreservation() {
        XCTAssertTrue(HTMLSourceCodec.editable("**旧正文**").contains("<strong>"))
        let source = "<section data-id=\"甲\">\n<p>原文 &amp; <em>注</em></p>\n</section>"
        XCTAssertEqual(HTMLSourceCodec.editable(source),source)
        XCTAssertEqual(HTMLSourceCodec.editable(""),"")
        XCTAssertFalse(HTMLSourceCodec.hasContent("<p><br>&nbsp;</p>"))
        XCTAssertTrue(HTMLSourceCodec.hasContent("<img src=\"local.png\">"))
    }
    func testClozeRejectsTagAndPartialEntitySelections() {
        let source = "<p>😀史料 &amp; 分析</p>", ns = source as NSString
        XCTAssertTrue(HTMLSourceCodec.canWrapCloze(source,range:ns.range(of:"😀史料")))
        XCTAssertTrue(HTMLSourceCodec.canWrapCloze(source,range:ns.range(of:"&amp;")))
        XCTAssertFalse(HTMLSourceCodec.canWrapCloze(source,range:ns.range(of:"amp")))
        XCTAssertFalse(HTMLSourceCodec.canWrapCloze(source,range:ns.range(of:"p>😀")))
        XCTAssertFalse(HTMLSourceCodec.canWrapCloze(source,range:NSRange(location:NSNotFound,length:1)))
    }
    @MainActor func testNativeTagInsertionPreservesLiteralSourceAndSelection() {
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:500,height:200))
        view.isRichText = false; view.isEditable = true
        view.string = "<p>😀史料</p>"
        var saved = ""
        view.changed = { saved = $0 }
        view.setSelectedRange((view.string as NSString).range(of:"😀史料"))
        view.applyHTML("bold")
        XCTAssertEqual(view.string,"<p><strong>😀史料</strong></p>")
        XCTAssertEqual(saved,view.string)
        XCTAssertEqual((view.string as NSString).substring(with:view.selectedRange()),"😀史料")
        view.insertHTMLLink("https://example.com/?a=1&b=\"2\"")
        XCTAssertTrue(view.string.contains("&amp;b=&quot;2&quot;"))
        XCTAssertTrue(view.string.contains(">😀史料</a>"))
    }
    @MainActor func testSourceViewportKeepsLeftEdgeVisibleAfterResizeAndCaretScroll() {
        let scroll = SourceScrollView(frame:NSRect(x:0,y:0,width:320,height:160))
        scroll.contentView = SourceClipView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:900,height:1500))
        view.isRichText = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = NSSize(width:10,height:10)
        view.textContainer?.widthTracksTextView = true
        view.string = "<p>" + String(repeating:"很长的正文abcdef",count:200) + "</p>"
        scroll.documentView = view
        for width: CGFloat in [320,180,680,240] {
            scroll.setFrameSize(NSSize(width:width,height:160))
            scroll.tile()
            view.setSelectedRange(NSRange(location:(view.string as NSString).length,length:0))
            view.scrollRangeToVisible(view.selectedRange())
            scroll.contentView.scroll(to:NSPoint(x:140,y:100))
            XCTAssertEqual(scroll.contentView.bounds.origin.x,0,accuracy:0.5)
            XCTAssertEqual(view.frame.width,scroll.contentView.bounds.width,accuracy:0.5)
            XCTAssertEqual(view.textContainer!.containerSize.width,view.frame.width-20,accuracy:0.5)
            let constrained = scroll.contentView.constrainBoundsRect(NSRect(x:-80,y:30,width:width,height:160))
            XCTAssertEqual(constrained.origin.x,0)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y,0,"Vertical reading must remain available")
        }
        XCTAssertTrue(view.string.hasPrefix("<p>很长的正文"))
    }
    func testHighlightSearchCrossesInlineTagsAndIgnoresAttributes() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text:"<p data-secret=\"uniqueattribute\">臺<strong>灣歷</strong>史</p>"))
        var query = HighlightQuery(); query.text = "台湾历史"
        XCTAssertEqual(try db.highlights(query).map(\.id),[h.id])
        query.text = "uniqueattribute"
        XCTAssertTrue(try db.highlights(query).isEmpty)
    }
}
