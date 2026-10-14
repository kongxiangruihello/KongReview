import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - LiquidText 导入

/// 解析 LiquidText 导出的笔记（“Export Notes → Word”得到的 .docx，或复制出来的纯文本）。
///
/// 按 2026 年 10 月实际导出的文件（《革命造反年代》工作区）归纳的格式：
/// - 第一段：`Notes in ‘工作区名 ’`；随后是 `Notes in Workspace:` 之类的小标题；
/// - 每条笔记一段：`Excerpt:<Tab>正文<换行>(文档名 , p.14)`，出处一行是灰色斜体；
/// - 图片摘录：`Excerpt:<Tab>[Image]` 加一张内嵌图片（word/media/imageN.jpeg）；
/// - 批注（Comment）与摘录同样格式，缩进更深的视为上一条摘录的批注。
/// 从 PDF 摘出来的中文常在原来换行处留下空格（“工 人造反派”），导入时会去掉。
public enum LiquidTextImporter {

    /// 文档里的一段（与 docx / 纯文本无关的中间形式）
    public struct Block: Equatable, Sendable {
        public var text: String
        /// 段落左缩进（twips），纯文本时为 0
        public var indent: Int
        /// 段内图片的关系 id（rId）
        public var images: [String]

        public init(text: String, indent: Int = 0, images: [String] = []) {
            self.text = text
            self.indent = indent
            self.images = images
        }
    }

    public enum Kind: String, Equatable, Sendable {
        case excerpt, comment, other
    }

    /// 解析出的一条笔记
    public struct Item: Equatable, Sendable {
        public var kind: Kind
        public var label: String
        public var text: String
        /// 出处行里的文档名（未拆作者）
        public var document: String?
        public var page: String?
        public var images: [String]
        public var comments: [String]
        public var indent: Int
    }

    public struct Parsed: Equatable, Sendable {
        /// 第一行“Notes in ‘…’”里的工作区名
        public var workspace: String?
        public var items: [Item]
        public var imageCount: Int { items.reduce(0) { $0 + $1.images.count } }
    }

    // MARK: 读取 docx 的 document.xml

    /// 把 word/document.xml 拆成段落：文字（Tab、换行保留）、左缩进、内嵌图片
    public static func blocks(documentXML: Data) throws -> [Block] {
        let reader = DocxParagraphReader()
        let parser = XMLParser(data: documentXML)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else {
            throw LiquidTextError.badDocument(parser.parserError?.localizedDescription ?? "无法解析 document.xml")
        }
        return reader.blocks
    }

    /// word/_rels/document.xml.rels：rId → 包内路径（如 media/image10.jpeg）
    public static func relationships(_ data: Data) -> [String: String] {
        let reader = RelsReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        _ = parser.parse()
        return reader.map
    }

