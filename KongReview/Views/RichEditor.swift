import SwiftUI
import WebKit
import KongReviewCore

// MARK: - 所见即所得编辑器（1.2）

/// 所见即所得的 Markdown 编辑器：直接显示粗体、标题、列表、引用、图片，看不到 ** # 这些符号；
/// 快捷键与行首 Markdown 自动转换见 EditorPage；粘贴时保留格式。保存的仍是 Markdown（记忆卡必要时为 HTML）。
///
/// - autoHeight 为 true 时高度随内容增长（放在 ScrollView 里用，如回顾卡片上的就地编辑）；
///   为 false 时由外面给定高度，内容多了在编辑器里滚动（如编辑面板）。
/// - onSubmit：⌘↩；onCancel：Esc。
struct RichEditor: View {
    @Binding var text: String
    var mode: RichEditorMode = .markdown
    var font: RichEditorFont = .body
    var placeholder: String = ""
    var toolbar: Bool = true
    var autoHeight: Bool = false
    var minHeight: CGFloat = 70
    var focus: Bool = false
    /// 记录自动高度用的标识（同一界面里多个编辑器要不同）
    var slot: String = "editor"
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// 1.3：Tab / ⇧Tab 跳出编辑器（快速录入浮窗用）；nil 时 Tab 照常
    var onTab: ((Bool) -> Void)? = nil
    /// 1.3：外部控制焦点、全选
    var handle: RichEditorHandle? = nil
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let rep = RichEditorRep(text: $text, mode: mode, font: font, placeholder: placeholder, toolbar: toolbar,
                                autoHeight: autoHeight, focus: focus, slot: "rich-editor-" + slot,
                                onSubmit: onSubmit, onCancel: onCancel, onTab: onTab, handle: handle, store: store)
        if autoHeight {
            rep.frame(height: max(minHeight, WebHeights.shared.values["rich-editor-" + slot] ?? minHeight))
        } else {
            rep.frame(minHeight: minHeight)
        }
    }
}

/// 编辑器的外框（圆角、细边），与应用的纸色设计一致
struct RichEditorFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ReviewPalette.hair))
    }
}

extension View {
    func richEditorFrame() -> some View { modifier(RichEditorFrame()) }
}

/// 编辑器用的网页视图：自动高度时把滚轮交给外面的 ScrollView
final class EditorWebView: WKWebView {
    var passScroll = false
    override func scrollWheel(with event: NSEvent) {
        if passScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

struct RichEditorRep: NSViewRepresentable {
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
    let store: LibraryStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorWebView {
        let c = context.coordinator
        c.parent = self
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(c), name: "krEditor")
        LocalSchemeHandler.register(on: config, store: store)
        let wv = EditorWebView(frame: .zero, configuration: config)
        c.webView = wv
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
        wv.loadHTMLString(EditorPage.page(text: text, mode: mode, font: font, placeholder: placeholder,
                                          toolbar: toolbar, autoHeight: autoHeight, tabOut: onTab != nil), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: EditorWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // 外部换了内容（如打开另一条摘录）：整体替换编辑区；自己刚发出的改动不重复载入
        if text != c.lastValue {
            c.lastValue = text
            let (html, isHTML) = EditorPage.displayHTML(for: text, mode: mode)
            let arg = EditorPage.jsonString(html)
            if c.ready { wv.evaluateJavaScript("krSetContent(\(arg), \(isHTML));", completionHandler: nil) }
            else { c.pending = "krSetContent(\(arg), \(isHTML));" }
        }
    }

    static func dismantleNSView(_ wv: EditorWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "krEditor")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichEditorRep?
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
            if let js = pending { webView.evaluateJavaScript(js, completionHandler: nil); pending = nil }
            if wantsFocus {
                wantsFocus = false
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

/// 1.3：从外面（AppKit 浮窗）控制编辑器：设焦点、全选
@MainActor
final class RichEditorHandle {
    weak var webView: WKWebView?
    weak var coordinator: RichEditorRep.Coordinator?

    /// 让编辑器成为键盘焦点；selectAll 为 true 时全选内容（直接打字即替换）
    func focus(selectAll: Bool = false) {
        guard let wv = webView else { return }
        wv.window?.makeFirstResponder(wv)
        let js = selectAll ? "krSelectAll();" : "krFocus();"
        if coordinator?.ready == true {
            wv.evaluateJavaScript(js, completionHandler: nil)
        } else {
            // 页面还没载入完：载入后再做
            coordinator?.wantsFocus = true
            coordinator?.pendingSelectAll = selectAll
        }
    }
}
