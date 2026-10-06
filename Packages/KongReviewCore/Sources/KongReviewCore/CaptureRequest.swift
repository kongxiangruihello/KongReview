import Foundation

/// 解析 `kongreview://add?...` 链接。
///
/// 这是第一期的“网页摘录”通道：浏览器书签小程序（bookmarklet）、快捷指令、
/// kongfetch 等任何能打开 URL 的工具都可以把选中的文字送进来，无需先写 Safari 扩展。
///
/// 支持参数：text（必填）、title、author、url、location、note、tags（逗号分隔）
///
/// 例：kongreview://add?text=学而时习之&title=论语&location=学而第一
public struct CaptureRequest: Equatable, Sendable {
    public var text: String
    public var title: String?
    public var author: String?
    public var url: String?
    public var location: String?
    public var note: String?
    public var tags: [String]

    public static let scheme = "kongreview"
    /// 改名前的旧链接（书签小程序、Drafts 动作里可能还在用），继续支持
    public static let legacySchemes: Set<String> = ["kongglean"]

    public static func isOurScheme(_ s: String?) -> Bool {
        guard let s = s?.lowercased() else { return false }
        return s == scheme || legacySchemes.contains(s)
    }

    /// 解析任意 kongreview:// 链接
    public enum Route: Equatable, Sendable {
        /// kongreview://add?text=...（text 必填）
        case add(CaptureRequest)
        /// kongreview://quick 或 kongreview://quick?text=...：打开快速录入浮窗，参数可选
        case quick(CaptureRequest?)
        /// kongreview://review：打开今日回顾
        case review
        /// kongreview://save?url=…：抓取并存档整篇网页
        case save(URL)
    }

    public static func route(for url: URL) -> Route? {
        guard isOurScheme(url.scheme) else { return nil }
        switch url.host?.lowercased() {
        case "add":
            return CaptureRequest(url: url).map(Route.add)
        case "quick":
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.host = "add"
            return .quick(comps?.url.flatMap(CaptureRequest.init(url:)))
        case "review":
            return .review
        case "save":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let raw = comps?.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
                  let target = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return nil }
            return .save(target)
        default:
            return nil
        }
    }

    public init(
        text: String,
        title: String? = nil,
        author: String? = nil,
        url: String? = nil,
        location: String? = nil,
        note: String? = nil,
        tags: [String] = []
    ) {
        self.text = text
        self.title = title
        self.author = author
        self.url = url
        self.location = location
        self.note = note
        self.tags = tags
    }

    public init?(url: URL) {
        guard Self.isOurScheme(url.scheme),
              url.host?.lowercased() == "add",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var dict: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let v = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                dict[item.name.lowercased()] = v
            }
        }
        guard let text = dict["text"] else { return nil }
        self.init(
            text: text,
            title: dict["title"],
            author: dict["author"],
            url: dict["url"],
            location: dict["location"],
            note: dict["note"],
            tags: dict["tags"].map(TagParser.parse) ?? []
        )
    }

    /// 书签小程序：把当前网页整篇存档到 KongReview
    public static let saveBookmarklet = "javascript:location.href='kongreview://save?url='+encodeURIComponent(location.href)"

    /// 规范化用户输入的网址：补上 https://，只接受 http/https
    public static func normalizeWebURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return u
    }

    /// 浏览器书签小程序：选中文字后点书签即可发送到 KongReview。
    public static let bookmarklet = """
    javascript:(()=>{const s=String(getSelection()).trim();if(!s){alert('请先选中文字');return}\
    const q=new URLSearchParams({text:s,title:document.title,url:location.href});\
    location.href='kongreview://add?'+q.toString().replace(/\\+/g,'%20')})()
    """
}