    /// 纯文本（从 LiquidText 复制出来、或另存的 .txt）：按“标签: 正文”开头、“(文档 , p.N)”结尾切分；
    /// 没有标签时，空行分隔的每一段算一条摘录。
    public static func blocks(plainText: String) -> [Block] {
        let lines = plainText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [Block] = []
        var cur: [String] = []
        func flush() {
            let t = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(Block(text: t, indent: 0)) }
            cur = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if split(label: line) != nil, !cur.isEmpty { flush() }
            cur.append(line)
            if citation(in: line) != nil { flush() }
        }
        flush()
        return out
    }

    // MARK: 解析

    public static func parse(_ blocks: [Block]) -> Parsed {
        var workspace: String?
        var items: [Item] = []
        for b in blocks {
            let text = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && b.images.isEmpty { continue }
            if let w = header(text) {
                if workspace == nil { workspace = w }
                continue
            }
            if isSectionHeading(text) && b.images.isEmpty { continue }

            // 拆出末尾的“(文档 , p.N)”
            var body = text
            var document: String?
            var page: String?
            if let r = body.range(of: #"\n?\s*\(([^\n]*)\)\s*$"#, options: .regularExpression),
               let c = citation(in: String(body[r]).trimmingCharacters(in: .whitespacesAndNewlines)) {
                document = c.document
                page = c.page
                body = String(body[..<r.lowerBound])
            }

            // 工作区批注末尾的“(Refers to a comment )”“(Refers to …)”不是出处，去掉（2026-10-14 实际导出）
            if document == nil, let r = body.range(of: #"\n?\s*\(\s*Refers to[^)\n]*\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                body = String(body[..<r.lowerBound])
            }
            var kind = Kind.excerpt
            var label = "Excerpt"
            if let (l, rest) = split(label: body) {
                label = l
                kind = Self.kind(of: l)
                body = rest
            }
            body = body.replacingOccurrences(of: "[Image]", with: "")
            body = clean(body)
            if body.isEmpty && b.images.isEmpty { continue }

            // 批注：缩进比上一条摘录深，或出处页码相同且紧跟其后 → 挂到上一条摘录
            if kind == .comment, let last = items.indices.last, items[last].kind == .excerpt,
               b.indent > items[last].indent || (page != nil && page == items[last].page && document == items[last].document) {
                if !body.isEmpty { items[last].comments.append(body) }
                continue
            }
            items.append(Item(kind: kind, label: label, text: body, document: document, page: page,
                              images: b.images, comments: [], indent: b.indent))
        }
        return Parsed(workspace: workspace, items: items)
    }

    /// 转成与 Readwise 导入相同的结构，交给同一个预览、同一个数据库导入流程。
    /// - imageMarkdown：图片 rId → 写进正文的 Markdown（应用里把图片存进数据库后给出 kr-media:// 地址）；返回 nil 的图片略去。
    /// - fallbackTitle：没有出处行、也没有工作区名时用的标题（一般是文件名）。
    public static func result(_ parsed: Parsed, fallbackTitle: String,
                              imageMarkdown: (String, String?) -> String? = { _, _ in nil }) -> ReadwiseCSVImporter.Result {
        var order: [String] = []
        var groups: [String: [ReadwiseCSVImporter.ImportedHighlight]] = [:]
        var seen = Set<String>()
        var skipped = 0
        let defaultDoc = parsed.workspace?.nonEmptyTrimmed ?? fallbackTitle

        for item in parsed.items {
            let doc = item.document?.nonEmptyTrimmed ?? defaultDoc
            let location = item.page.map { "第 \($0) 页" }
            var parts: [String] = []
            if !item.text.isEmpty { parts.append(item.text) }
            for rid in item.images {
                if let md = imageMarkdown(rid, location) { parts.append(md) }
            }
            let text = parts.joined(separator: "\n\n")
            guard !text.isEmpty else { skipped += 1; continue }
            // 同一文档、同一页、同样文字才算重复（只摘了人名的笔记在不同页各算一条）
            let key = doc + "\u{1}" + text + "\u{1}" + (location ?? "")
            guard seen.insert(key).inserted else { skipped += 1; continue }

            var tags: [String] = []
            if item.kind == .comment { tags.append("批注") }
            let note = item.comments.isEmpty ? nil : item.comments.joined(separator: "\n\n")
            let h = ReadwiseCSVImporter.ImportedHighlight(text: text, note: note, location: location, tags: tags,
                                                          isFavorite: false, isDiscarded: false, highlightedAt: nil)
            if groups[doc] == nil { order.append(doc) }
            groups[doc, default: []].append(h)
        }

        let sources = order.map { doc -> ReadwiseCSVImporter.ImportedSource in
            let (title, author) = splitAuthor(doc)
            return ReadwiseCSVImporter.ImportedSource(title: title, author: author, url: nil, kind: .book,
                                                      highlights: groups[doc] ?? [])
        }
        return ReadwiseCSVImporter.Result(sources: sources, skippedRows: skipped)
    }

    // MARK: 文本小工具

    /// “Notes in ‘工作区 ’” → 工作区
    static func header(_ text: String) -> String? {
        guard text.hasPrefix("Notes in ") || text.hasPrefix("Notes from ") else { return nil }
        let rest = text.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst()
        let quotes = CharacterSet(charactersIn: "‘’'\"“”「」")
        let name = String(rest).trimmingCharacters(in: quotes.union(.whitespaces))
        // “Notes in Workspace:” 这类小标题不算
        if name.hasSuffix(":") || name.hasSuffix("：") { return nil }
        guard String(rest).first.map({ "‘'\"“「".contains($0) }) ?? false else { return nil }
        return name.isEmpty ? nil : name
    }

    static func isSectionHeading(_ text: String) -> Bool {
        guard !text.contains("\n"), text.count <= 60 else { return false }
        return text.hasSuffix(":") || text.hasSuffix("：")
    }

    /// “Excerpt:\t正文” → ("Excerpt", "正文")
    static func split(label text: String) -> (String, String)? {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let label = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 16, !label.contains("\n") else { return nil }
        let known = ["excerpt", "comment", "note", "highlight", "ink", "annotation", "link", "image",
                     "摘录", "摘錄", "批注", "评论", "評論", "注释", "笔记", "高亮"]
        guard known.contains(label.lowercased()) else { return nil }
        let rest = text[text.index(after: colon)...]
        return (label, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func kind(of label: String) -> Kind {
        switch label.lowercased() {
        case "excerpt", "highlight", "摘录", "摘錄", "高亮", "image": return .excerpt
        case "comment", "note", "annotation", "批注", "评论", "評論", "注释", "笔记": return .comment
        default: return .other
        }
    }

    /// “(革命造反年代 (李逊) , p.14)” → ("革命造反年代 (李逊)", "14")
    static func citation(in line: String) -> (document: String, page: String?)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")"), t.count > 2 else { return nil }
        let inner = String(t.dropFirst().dropLast())
        if let r = inner.range(of: #"\s*,\s*(?:p|pp|page|页)\.?\s*([0-9ivxlcdmIVXLCDM]+(?:\s*[-–—]\s*[0-9ivxlcdmIVXLCDM]+)?)\s*$"#,
                               options: .regularExpression) {
            let doc = inner[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let pageText = String(inner[r]).replacingOccurrences(of: #"^\s*,\s*(?:p|pp|page|页)\.?\s*"#, with: "",
                                                                 options: .regularExpression)
            guard !doc.isEmpty else { return nil }
            return (doc, pageText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-"))
        }
        // 没有页码的括注多半是正文的一部分，不当出处
        return nil
    }

    /// “革命造反年代：上海文革运动史稿 全二册(李逊) ” → (“革命造反年代：上海文革运动史稿 全二册”, “李逊”)
    static func splitAuthor(_ doc: String) -> (String, String) {
        var t = doc.trimmingCharacters(in: .whitespaces)
        for ext in [".pdf", ".PDF", ".epub", ".docx", ".doc"] where t.hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"\s*[\(（]([^()（）]{1,24})[\)）]\s*$"#, options: .regularExpression) {
            let inner = t[r].trimmingCharacters(in: CharacterSet(charactersIn: " ()（）"))
            // 括号里是年份、卷册、版本时不当作者
            let isMeta = inner.allSatisfy { $0.isNumber || $0 == "-" } || inner.contains("版") || inner.contains("卷")
                || inner.contains("册") || inner.lowercased().contains("ed")
            if !isMeta {
                let title = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return (title, inner) }
            }
        }
        return (t, "")
    }

    /// 去掉 PDF 换行留下的空格：两侧都是中日韩字符（或一侧中文、一侧数字）时删掉空格；
    /// 连续空白合并，首尾去空白。拉丁文不受影响。
    public static func clean(_ s: String) -> String {
        let chars = Array(s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\t", with: " "))
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " {
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                let prev = out.last
                let next = j < chars.count ? chars[j] : nil
                if let p = prev, let n = next, joinable(p, n) {
                    // 删除
                } else if prev != nil, next != nil, prev != "\n", next != "\n" {
                    out.append(" ")
                }
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x303F).contains(u) || (0x3400...0x4DBF).contains(u) || (0x4E00...0x9FFF).contains(u)
            || (0xF900...0xFAFF).contains(u) || (0xFF00...0xFFEF).contains(u) || (0x20000...0x2FA1F).contains(u)
            || (0x2018...0x201F).contains(u) || u == 0x2014 || u == 0x2026 || u == 0x00B7
    }

    static func joinable(_ a: Character, _ b: Character) -> Bool {
        if isCJK(a) && isCJK(b) { return true }
        if isCJK(a) && b.isASCII && b.isNumber { return true }
        if a.isASCII && a.isNumber && isCJK(b) { return true }
        return false
    }
}

