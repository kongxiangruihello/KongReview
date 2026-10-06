import Foundation

/// 解析 `kongglean://add?...` 链接。
///
/// 这是第一期的“网页摘录”通道：浏览器书签小程序（bookmarklet）、快捷指令、
/// kongfetch 等任何能打开 URL 的工具都可以把选中的文字送进来，无需先写 Safari 扩展。
///
/// 支持参数：text（必填）、title、author、url、location、note、tags（逗号分隔）
///
/// 例：kongglean://add?text=学而时习之&title=论语&location=学而第一
public struct CaptureRequest: Equatable, Sendable {
    public var text: String
    public var title: String?
    public var author: String?
    public var url: String?
    public var location: String?
    public var note: String?
    public var tags: [String]

    public static let scheme = "kongglean"

    /// 解析任意 kongglean:// 链接
    public enum Route: Equatable, Sendable {
        /// kongglean://add?text=...（text 必填）
        case add(CaptureRequest)
        /// kongglean://quick 或 kongglean://quick?text=...：打开快速录入浮窗，参数可选
        case quick(CaptureRequest?)
        /// kongglean://review：打开今日回顾
        case review
    }

    public static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "add":
            return CaptureRequest(url: url).map(Route.add)
        case "quick":
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.host = "add"
            return .quick(comps?.url.flatMap(CaptureRequest.init(url:)))
        case "review":
            return .review
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
        guard url.scheme?.lowercased() == Self.scheme,
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

    /// 浏览器书签小程序：选中文字后点书签即可发送到 KongGlean。
    public static let bookmarklet = """
    javascript:(()=>{const s=String(getSelection()).trim();if(!s){alert('请先选中文字');return}\
    const q=new URLSearchParams({text:s,title:document.title,url:location.href});\
    location.href='kongglean://add?'+q.toString().replace(/\\+/g,'%20')})()
    """
}
