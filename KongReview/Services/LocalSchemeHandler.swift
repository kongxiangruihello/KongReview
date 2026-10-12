import Foundation
import WebKit
import KongReviewCore

/// 阅读器与记忆卡里的图片都走这里：
/// - kr-img://img?u=原图&r=来源页：网页存档的图片。先查本地缓存；没有就下载（带上合适的 Referer，
///   绕过多数站点的防盗链；微信图片不带 Referer），成功后存进数据库，以后离线也能看。
/// - kr-media://media/文件名：从 Anki 导入的图片等媒体。
@MainActor
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var store: LibraryStore?
    private var active = Set<ObjectIdentifier>()

    init(store: LibraryStore?) {
        self.store = store
    }

    static func register(on config: WKWebViewConfiguration, store: LibraryStore?) {
        let h = LocalSchemeHandler(store: store)
        config.setURLSchemeHandler(h, forURLScheme: ArticleImages.scheme)
        config.setURLSchemeHandler(h, forURLScheme: "kr-media")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let key = ObjectIdentifier(task)
        active.insert(key)

        if url.scheme == "kr-media" {
            let name = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let decoded = name.removingPercentEncoding ?? name
            if let data = try? store?.db.media(named: decoded) {
                respond(task, url: url, data: data, mime: Self.mime(for: decoded))
            } else {
                fail(task)
            }
            return
        }

        guard let parsed = ArticleImages.parse(url) else { fail(task); return }
        let image = parsed.image, referer = parsed.referer
        if let cached = try? store?.db.cachedImage(image.absoluteString) {
            respond(task, url: url, data: cached.data, mime: cached.mime ?? Self.mime(for: image.lastPathComponent))
            return
        }
        Task { @MainActor in
            let result = await Self.download(image, referer: referer)
            guard self.active.contains(key) else { return }
            if let result {
                self.store?.db.cacheImage(image.absoluteString, data: result.0, mime: result.1)
                self.respond(task, url: url, data: result.0, mime: result.1)
            } else {
                self.fail(task)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)",
                                                  "Cache-Control": "max-age=31536000"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return }
        task.didFailWithError(URLError(.resourceUnavailable))
    }

    /// 先按设定带 Referer 下载；失败或返回的不是图片时，换另一种 Referer 再试一次
    nonisolated static func download(_ url: URL, referer: String?) async -> (Data, String)? {
        let first = ArticleImages.sendsReferer(for: url) ? referer : nil
        if let r = await fetch(url, referer: first) { return r }
        return await fetch(url, referer: first == nil ? referer : nil)
    }

    nonisolated static func fetch(_ url: URL, referer: String?) async -> (Data, String)? {
        var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("image/avif,image/webp,image/png,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
        let mime = http.mimeType ?? mime(for: url.lastPathComponent)
        guard mime.hasPrefix("image/") || mime == "application/octet-stream" else { return nil }
        return (data, mime)
    }

    nonisolated static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
