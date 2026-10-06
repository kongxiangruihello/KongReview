import AppKit
import WebKit
import KongGleanCore

/// 用一个不显示的 WKWebView 打开网页，等页面（包括脚本渲染的内容）加载完后，
/// 注入 Mozilla Readability 提取正文。
/// 用浏览器内核而不是直接下载 HTML，是为了：自动处理 GBK 等编码、执行页面脚本（知乎等动态页面）、
/// 跟随跳转，并且图片、相对链接都会被转换成绝对地址。
@MainActor
final class WebArticleFetcher: NSObject, WKNavigationDelegate {

    enum FetchError: LocalizedError {
        case loadFailed(String)
        case badResult

        var errorDescription: String? {
            switch self {
            case .loadFailed(let m): return "网页打不开：\(m)"
            case .badResult: return "提取正文失败（脚本没有返回结果）。"
            }
        }
    }

    /// 最多等页面加载多久；超时后用已经加载出来的内容提取
    static let loadTimeout: TimeInterval = 20
    /// 页面加载完成后再等多久，让脚本渲染的正文出现
    static let settleDelay: TimeInterval = 1.2

    static func fetch(_ url: URL) async throws -> ArticleExtraction {
        let fetcher = WebArticleFetcher()
        return try await fetcher.run(url)
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    private func run(_ url: URL) async throws -> ArticleExtraction {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1600), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.navigationDelegate = self
        webView = wv
        defer {
            wv.stopLoading()
            wv.navigationDelegate = nil
            webView = nil
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            // 有些网页的广告、统计脚本一直加载不完；到时间就直接用已经有的内容
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak self] in
                self?.finish(nil)
            }
        }

        try await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))

        let script = WebScripts.readability + "\n;\n" + WebScripts.extract
        let json: String = try await withCheckedThrowingContinuation { c in
            wv.evaluateJavaScript(script) { result, error in
                if let error {
                    c.resume(throwing: error)
                } else if let s = result as? String {
                    c.resume(returning: s)
                } else {
                    c.resume(throwing: FetchError.badResult)
                }
            }
        }
        var extraction = try ArticleExtraction.decode(json)
        if extraction.url == nil || extraction.url == "about:blank" { extraction.url = url.absoluteString }
        return extraction
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 主文档已出来、只是子资源失败时，仍然可以提取
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        // 被页面自己的跳转打断（-999）不算失败，等下一次加载
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        finish(FetchError.loadFailed(error.localizedDescription))
    }
}
