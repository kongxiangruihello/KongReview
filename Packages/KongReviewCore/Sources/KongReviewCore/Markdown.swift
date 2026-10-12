import Foundation

/// 轻量 Markdown → HTML（用于记忆卡正反面、摘录的富文本显示）。
/// 支持：标题 #、段落、换行、**粗体**、*斜体*、`代码`、[链接](url)、> 引用、- / 1. 列表、--- 分隔线、``` 代码块。
/// 如果文本本身已是 HTML（以标签开头，如从 Anki 导入的卡片），原样返回。
public enum Markdown {

    public static func looksLikeHTML(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<") else {
            // Anki 字段常见：文字中夹 <br>、<b>、<div>
            return t.range(of: #"<(br|div|b|i|u|span|img|p|ul|ol|li|table|sub|sup|font)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return true
    }

    public static func html(_ source: String) -> String {
        if looksLikeHTML(source) { return source }
        var out: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var inCode = false
        var code: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>")
                paragraph = []
            }
        }
        func flushList() {
            if let t = listTag { out.append("</\(t)>"); listTag = nil }
        }
        func flushQuote() {
            if !quote.isEmpty {
                out.append("<blockquote>" + quote.map(inline).joined(separator: "<br>") + "</blockquote>")
                quote = []
            }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }

            if trimmed.isEmpty { flushAll(); continue }

            if let level = headingLevel(trimmed) {
                flushAll()
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                flushAll()
                out.append("<hr>")
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(trimmed) {
                flushParagraph(); flushQuote()
                if listTag != item.tag { flushList(); out.append("<\(item.tag)>"); listTag = item.tag }
                out.append("<li>\(inline(item.text))</li>")
                continue
            }
            flushList(); flushQuote()
            paragraph.append(trimmed)
        }
        if inCode { out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushAll()
        return out.joined(separator: "\n")
    }

    static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for ch in s { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), s.count > n, s[s.index(s.startIndex, offsetBy: n)] == " " else { return nil }
        return n
    }

    static func listItem(_ s: String) -> (tag: String, text: String)? {
        for bullet in ["- ", "* ", "+ ", "・", "• "] where s.hasPrefix(bullet) {
            return ("ul", String(s.dropFirst(bullet.count)))
        }
        // 1. 或 1、
        var digits = ""
        for ch in s { if ch.isNumber && ch.isASCII { digits.append(ch) } else { break } }
        if !digits.isEmpty {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix("、") {
                return ("ol", String(rest.dropFirst(rest.hasPrefix(". ") ? 2 : 1)))
            }
        }
        return nil
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 行内：先转义，再处理 `代码`、**粗体**、*斜体*、[文字](链接)
    static func inline(_ s: String) -> String {
        var t = escape(s)
        t = replace(t, #"`([^`]+)`"#, "<code>$1</code>")
        t = replace(t, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        t = replace(t, #"(?<!\*)\*([^*\s][^*]*?)\*(?!\*)"#, "<em>$1</em>")
        t = replace(t, #"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">")
        t = replace(t, #"(?<!!)\[([^\]]+)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        t = replace(t, #"~~([^~]+)~~"#, "<del>$1</del>")
        return t
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// 去掉 HTML 标签得到纯文本（用于搜索、预览、Anki 字段）
    public static func plainText(fromHTML html: String) -> String {
        var t = html
        t = replace(t, #"(?i)<br\s*/?>"#, "\n")
        t = replace(t, #"(?i)</(p|div|li|h[1-6]|blockquote|tr)>"#, "\n")
        t = replace(t, #"<[^>]+>"#, "")
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return ArticleText.normalize(t)
    }

    /// 摘录、译文、按语的完整渲染：先把夹杂的 HTML 标签换成 Markdown，再整体转 HTML（标题、列表、图片都按真实样式显示）
    public static func richHTML(_ source: String) -> String {
        html(markdown(fromHTMLFragments: source))
    }

    // MARK: 混排的 HTML 片段 → Markdown

    /// 文本里是否夹有 HTML 标签（`a < b` 这类不算）
    public static func containsHTMLTag(_ s: String) -> Bool {
        s.range(of: #"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?/?>"#, options: .regularExpression) != nil
    }

    /// 摘录里常混着从网页复制来的 HTML（<h1>、<b>、<a href>、<br>、<p>…），而 SwiftUI 的 Text 不认 HTML。
    /// 这里把常见标签换成等价的 Markdown，其余标签去掉、实体解码，再交给 Markdown 显示：
    /// 标题 <h1>–<h6> 与 <b>/<strong> → **粗体**；<i>/<em> → *斜体*；<code> → `代码`；
    /// <a href> → [文字](网址)；<br>、</p>、</div>、</li> → 换行；<li> → “- ”；<blockquote> → “> ”；<hr> → ---
    public static func markdown(fromHTMLFragments html: String) -> String {
        guard containsHTMLTag(html) else { return html }
        var t = html
        let rules: [(String, String)] = [
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)<hr\s*/?>"#, "\n---\n"),
            (#"(?is)<(h[1-6])\b[^>]*>(.*?)</\1\s*>"#, "**$2**"),
            (#"(?is)<(b|strong)\b[^>]*>(.*?)</\1\s*>"#, "**$2**"),
            (#"(?is)<(i|em)\b[^>]*>(.*?)</\1\s*>"#, "*$2*"),
            (#"(?is)<code\b[^>]*>(.*?)</code\s*>"#, "`$1`"),
            (#"(?is)<a\b[^>]*?href\s*=\s*"([^"]+)"[^>]*>(.*?)</a\s*>"#, "[$2]($1)"),
            (#"(?is)<a\b[^>]*?href\s*=\s*'([^']+)'[^>]*>(.*?)</a\s*>"#, "[$2]($1)"),
            (#"(?is)<img\b[^>]*?src\s*=\s*"([^"]+)"[^>]*>"#, "![]($1)"),
            (#"(?is)<img\b[^>]*?src\s*=\s*'([^']+)'[^>]*>"#, "![]($1)"),
            (#"(?i)<li\b[^>]*>"#, "\n- "),
            (#"(?i)<blockquote\b[^>]*>"#, "\n> "),
            (#"(?i)</li\s*>"#, ""),
            (#"(?i)</(p|div|tr|blockquote|ul|ol|table|h[1-6])\s*>"#, "\n"),
            (#"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?/?>"#, ""),
        ]
        for (pattern, template) in rules { t = replace(t, pattern, template) }
        t = decodeEntities(t)
        // 连续 3 个以上换行压成一个空行；去掉开头的空行
        t = replace(t, #"\n[ \t]*\n([ \t]*\n)+"#, "\n\n")
        while t.hasPrefix("\n") { t.removeFirst() }
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        if let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = m.range(at: 1).length > 0
                let num = ns.substring(with: m.range(at: 2))
                if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) {
                    out += String(Character(u))
                } else {
                    out += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }
}
