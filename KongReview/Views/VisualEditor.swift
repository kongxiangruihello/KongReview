import SwiftUI
import WebKit
import KongReviewCore

final class EditorWebView: WKWebView {
    var passScroll = false
    override func scrollWheel(with event: NSEvent) {
        if passScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

struct VisualEditorRep: NSViewRepresentable {
    @Binding var text: String
    let mode: RichEditorMode
    let font: RichEditorFont
    let placeholder: String
    let toolbar: Bool
    let autoHeight: Bool
    let focus: Bool
    let slot: String
    let onSubmit: (() -> Void)?
    let onCancel: (() -> Void)?
    let onTab: ((Bool) -> Void)?
    let handle: RichEditorHandle?
    let formatting: CardFormattingState?
    let fieldName: String
    let store: LibraryStore?
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorWebView {
        let c = context.coordinator
        c.parent = self
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(c), name: "krEditor")
        config.userContentController.addUserScript(WKUserScript(source:EditorTextScript.source,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        if formatting != nil {
            config.userContentController.addUserScript(WKUserScript(source: CardFormattingScript.source,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        LocalSchemeHandler.register(on: config, store: store)
        let wv = EditorWebView(frame: .zero, configuration: config)
        c.webView = wv
        formatting?.attach(slot: slot, name: fieldName, webView: wv)
        wv.passScroll = autoHeight
        // 1.8：同一个位置上次留下的高度（可能是另一张卡的长内容）不沿用，等网页量好再定
        if autoHeight {
            let key = slot
            DispatchQueue.main.async { [weak c] in
                // 网页已经报过高度就不要再清掉（否则高度不变时不会再报，编辑器会缩回最小高度）
                if c?.gotHeight != true { WebHeights.shared.values[key] = nil }
            }
        }
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = c
        c.lastValue = text
        c.wantsFocus = focus
        handle?.webView = wv
        handle?.coordinator = c
        handle?.valueReader = { [weak c] in c?.parent?.text }
        wv.loadHTMLString(EditorPage.page(text: HTMLSourceCodec.editable(text), mode: .card, font: font, placeholder: placeholder,
                                          toolbar: toolbar, autoHeight: autoHeight, tabOut: onTab != nil), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: EditorWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.ready { wv.evaluateJavaScript("document.getElementById('ed').contentEditable = \(enabled ? "'true'" : "'false'");", completionHandler:nil) }
        formatting?.attach(slot: slot, name: fieldName, webView: wv)
        // 外部换了内容（如打开另一条摘录）：整体替换编辑区；自己刚发出的改动不重复载入
        if text != c.lastValue {
            c.lastValue = text
            let (html, isHTML) = EditorPage.displayHTML(for: HTMLSourceCodec.editable(text), mode: .card)
            let arg = EditorPage.jsonString(html)
            if c.ready { wv.evaluateJavaScript("krSetContent(\(arg), \(isHTML));", completionHandler: nil) }
            else { c.pending = "krSetContent(\(arg), \(isHTML));" }
        }
    }

    static func dismantleNSView(_ wv: EditorWebView, coordinator: Coordinator) {
        if let parent = coordinator.parent { parent.formatting?.detach(slot: parent.slot, webView: wv) }
        if coordinator.parent?.handle?.webView === wv {
            coordinator.parent?.handle?.webView = nil
            coordinator.parent?.handle?.coordinator = nil
            if coordinator.parent?.handle?.textView == nil { coordinator.parent?.handle?.valueReader = nil }
        }
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "krEditor")
        coordinator.parent = nil
        wv.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: VisualEditorRep?
        weak var webView: WKWebView?
        var lastValue = ""
        var ready = false
        var wantsFocus = false
        var pendingSelectAll = false
        var pending: String?
        /// 1.8：网页是否已经报过内容高度
        var gotHeight = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            editorReady(in: webView)
        }

        /// 编辑器脚本完成初始化就可以同步原文；didFinish 可能还在等远程图片。
        private func editorReady(in webView: WKWebView) {
            guard !ready else { return }
            ready = true
            webView.evaluateJavaScript("document.getElementById('ed').contentEditable = \(parent?.enabled == false ? "'false'" : "'true'");", completionHandler:nil)
            if let js = pending { webView.evaluateJavaScript(js, completionHandler: nil); pending = nil }
            if wantsFocus {
                wantsFocus = false
                if let parent { parent.formatting?.activate(parent.slot) }
                webView.window?.makeFirstResponder(webView)
                webView.evaluateJavaScript(pendingSelectAll ? "krSelectAll();" : "krFocus();", completionHandler: nil)
                pendingSelectAll = false
            }
        }

        /// 只允许载入编辑器页面本身；拖进来的文件、点到的链接都不在编辑器里打开
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if !ready, action.navigationType == .other { return .allow }
            if action.targetFrame?.isMainFrame == false { return .allow }
            return .cancel
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let p = parent else { return }
            switch type {
            case "find":
                p.handle?.showsFind = true
            case "focus":
                p.formatting?.activate(p.slot)
            case "external-link":
                p.formatting?.activate(p.slot)
                p.formatting?.linkURL = ""
                p.formatting?.linkError = nil
                p.formatting?.showsLink = true
            case "ready":
                if let webView { editorReady(in: webView) }
            case "change":
                guard ready else { return }
                guard let v = body["value"] as? String else { return }
                lastValue = v
                if p.text != v { p.text = v }
            case "height":
                guard let h = (body["value"] as? NSNumber).map({ CGFloat($0.doubleValue) }), h > 0 else { return }
                gotHeight = true
                if WebHeights.shared.values[p.slot] != h { WebHeights.shared.values[p.slot] = h }
            case "submit":
                p.onSubmit?()
            case "cancel":
                p.onCancel?()
            case "tab", "backtab":
                p.onTab?(type == "backtab")
            case "open":
                if let s = body["value"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            default:
                break
            }
        }
    }
}

