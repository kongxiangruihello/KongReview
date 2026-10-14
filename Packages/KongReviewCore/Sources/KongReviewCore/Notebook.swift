import Foundation

// MARK: - 专题笔记本（1.3）

/// 专题笔记本：把摘录编排成一篇长文（讲稿、论文草稿、专题综述）。
/// 由若干“块”按顺序组成：摘录（引用库里的一条摘录，显示其最新文字）、文字（过渡、论述）、小标题。
public struct Notebook: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NotebookBlock: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 引用一条摘录（highlightId）；text 存加入时的原文，摘录被彻底删除后仍可显示
        case highlight
        /// 一段或几段文字（Markdown）
        case text
        /// 小标题（纯文字）
        case heading
    }

    public var id: Int64?
    public var notebookId: Int64
    /// 排序位置（插入时取前后两块的中点）
    public var position: Double
    public var kind: Kind
    public var highlightId: Int64?
    public var text: String
    /// 1.5：本文批注——只属于这本笔记本，不改原摘录的按语（只用于摘录块）
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, notebookId: Int64, position: Double, kind: Kind, highlightId: Int64? = nil,
                text: String = "", note: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.notebookId = notebookId
        self.position = position
        self.kind = kind
        self.highlightId = highlightId
        self.text = text
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 在 before 与 after 之间插入时用的位置；nil 表示开头或末尾
    public static func position(between before: Double?, and after: Double?) -> Double {
        switch (before, after) {
        case let (b?, a?): return (b + a) / 2
        case let (b?, nil): return b + 1
        case let (nil, a?): return a - 1
        case (nil, nil): return 1
        }
    }
}

// MARK: - 导出

/// 导出时的一块：已经解析好摘录与出处
public struct NotebookPiece: Sendable {
    public enum Kind: Sendable {
        case heading(String)
        case text(String)
        /// 摘录原文（Markdown）与脚注文字（出处）；cite 为空时不加脚注
        case quote(String, cite: String)
        /// 1.4：摘录的按语（导出时可选附上，排在该摘录之后）
        case comment(String)
    }
    public var kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
}

public struct NotebookExportOptions: Sendable, Equatable {
    /// 摘录出处做成脚注（否则写在引文后面的括号里）
    public var footnotes = true
    /// 文末附参考文献表（GB/T 7714）
    public var bibliography: [String] = []
    /// 1.4：Word 导出时在标题后加目录（按小标题）
    public var toc = true
    /// 1.4：页眉（标题）与页脚（页码）
    public var headerFooter = true
    public init(footnotes: Bool = true, bibliography: [String] = [], toc: Bool = true, headerFooter: Bool = true) {
        self.footnotes = footnotes
        self.bibliography = bibliography
        self.toc = toc
        self.headerFooter = headerFooter
    }
}

public enum NotebookExporter {

    // MARK: Markdown（脚注用 [^1] 语法，Obsidian、Typora、Pandoc 都认）

    public static func markdown(title: String, pieces: [NotebookPiece], options: NotebookExportOptions = .init()) -> String {
        var out = ["# " + title.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        var notes: [String] = []
        for p in pieces {
            switch p.kind {
            case .heading(let h):
                out += ["## " + h.trimmingCharacters(in: .whitespacesAndNewlines), ""]
            case .text(let t):
                let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out += [t, ""] }
            case .quote(let q, let cite):
                var lines = q.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
                if !cite.isEmpty {
                    if options.footnotes {
                        notes.append(cite)
                        lines[lines.count - 1] += "[^\(notes.count)]"
                    } else {
                        lines[lines.count - 1] += "（\(cite)）"
                    }
                }
                out += lines + [""]
            case .comment(let c):
                let c = c.trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { out += ["**按：**" + c.replacingOccurrences(of: "\n\n", with: "\n\n　　"), ""] }
            }
        }
        if !options.bibliography.isEmpty {
            out += ["## 参考文献", ""] + options.bibliography.map { $0 + "  " } + [""]
        }
        if !notes.isEmpty {
            out += notes.enumerated().map { "[^\($0.offset + 1)]: \($0.element)" } + [""]
        }
        return out.joined(separator: "\n")
    }

    // MARK: 行内 Markdown → 文字片段（粗体、斜体、删除线；链接只留文字，图片换成［图片］）

