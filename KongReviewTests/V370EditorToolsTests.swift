import XCTest
import AppKit
import JavaScriptCore
import GRDB
import KongReviewCore
@testable import KongReview

final class V370EditorToolsTests: XCTestCase {
    func testLiteralSearchUnicodeReplacementAndBoundedMatches() {
        let text = "😀 A.b a.B\nA.b"
        let matches = EditorTextMatch.find(text,query:"a.b",caseSensitive:false)
        XCTAssertEqual(matches.ranges.count,3)
        XCTAssertEqual(matches.ranges[0].location,3)
        XCTAssertEqual(matches.replacing(text,with:"$&<新>"),"😀 $&<新> $&<新>\n$&<新>")
        XCTAssertEqual(EditorTextMatch.find(text,query:"A.b",caseSensitive:true).ranges.count,2)
        XCTAssertTrue(EditorTextMatch.find(text,query:"",caseSensitive:false).ranges.isEmpty)
        let many = EditorTextMatch.find(String(repeating:"a",count:5001),query:"a",caseSensitive:true)
        XCTAssertEqual(many.ranges.count,5000); XCTAssertTrue(many.truncated)
    }
    @MainActor func testSourceReplacementIsUndoableAndStalePreviewCannotOverwrite() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:480,height:180))
        view.isRichText = false; view.isEditable = true; view.allowsUndo = true
        window.contentView = view; window.makeFirstResponder(view)
        let handle = RichEditorHandle(); handle.textView = view
        view.string = "<p>甲 甲</p>"
        let mutation = EditorMutation(title:"测试",original:view.string,proposed:"<p>乙 乙</p>",count:2,source:true)
        var applied = false
        handle.apply(mutation) { applied = $0 }; XCTAssertTrue(applied); XCTAssertEqual(view.string,"<p>乙 乙</p>")
        view.undoManager?.undo(); XCTAssertEqual(view.string,"<p>甲 甲</p>")
        handle.valueReader = { "外部绑定先于视图更新" }
        var guarded = mutation; guarded.storedBaseline = "原绑定"
        handle.apply(guarded) { applied = $0 }; XCTAssertFalse(applied); XCTAssertEqual(view.string,"<p>甲 甲</p>")
        view.string = "外部更新"
        handle.apply(mutation) { applied = $0 }; XCTAssertFalse(applied); XCTAssertEqual(view.string,"外部更新")
    }
    @MainActor func testResourceLocationRestoresFocusAndRespectsChangedInput() async throws {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:150),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:390,height:140))
        window.contentView = view; view.isEditable = true
        let source = "<a href=\"example.com\">地址</a>"
        view.string = source
        let handle = RichEditorHandle(); handle.textView = view
        let range = (source as NSString).range(of:"example.com")
        handle.revealSourceSelection(range,in:source)
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(view.selectedRange(),range); XCTAssertTrue(window.firstResponder === view)
        handle.revealSourceSelection(range,in:source)
        view.string = "用户的新输入"; view.setSelectedRange(NSRange(location:0,length:0))
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(view.selectedRange().location,0); XCTAssertEqual(view.string,"用户的新输入")
    }
    @MainActor func testLongMatchScrollsOuterViewportWithoutHorizontalDrift() {
        let outer = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:180))
        let document = NSView(frame:NSRect(x:0,y:0,width:400,height:3000)); outer.documentView = document
        let editor = NSView(frame:NSRect(x:0,y:0,width:400,height:3000)); document.addSubview(editor)
        EditorViewport.reveal(NSRect(x:12,y:2600,width:100,height:24),in:editor)
        XCTAssertGreaterThan(outer.contentView.bounds.minY,2000)
        XCTAssertEqual(outer.contentView.bounds.minX,0)
        EditorViewport.reveal(NSRect(x:12,y:20,width:100,height:24),in:editor)
        XCTAssertLessThan(outer.contentView.bounds.minY,100)
    }
    func testCleanupPreservesSemanticFormattingMediaAndCSSFunctions() {
        let source = #"<p style="font-family:Arial;font-size:20px;color:red;text-align:center;background-image:url('data:x;a')"><span><strong>正文</strong><a href="https://example.com">链接</a><img src="a.png"></span></p><p><br></p>"#
        let result = EditorFormattingCleanup.clean(source,options:.init())
        XCTAssertFalse(result.text.contains("font-family")); XCTAssertFalse(result.text.contains("font-size")); XCTAssertFalse(result.text.contains("color:red"))
        XCTAssertTrue(result.text.contains("text-align:center")); XCTAssertTrue(result.text.contains("background-image:url('data:x;a')"))
        XCTAssertTrue(result.text.contains("<strong>正文</strong>")); XCTAssertTrue(result.text.contains(#"<img src="a.png">"#))
        XCTAssertTrue(result.text.contains(#"<a href="https://example.com">链接</a>"#))
        XCTAssertFalse(result.text.contains("<span>")); XCTAssertFalse(result.text.contains("<p><br></p>"))
        let preserved = "<pre>"+source+"</pre><script>var x='<span></span>';</script>"
        XCTAssertEqual(EditorFormattingCleanup.clean(preserved,options:.init()).text,preserved)
        XCTAssertEqual(EditorFormattingCleanup.clean(source,options:.init(fonts:false,colors:false,emptyLines:false,redundantTags:false)).text,source)
    }
    func testResourcesCheckRangesMissingMediaAndNoScriptExamples() throws {
        let source = ##"<p>😀<a href="example.com">网页</a><a href="#target">段内</a><span id="target">目标</span><img src="ok.png"><audio src='missing.mp3'></audio>[sound:ok.mp3]</p><pre><img src="fake.png">[sound:fake.mp3]</pre>"##
        let results = EditorResourceCheck.references(source) { ["ok.png","ok.mp3"].contains($0) }
        XCTAssertEqual(results.count,5)
        XCTAssertTrue(results[0].problem); XCTAssertTrue(results[0].message.contains("https://"))
        XCTAssertFalse(results[1].problem); XCTAssertFalse(results[2].problem)
        XCTAssertTrue(results[3].problem); XCTAssertFalse(results[4].problem)
        for result in results { XCTAssertEqual((source as NSString).substring(with:result.range),result.value) }
        let remote = EditorResourceCheck.references(#"<a href="https://example.com/x">x</a><img src="https://example.com/a.png">"#) { _ in XCTFail("Remote references must not query local files"); return false }
        XCTAssertFalse(remote.contains(where:\.problem))
        let bad = EditorResourceCheck.references(#"<a href="javascript:alert(1)">bad</a>"#) { _ in false }
        XCTAssertTrue(bad[0].problem)
    }
    func testParagraphDifferenceDistinguishesAddedRemovedAndModifiedAndBoundsLongWork() {
        let diff = ParagraphDifference.make(before:"<p>共同</p><p>旧句</p><p>末尾</p>",after:"<p>共同</p><p>新句</p><p>末尾</p><p>新增</p>")
        XCTAssertEqual(diff.before.map(\.kind),[.unchanged,.modified,.unchanged])
        XCTAssertEqual(diff.after.map(\.kind),[.unchanged,.modified,.unchanged,.added])
        let deleted = ParagraphDifference.make(before:"a\n\nb",after:"a")
        XCTAssertEqual(deleted.before.last?.kind,.removed)
        let long = (0..<800).map { "第\($0)段" }.joined(separator:"\n")
        let coarse = ParagraphDifference.make(before:long,after:long+"\n新段")
        XCTAssertTrue(coarse.coarse); XCTAssertEqual(coarse.after.last?.kind,.added)
    }
    func testSearchBridgeJavaScriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        _ = context.evaluateScript("new Function(" + EditorPage.jsonString(EditorTextScript.source) + ")")
        XCTAssertNil(context.exception,context.exception?.toString() ?? "")
    }
}