public enum LiquidTextError: Error, LocalizedError, Equatable {
    case badDocument(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .badDocument(let m): return "无法读取这个 Word 文件：\(m)"
        case .empty: return "没有找到 LiquidText 笔记。请在 LiquidText 里用“导出笔记 → Word”导出后再试。"
        }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - XML 读取

private final class DocxParagraphReader: NSObject, XMLParserDelegate {
    var blocks: [LiquidTextImporter.Block] = []
    private var inParagraph = false
    private var inText = false
    private var text = ""
    private var indent = 0
    private var images: [String] = []
    private var depth = 0          // 嵌套段落（文本框里的段落）只算外层

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:p":
            depth += 1
            if depth == 1 { inParagraph = true; text = ""; indent = 0; images = [] }
        case "w:ind":
            if inParagraph, let v = attributes["w:left"] ?? attributes["w:start"], let n = Int(v) { indent = n }
        case "w:t":
            inText = true
        case "w:tab":
            if inParagraph { text += "\t" }
        case "w:br", "w:cr":
            if inParagraph { text += "\n" }
        case "a:blip":
            if inParagraph, let id = attributes["r:embed"] { images.append(id) }
        case "v:imagedata":
            if inParagraph, let id = attributes["r:id"] { images.append(id) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "w:t":
            inText = false
        case "w:p":
            if depth == 1 {
                blocks.append(LiquidTextImporter.Block(text: text, indent: indent, images: images))
                inParagraph = false
            }
            depth = max(0, depth - 1)
        default:
            break
        }
    }
}

private final class RelsReader: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            map[id] = target
        }
    }
}
