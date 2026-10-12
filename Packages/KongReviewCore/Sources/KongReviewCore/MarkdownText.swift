import Foundation

#if canImport(Darwin)

/// 把 Markdown 转成 AttributedString，供 SwiftUI 的 Text 直接显示（摘录、译文、按语、实时预览共用）。
///
/// SwiftUI 的 Text 只认行内格式；AttributedString(markdown:) 的完整语法又会把换行、列表吞掉。
/// 所以这里逐行处理块级语法，行内部分交给系统解析：
/// - `# 标题` → 粗体；`- 项` / `* 项` → “• 项”；`1. 项` 原样；`> 引用` → “┃ ” + 斜体
/// - ``` 代码块 ``` → 等宽；`---` → 分隔线
/// - 行内：**粗体**、*斜体*、`代码`、~~删除线~~、[链接](https://…)
/// 换行与空行原样保留，纯文本看起来与以前完全一样。
/// 夹在文字里的 HTML 标签先换成 Markdown（见 Markdown.markdown(fromHTMLFragments:)）。
public enum MarkdownText {

    public static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        // 先把混在文字里的 HTML 标签（<h1>、<b>、<a href>…）换成 Markdown
        let text = Markdown.markdown(fromHTMLFragments: source)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inCode = false
        var emitted = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            let piece: AttributedString
            if t.hasPrefix("```") {
                inCode.toggle()
                // 代码块的围栏行本身不显示；为了不多出空行，连同换行一起跳过
                continue
            }
            if inCode {
                var c = AttributeContainer()
                c[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .code
                piece = AttributedString(line, attributes: c)
            } else if let level = headingLevel(t) {
                piece = wrapped(String(t.dropFirst(level)), "**")
            } else if t == "---" || t == "***" || t == "___" {
                piece = AttributedString("————————")
            } else if t.hasPrefix(">") {
                piece = AttributedString("┃ ") + wrapped(String(t.dropFirst()), "*")
            } else if let bullet = ["- ", "* ", "+ "].first(where: { t.hasPrefix($0) }) {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                piece = AttributedString(indent + "• ") + inline(String(t.dropFirst(bullet.count)))
            } else {
                piece = inline(line)
            }
            if emitted { result += AttributedString("\n") }
            emitted = true
            result += piece
        }
        return result
    }

    /// 整行包一层 Markdown 强调（标题加粗、引用变斜体）；空行或首尾有空白时不包，避免语法失效
    static func wrapped(_ text: String, _ mark: String) -> AttributedString {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(mark) else { return inline(t) }
        return inline(mark + t + mark)
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for ch in s { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), s.count > n, s[s.index(s.startIndex, offsetBy: n)] == " " else { return nil }
        return n
    }
}
#endif
