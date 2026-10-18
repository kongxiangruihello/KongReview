import XCTest
import AppKit
import GRDB
import KongReviewCore
@testable import KongReview

final class V35HTMLSourceTests: XCTestCase {
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
    func testHighlightSearchCrossesInlineTagsAndIgnoresAttributes() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text:"<p data-secret=\"uniqueattribute\">臺<strong>灣歷</strong>史</p>"))
        var query = HighlightQuery(); query.text = "台湾历史"
        XCTAssertEqual(try db.highlights(query).map(\.id),[h.id])
        query.text = "uniqueattribute"
        XCTAssertTrue(try db.highlights(query).isEmpty)
    }
    func testHTMLPlanSplittingAndStoredSourceRoundTrip() throws {
        XCTAssertEqual(LearningPlanDraft.lines("<p>第一项</p><p><strong>第二项</strong></p>"),["第一项","第二项"])
        let db = try AppDatabase(DatabaseQueue())
        let html = "<p data-note=\"保留\">整理<strong>史料</strong></p>"
        let plan = LearningPlan(title:html)
        try db.commitPlanDraft(.init(plan:plan))
        XCTAssertEqual(try db.progressValue(LearningPlan.self,key:plan.key)?.title,html)
        XCTAssertThrowsError(try db.commitPlanDraft(.init(plan:.init(title:"<p><br></p>"))))
    }
}