    public struct Span: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var strike = false
        public init(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false) {
            self.text = text; self.bold = bold; self.italic = italic; self.strike = strike
        }
    }

    /// 一段 Markdown → 若干段落，每段若干片段；行首 # 记为小标题（level），> 引用、- 列表去掉标记
    public struct Paragraph: Equatable, Sendable {
        public var spans: [Span]
        public var headingLevel: Int = 0
        public var isQuote = false
        public var listMarker: String? = nil
    }

    public static func paragraphs(fromMarkdown md: String) -> [Paragraph] {
        var src = md
        // 去掉 HTML 片段里的标签（摘录里偶有 <br>、<b>）
        if Markdown.containsHTMLTag(src) { src = Markdown.markdown(fromHTMLFragments: src) }
        var out: [Paragraph] = []
        var buffer: [String] = []
        var bufferQuote = false
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                var p = Paragraph(spans: spans(joined))
                p.isQuote = bufferQuote
                out.append(p)
            }
            buffer = []
            bufferQuote = false
        }
        for raw in src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[m].filter { $0 == "#" }.count
                var p = Paragraph(spans: spans(String(line[m.upperBound...])))
                p.headingLevel = level
                out.append(p)
                continue
            }
            if line == "---" || line == "***" { flush(); continue }
            if let m = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flush()
                let marker = line[m].trimmingCharacters(in: .whitespaces)
                var p = Paragraph(spans: spans(String(line[m.upperBound...])))
                p.listMarker = marker.first?.isNumber == true ? marker : "•"
                out.append(p)
                continue
            }
            if line.hasPrefix(">") {
                if !buffer.isEmpty && !bufferQuote { flush() }
                bufferQuote = true
                buffer.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if bufferQuote { flush() }
            buffer.append(line)
        }
        flush()
        return out
    }

    /// 行内标记 → 片段
    public static func spans(_ s: String) -> [Span] {
        var t = s
        t = Markdown.replace(t, #"!\[[^\]]*\]\([^)]*\)"#, "［图片］")
        t = Markdown.replace(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = Markdown.replace(t, #"`([^`]+)`"#, "$1")
        t = t.replacingOccurrences(of: "\n", with: "")
        var out: [Span] = []
        var bold = false, italic = false, strike = false
        var cur = ""
        func push() { if !cur.isEmpty { out.append(Span(cur, bold: bold, italic: italic, strike: strike)); cur = "" } }
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { cur.append(chars[i + 1]); i += 2; continue }
            if c == "*" || c == "_" {
                // _ 只在两侧不是字母数字时当作标记（避免 snake_case）
                let n = (i + 1 < chars.count && chars[i + 1] == c) ? 2 : 1
                if c == "_" {
                    let prev = i > 0 ? chars[i - 1] : " "
                    let next = i + n < chars.count ? chars[i + n] : " "
                    if prev.isLetter || prev.isNumber, next.isLetter || next.isNumber { cur.append(c); i += 1; continue }
                }
                if n == 2 {
                    // *** 视为粗体 + 斜体
                    if i + 2 < chars.count && chars[i + 2] == c { push(); bold.toggle(); italic.toggle(); i += 3; continue }
                    push(); bold.toggle(); i += 2; continue
                }
                push(); italic.toggle(); i += 1; continue
            }
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~" { push(); strike.toggle(); i += 2; continue }
            cur.append(c)
            i += 1
        }
        push()
        return out
    }

    public static func plain(_ md: String) -> String {
        paragraphs(fromMarkdown: md).map { $0.spans.map(\.text).joined() }.joined(separator: "\n")
    }

    // MARK: RTF（复制到剪贴板，粘进 Word / Pages：脚注是真脚注）

    public static func rtf(title: String, pieces: [NotebookPiece], options: NotebookExportOptions = .init()) -> String {
        func runs(_ spans: [Span]) -> String {
            spans.map { s in
                var open = "", close = ""
                if s.bold { open += "\\b "; close = "\\b0 " + close }
                if s.italic { open += "\\i "; close = "\\i0 " + close }
                if s.strike { open += "\\strike "; close = "\\strike0 " + close }
                return open.isEmpty ? RTFWriter.escape(s.text) : "{" + open + RTFWriter.escape(s.text) + "}"
            }.joined()
        }
        func note(_ cite: String) -> String {
            "{\\super\\chftn}{\\footnote\\pard\\plain\\f0\\fs20 {\\super\\chftn} \(RTFWriter.escape(cite))}"
        }
        let normal = "\\pard\\plain\\f0\\fs24\\sl360\\slmult1\\fi480\\sa120 "
        var body: [String] = []
        body.append("\\pard\\plain\\qc\\f0\\fs36\\b\\sa240 \(RTFWriter.escape(title))\\b0\\par")
        for p in pieces {
            switch p.kind {
            case .heading(let h):
                body.append("\\pard\\plain\\f0\\fs30\\b\\sb240\\sa120 \(RTFWriter.escape(h))\\b0\\par")
            case .text(let t):
                for para in paragraphs(fromMarkdown: t) {
                    if para.headingLevel > 0 {
                        body.append("\\pard\\plain\\f0\\fs28\\b\\sb200\\sa100 \(runs(para.spans))\\b0\\par")
                    } else if let m = para.listMarker {
                        body.append("\\pard\\plain\\f0\\fs24\\li480\\sa60 \(RTFWriter.escape(m)) \(runs(para.spans))\\par")
                    } else {
                        body.append(normal + runs(para.spans) + "\\par")
                    }
                }
            case .quote(let q, let cite):
                let paras = paragraphs(fromMarkdown: q)
                for (k, para) in paras.enumerated() {
                    var line = "\\pard\\plain\\f0\\fs22\\li720\\ri360\\sl320\\slmult1\\sa120 " + runs(para.spans)
                    if k == paras.count - 1, !cite.isEmpty {
                        line += options.footnotes ? note(cite) : RTFWriter.escape("（\(cite)）")
                    }
                    body.append(line + "\\par")
                }
            case .comment(let c):
                for (k, para) in paragraphs(fromMarkdown: c).enumerated() {
                    let lead = k == 0 ? "{\\b " + RTFWriter.escape("按：") + "}" : ""
                    body.append("\\pard\\plain\\f0\\fs21\\li720\\sa120 " + lead + runs(para.spans) + "\\par")
                }
            }
        }
        if !options.bibliography.isEmpty {
            body.append("\\pard\\plain\\f0\\fs30\\b\\sb360\\sa120 \(RTFWriter.escape("参考文献"))\\b0\\par")
            for e in options.bibliography {
                body.append("\\pard\\plain\\f0\\fs21\\li420\\fi-420\\sa60 \(RTFWriter.escape(e))\\par")
            }
        }
        return "{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0{\\fonttbl{\\f0\\fnil Songti SC;}}\n" + body.joined(separator: "\n") + "\n}"
    }
}
