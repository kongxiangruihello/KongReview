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
        t = replace(t, #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
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
}
