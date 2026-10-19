import AppKit
import CoreGraphics
import WebKit
import XCTest
import KongReviewCore
@testable import KongReview

/// 使用真正的 WebKit 检查初始化和长文布局；没有图形会话的 CI 明确跳过。
@MainActor
final class EditorWebViewTests: XCTestCase {
    private func requireDesktopSession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["kCGSessionOnConsoleKey"] as? Bool == true else {
            throw XCTSkip("WebKit 编辑器回归需要已登录的 macOS 图形会话。")
        }
        _ = NSApplication.shared
    }

    func testPasteChoicePreservesFormattingInEmptyFieldAndOutlineKeepsContent() async throws {
        try requireDesktopSession()
        let ready = expectation(description:"录入编辑器就绪")
        let messages = EditorMessageRecorder(ready:ready)
        let pasted = expectation(description:"粘贴请求")
        messages.pasteExpectation = pasted
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages,name:"krEditor")
        config.userContentController.addUserScript(WKUserScript(source:EditorIntakeScript.source,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        let view = WKWebView(frame:NSRect(x:0,y:0,width:560,height:240),configuration:config)
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName:"krEditor") }
        view.loadHTMLString(EditorPage.page(text:"",mode:.card),baseURL:nil)
        await fulfillment(of:[ready],timeout:10)
        guard messages.receivedReady else { return }
        _ = try await view.evaluateJavaScript("""
            krFocus();var dt=new DataTransfer();
            dt.setData('text/html','<p style="font-size:28px;color:red" onclick="bad()">格式保留<strong>粗体</strong></p><script>bad()</script>');
            dt.setData('text/plain','格式保留粗体');
            document.getElementById('ed').dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));
        """)
        await fulfillment(of:[pasted],timeout:3)
        let proposal = try XCTUnwrap(messages.pastes.first)
        let html = try XCTUnwrap(proposal["html"] as? String),original = try XCTUnwrap(proposal["original"] as? String)
        XCTAssertFalse(html.contains("onclick"));XCTAssertFalse(html.contains("<script"))
        let adopted = try await view.evaluateJavaScript("krEditorPasteApply(\(EditorPage.jsonString(html)),\(EditorPage.jsonString(original)))") as? Bool
        XCTAssertEqual(adopted,true)
        let storedValue = try await view.evaluateJavaScript("krGetValue()") as? String
        let stored = try XCTUnwrap(storedValue)
        XCTAssertTrue(stored.contains("font-size"));XCTAssertTrue(stored.contains("<strong>粗体</strong>"))
        _ = try await view.evaluateJavaScript("document.execCommand('undo');krFlush()")
        let undone = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(undone,"")
        _ = try await view.evaluateJavaScript("krSetContent('<h1>大标题</h1><p>正文</p><h2>小标题</h2>',true)")
        let before = try await view.evaluateJavaScript("krGetValue()") as? String
        let outline = try await view.evaluateJavaScript("krEditorOutline()") as? [String:Any]
        XCTAssertEqual((outline?["headings"] as? [[String:Any]])?.count,2)
        let snapshot = try XCTUnwrap(outline?["original"] as? String)
        let location = try await view.evaluateJavaScript("krEditorOutlineGo(1,\(EditorPage.jsonString(snapshot)))") as? [String:Any]
        XCTAssertNotNil(location?["y"])
        let after = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(after,before,"目录定位不能修改正文")
    }

    func testFieldSearchReplacementPreservesHTMLAndUndo() async throws {
        try requireDesktopSession()
        let ready = expectation(description:"查找编辑器就绪")
        let messages = EditorMessageRecorder(ready:ready)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages,name:"krEditor")
        config.userContentController.addUserScript(WKUserScript(source:EditorTextScript.source,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        let view = WKWebView(frame:NSRect(x:0,y:0,width:560,height:240),configuration:config)
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName:"krEditor") }
        view.loadHTMLString(EditorPage.page(text:"<p>Alpha <strong>Beta</strong> Alpha</p>",mode:.card),baseURL:nil)
        await fulfillment(of:[ready],timeout:10)
        guard messages.receivedReady else { return }
        let before = try await view.evaluateJavaScript("krFlush()") as? String
        let matches = try await view.evaluateJavaScript("krEditorFind('Alpha',false,0)") as? [String:Any]
        XCTAssertEqual(matches?["count"] as? Int,2)
        let highlighted = try await view.evaluateJavaScript("krFlush()") as? String
        XCTAssertEqual(highlighted,before,"查找高亮不能写入正文")
        let preview = try await view.evaluateJavaScript("krEditorReplacementPreview('Alpha',false,'Gamma')") as? [String:Any]
        let original = try XCTUnwrap(preview?["original"] as? String), proposed = try XCTUnwrap(preview?["proposed"] as? String)
        XCTAssertTrue(proposed.contains("<strong>Beta</strong>"))
        let applied = try await view.evaluateJavaScript("krEditorApply(\(EditorPage.jsonString(proposed)),\(EditorPage.jsonString(original)))") as? Bool
        XCTAssertEqual(applied,true)
        let replaced = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertTrue(replaced?.contains("Gamma <strong>Beta</strong> Gamma") == true)
        _ = try await view.evaluateJavaScript("document.execCommand('undo'); krFlush();")
        let undone = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(undone,before)
        let rejected = try await view.evaluateJavaScript("krEditorApply('<p>不应覆盖</p>','stale')") as? Bool
        XCTAssertEqual(rejected,false)
    }

    func testVisualSourceRoundTripFlushAndCloze() async throws {
        try requireDesktopSession()
        let ready = expectation(description:"文字编辑器就绪")
        let messages = EditorMessageRecorder(ready:ready)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages,name:"krEditor")
        let view = WKWebView(frame:NSRect(x:0,y:0,width:560,height:240),configuration:config)
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName:"krEditor") }
        let source = "<p>原文<strong>需要记忆</strong>末尾</p>"
        view.loadHTMLString(EditorPage.page(text:HTMLSourceCodec.editable(source),mode:.card),baseURL:nil)
        await fulfillment(of:[ready],timeout:10)
        guard messages.receivedReady else { return }
        _ = try await view.evaluateJavaScript("krFlush();")
        XCTAssertTrue(messages.changes.isEmpty,"仅查看或切换不能改写原始 HTML")
        _ = try await view.evaluateJavaScript("""
          var ed=document.getElementById('ed'); ed.focus();
          var r=document.createRange();r.selectNodeContents(ed.querySelector('strong'));
          var s=window.getSelection();s.removeAllRanges();s.addRange(r);
        """)
        let wrapped = try await view.evaluateJavaScript(VisualClozeScript.wrap(number:1)) as? Bool
        XCTAssertEqual(wrapped,true)
        let flushed = try await view.evaluateJavaScript("krFlush()")
        let edited = try XCTUnwrap(flushed as? String)
        XCTAssertTrue(edited.contains("{{c1::需要记忆}}"))
        XCTAssertTrue(edited.contains("<strong>"))
        let replacement = "<p>源码新增<em>最后几个字</em></p>"
        _ = try await view.evaluateJavaScript("krSetContent(\(EditorPage.jsonString(replacement)),true)")
        let rendered = try await view.evaluateJavaScript("document.getElementById('ed').textContent") as? String
        XCTAssertEqual(rendered,"源码新增最后几个字")
        let result = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(result,replacement)
    }

    func testLongOriginalTextStaysCompleteAndToolbarStaysVisible() async throws {
        try requireDesktopSession()
        let ready = expectation(description: "编辑器脚本就绪")
        let messages = EditorMessageRecorder(ready: ready)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "krEditor")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 280), configuration: config)
        defer {
            view.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "krEditor")
        }
        let original = (1...400).map { "第\($0)段：这是完整原文，长文编辑时不能丢失尾部。" }.joined(separator: "\n\n")
        view.loadHTMLString(EditorPage.page(text: original, mode: .markdown), baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        guard messages.receivedReady else { return }

        let initial = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(initial, original)
        let geometry = try await view.evaluateJavaScript("""
            (function () {
              var ed = document.getElementById('ed'), tb = document.getElementById('tb');
              ed.scrollTop = ed.scrollHeight;
              return { scroll: ed.scrollTop, overflow: ed.scrollHeight > ed.clientHeight,
                       toolbarTop: tb.getBoundingClientRect().top, bodyHeight: document.body.clientHeight };
            })()
            """) as? [String: Any]
        XCTAssertEqual(geometry?["overflow"] as? Bool, true)
        XCTAssertGreaterThan((geometry?["scroll"] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertEqual((geometry?["toolbarTop"] as? NSNumber)?.doubleValue ?? -1, 0, accuracy: 1)
        XCTAssertLessThanOrEqual((geometry?["bodyHeight"] as? NSNumber)?.doubleValue ?? .infinity, 280)

        let replacement = "另一条摘录的原文\n\n**尾部也完整**"
        _ = try await view.evaluateJavaScript("krSetContent(\(EditorPage.jsonString(EditorPage.displayHTML(for: replacement, mode: .markdown).html)), false)")
        let replaced = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(replaced, replacement)
    }

    func testEditorIsReadyBeforeSlowImageFinishesLoading() async throws {
        try requireDesktopSession()
        let ready = expectation(description: "不等待远程图片即可编辑原文")
        let imageRequested = expectation(description: "图片请求保持未完成")
        let messages = EditorMessageRecorder(ready: ready)
        let images = PendingEditorImageHandler(requested: imageRequested)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "krEditor")
        config.setURLSchemeHandler(images, forURLScheme: "kr-test-pending")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 280), configuration: config)
        defer {
            view.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "krEditor")
        }
        let original = "这是原文开头\n\n![](kr-test-pending://image)\n\n这是原文结尾"
        view.loadHTMLString(EditorPage.page(text: original, mode: .markdown), baseURL: nil)
        await fulfillment(of: [ready, imageRequested], timeout: 10)
        guard messages.receivedReady else { return }
        XCTAssertTrue(view.isLoading, "图片仍未完成时，编辑器已经通知应用就绪。")
        let value = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(value, original)
    }

    func testCardEditorHeightGrowsAndShrinksIndependentlyOfViewport() async throws {
        try requireDesktopSession()
        let ready = expectation(description: "自动高度编辑器就绪")
        let messages = EditorMessageRecorder(ready: ready)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "krEditor")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 280), configuration: config)
        defer {
            view.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "krEditor")
        }
        let short = "简短问题"
        view.loadHTMLString(EditorPage.page(text: short, mode: .card, autoHeight: true), baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        guard messages.receivedReady else { return }

        func contentHeight() async throws -> Double {
            let result = try await view.evaluateJavaScript("document.body.getBoundingClientRect().height")
            return try XCTUnwrap(result as? NSNumber).doubleValue
        }
        func replace(_ text: String) async throws {
            let html = EditorPage.displayHTML(for: text, mode: .card).html
            _ = try await view.evaluateJavaScript("krSetContent(\(EditorPage.jsonString(html)), false)")
        }

        let shortHeight = try await contentHeight()
        XCTAssertLessThan(shortHeight, 160)
        let long = (1...40).map { "第\($0)段：" + String(repeating: "记忆卡的编辑区域应当随着内容增减。", count: 5) }.joined(separator: "\n\n")
        try await replace(long)
        let longHeight = try await contentHeight()
        XCTAssertGreaterThan(longHeight, 280)

        // SwiftUI 会把网页视图拉高；删减内容仍应量出实际短内容高度。
        view.setFrameSize(NSSize(width: 560, height: longHeight))
        try await replace(short)
        let shrunkHeight = try await contentHeight()
        XCTAssertEqual(shrunkHeight, shortHeight, accuracy: 1)
        XCTAssertLessThan(shrunkHeight, longHeight)
        let finalValue = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertEqual(finalValue, short)
    }
}

@MainActor
private final class EditorMessageRecorder: NSObject, WKScriptMessageHandler {
    private let ready: XCTestExpectation
    private(set) var receivedReady = false
    private(set) var changes: [String] = []
    var pasteExpectation: XCTestExpectation?
    private(set) var pastes: [[String:Any]] = []
    init(ready: XCTestExpectation) { self.ready = ready }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "paste-choice" { pastes.append(body); pasteExpectation?.fulfill() }
        if body["type"] as? String == "change", let value = body["value"] as? String { changes.append(value) }
        guard body["type"] as? String == "ready", !receivedReady else { return }
        receivedReady = true
        ready.fulfill()
    }
}

@MainActor
private final class PendingEditorImageHandler: NSObject, WKURLSchemeHandler {
    private let requested: XCTestExpectation
    private var receivedRequest = false
    private var pending: [WKURLSchemeTask] = []
    init(requested: XCTestExpectation) { self.requested = requested }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        pending.append(urlSchemeTask)
        if !receivedRequest {
            receivedRequest = true
            requested.fulfill()
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeAll { $0 === urlSchemeTask }
    }
}
