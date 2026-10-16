import AppKit
import CoreGraphics
import WebKit
import XCTest
import KongReviewCore

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
}

@MainActor
private final class EditorMessageRecorder: NSObject, WKScriptMessageHandler {
    private let ready: XCTestExpectation
    private(set) var receivedReady = false
    init(ready: XCTestExpectation) { self.ready = ready }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "ready", !receivedReady else { return }
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
