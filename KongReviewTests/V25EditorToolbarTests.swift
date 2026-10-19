import AppKit
import CoreGraphics
import WebKit
import XCTest
import KongReviewCore
@testable import KongReview

@MainActor
final class V25EditorToolbarTests: XCTestCase {
    func testExternalFormattingRestoresSelectionAfterFocusLeavesLongEditor() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["kCGSessionOnConsoleKey"] as? Bool == true else {
            throw XCTSkip("工具栏交互回归需要已登录的 macOS 图形会话。")
        }
        _ = NSApplication.shared
        let ready = expectation(description: "编辑器就绪")
        let messages = FormattingMessageRecorder(ready)
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "krEditor")
        config.userContentController.addUserScript(WKUserScript(source: CardFormattingScript.source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 300), configuration: config)
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "krEditor") }
        view.loadHTMLString(EditorPage.page(text: "保留选区\n\n" + String(repeating: "长文段落\n\n", count: 80),
            mode: .card, toolbar: false, autoHeight: true), baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        _ = try await view.evaluateJavaScript("""
          var ed=document.getElementById('ed'); ed.focus();
          var r=document.createRange(); r.selectNodeContents(ed.firstChild);
          var s=window.getSelection(); s.removeAllRanges(); s.addRange(r);
          document.dispatchEvent(new Event('selectionchange')); ed.blur();
          window.krExternalCommand('bold');
          """)
        let value = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertTrue(value?.hasPrefix("**保留选区**") == true)
        _ = try await view.evaluateJavaScript("window.krExternalLink('https://example.com/reference')")
        let linked = try await view.evaluateJavaScript("krGetValue()") as? String
        XCTAssertTrue(linked?.contains("https://example.com/reference") == true)
        XCTAssertTrue(linked?.contains("长文段落") == true)
        let hasInnerToolbar = try await view.evaluateJavaScript("!!document.getElementById('tb')") as? Bool
        XCTAssertEqual(hasInnerToolbar, false)
    }
}

@MainActor
private final class FormattingMessageRecorder: NSObject, WKScriptMessageHandler {
    let ready: XCTestExpectation
    var received = false
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["type"] as? String == "ready", !received {
            received = true; ready.fulfill()
        }
    }
}
