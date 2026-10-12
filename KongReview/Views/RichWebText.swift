import SwiftUI
import WebKit
import KongReviewCore

/// 摘录、译文、按语的“所见即所得”显示：用网页内核渲染 Markdown / HTML，
/// 标题真的放大、列表有缩进、图片能显示，与记忆卡同一套样式。高度随内容自动变化，嵌在 ScrollView 里使用。
struct RichWebText: View {
    enum Style: String {
        case highlight      // 摘录原文：衬线大字
        case translation    // 译文：次要色
        case note           // 按语：小一号
        case preview        // 编辑面板里的预览
    }

    let text: String
    var style: Style = .preview
    /// 显示位置的标识（如“回顾-原文”）：内容变了也沿用上次的高度，避免跳动
    var slot: String
    @Environment(LibraryStore.self) private var store

    init(text: String, style: Style = .preview, slot: String? = nil) {
        self.text = text
        self.style = style
        self.slot = slot ?? style.rawValue
    }

    var body: some View {
        RichWebViewRep(shell: RichWebText.shell(style: style), content: RichWebText.bodyHTML(text), key: slot, store: store)
            .frame(height: max(18, WebHeights.shared.values[slot] ?? 24))
    }

    static func bodyHTML(_ text: String) -> String {
        // 网页图片经本地代理加载并缓存（http 图片、防盗链）
        ArticleImages.rewrite(Markdown.richHTML(text), base: "").html
    }

    /// 页面外壳（样式与量高度的脚本）；正文放进 #kr
    static func shell(style: Style) -> String {
        let font: String
        switch style {
        case .highlight: font = "font: 22px/1.75 \"Songti SC\", \"STSong\", serif;"
        case .translation: font = "font: 16px/1.7 -apple-system, \"PingFang SC\", sans-serif; color: var(--secondary);"
        case .note: font = "font: 14px/1.7 -apple-system, \"PingFang SC\", sans-serif;"
        case .preview: font = "font: 14px/1.7 -apple-system, \"PingFang SC\", sans-serif;"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; --text: #1d1d1f; --secondary: #6e6e73; --accent: #2f6fe4; }
        @media (prefers-color-scheme: dark) { :root { --text: #f2f2f7; --secondary: #a1a1a6; --accent: #6ea8ff; } }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { color: var(--text); \(font) -webkit-user-select: text; word-wrap: break-word; }
        p { margin: 0 0 .6em; } p:last-child { margin-bottom: 0; }
        h1 { font-size: 1.6em; margin: .3em 0 .4em; } h2 { font-size: 1.35em; margin: .3em 0 .4em; }
        h3, h4, h5, h6 { font-size: 1.15em; margin: .3em 0 .3em; }
        ul, ol { margin: .2em 0 .6em; padding-left: 1.4em; }
        blockquote { margin: .3em 0; padding-left: .8em; border-left: 3px solid rgba(128,128,128,.45); color: var(--secondary); }
        code { font: .85em ui-monospace, Menlo, monospace; background: rgba(128,128,128,.14); padding: 0 .2em; border-radius: 3px; }
        pre { background: rgba(128,128,128,.12); padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        a { color: var(--accent); }
        hr { border: none; border-top: 1px solid rgba(128,128,128,.35); margin: .8em 0; }
        </style></head><body><div id="kr"></div>
        <script>
        function krReport(){ var h = Math.ceil(document.getElementById('kr').getBoundingClientRect().height);
          window.webkit.messageHandlers.krHeight.postMessage(h); }
        function krSet(html){ var k = document.getElementById('kr'); k.innerHTML = html;
          k.querySelectorAll('img').forEach(function(i){ i.addEventListener('load', krReport); }); krReport(); }
        new ResizeObserver(krReport).observe(document.getElementById('kr'));
        </script></body></html>
        """
    }
}

/// 各网页内容的高度（按内容的哈希记录）。视图读取它来设高度，网页里的脚本量好后写进来。
@MainActor
@Observable
final class WebHeights {
    static let shared = WebHeights()
    var values: [String: CGFloat] = [:]
}

/// 不自己滚动的网页视图：滚轮事件交给外面的 ScrollView
final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct RichWebViewRep: NSViewRepresentable {
    let shell: String
    let content: String
    let key: String
    let store: LibraryStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassThroughWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "krHeight")
        LocalSchemeHandler.register(on: config, store: store)
        let wv = PassThroughWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateNSView(_ wv: PassThroughWebView, context: Context) {
        let c = context.coordinator
        c.key = key
        c.body = content
        if c.shell != shell {
            // 第一次或样式变了：载入外壳，载完再放正文
            c.shell = shell
            c.ready = false
            c.shown = nil
            wv.loadHTMLString(shell, baseURL: nil)
        } else if c.ready && c.shown != content {
            // 之后只替换正文（打字时实时预览不闪烁）
            c.show(in: wv)
        }
    }

    static func dismantleNSView(_ wv: PassThroughWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "krHeight")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var shell: String?
        var body = ""
        var shown: String?
        var ready = false
        var key = ""

        func show(in wv: WKWebView) {
            shown = body
            let data = (try? JSONSerialization.data(withJSONObject: [body])) ?? Data("[\"\"]".utf8)
            let arg = String(decoding: data, as: UTF8.self)
            wv.evaluateJavaScript("krSet(\(arg)[0]);", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            show(in: webView)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let h = (message.body as? NSNumber).map({ CGFloat($0.doubleValue) }), h > 0 else { return }
            if WebHeights.shared.values[key] != h { WebHeights.shared.values[key] = h }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
