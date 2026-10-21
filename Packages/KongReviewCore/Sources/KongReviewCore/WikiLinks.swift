import Foundation

// MARK: - 4.1：札记之间的 [[题目]] 链接
//
// 写法与 Obsidian 的内部链接一致：[[题目]] 或 [[题目|显示文字]]。
// 链接按题目匹配（去首尾空白、连续空白合一、繁简与全半角归一），由应用解析成札记编号存表；
// 对方改题目时，应用把各处的 [[旧题目]] 改写为 [[新题目]]。

public enum WikiLinks {
    static let pattern = #"\[\[([^\[\]\n|]{1,200})(?:\|([^\[\]\n]{1,200}))?\]\]"#

    public struct Match: Equatable, Sendable {
        public var title: String
        public var display: String
    }

    /// 正文中的全部链接（按出现顺序，题目去重）
    public static func links(in text: String) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [Match] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let title = normalize(unescape(ns.substring(with: m.range(at: 1))))
            guard !title.isEmpty else { continue }
            let display = m.range(at: 2).location == NSNotFound ? title : normalize(unescape(ns.substring(with: m.range(at: 2))))
            if seen.insert(key(title)).inserted { out.append(Match(title: title, display: display)) }
        }
        return out
    }

    public static func titles(in text: String) -> [String] { links(in: text).map(\.title) }

    /// 比较用的键：去首尾空白、空白合一、繁简与全半角归一、英文小写
    public static func key(_ title: String) -> String { ChineseFold.fold(normalize(title)) }

    public static func normalize(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 把已渲染的 HTML 中的 [[题目]] 换成链接：能找到的指向 kongreview://note/编号，找不到的指向 kongreview://note-new?title=…
    public static func render(_ html: String, resolve: (String) -> Int64?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return html }
        let ns = html as NSString
        var out = html
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let title = normalize(unescape(ns.substring(with: m.range(at: 1))))
            guard !title.isEmpty else { continue }
            let display = m.range(at: 2).location == NSNotFound ? title : normalize(unescape(ns.substring(with: m.range(at: 2))))
            let anchor: String
            if let id = resolve(title) {
                anchor = "<a class=\"kr-note-link\" href=\"kongreview://note/\(id)\">\(escape(display))</a>"
            } else {
                let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? ""
                anchor = "<a class=\"kr-note-missing\" href=\"kongreview://note-new?title=\(q)\" title=\"尚无此札记，点击新建\">\(escape(display))（未建）</a>"
            }
            out = (out as NSString).replacingCharacters(in: m.range, with: anchor)
        }
        return out
    }

    /// 改题目：把 [[旧题目]]、[[旧题目|显示]] 改写为新题目（按归一后的题目匹配），返回改写后的正文
    public static func rename(_ text: String, from old: String, to new: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let oldKey = key(old), newTitle = escape(normalize(new))
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard key(unescape(ns.substring(with: m.range(at: 1)))) == oldKey else { continue }
            let tail = m.range(at: 2).location == NSNotFound ? "" : "|" + ns.substring(with: m.range(at: 2))
            out = (out as NSString).replacingCharacters(in: m.range, with: "[[" + newTitle + tail + "]]")
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
