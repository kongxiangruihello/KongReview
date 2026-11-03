import Foundation
import CryptoKit
import KongReviewCore

// MARK: - 6.0.6：导入 KongFolio 的阅读材料
//
// KongFolio（作者自己的 PDF 阅读应用）把阅读记录存在 ~/Library/Application Support/KongFolio/ReadingJournal/catalog.json：
// - records：摘录、图片摘录、笔记（ReadingRecord：quote 原文、note 我的笔记、citations 书名 / 作者 / 页码、tags、created、modified、removed）；
// - essays：札记（ReadingEssay：题目、若干段，每段可带一条引用的摘录副本）。
// 导入后：摘录、图片摘录（有文字的）→ 摘录（出处取书名与作者，位置取页码，“我的笔记”作按语，加“KongFolio”标签）；
// 笔记、整本书心得、札记 → 札记（笔记里摘的原文、札记引用的摘录一并导成摘录并挂在札记上）。
// 以后在卷子上照常出题：摘录出要点题与出处题，札记出论证题。
// 可以反复导入：按 KongFolio 的编号记下对应关系，没变的跳过，KongFolio 里改过的更新，在 KongReview 里删去的不再加回来；
// KongFolio 里移到“最近删除”的不导入。也可以导入 KongFolio 导出的 Markdown（只增不改）。
// 只读 KongFolio 的文件，不改动它们。

/// KongFolio 的 catalog.json（只取用得着的字段；缺字段、多字段都不影响）
enum KongFolioCatalog {
    struct SourceRef: Decodable, Sendable {
        var page: Int?
        var pageLabel: String?
        var fileName: String?
    }
    struct Citation: Decodable, Sendable {
        var source: SourceRef?
        var title: String?
        var author: String?
    }
    struct Record: Decodable, Sendable {
        var id: String
        var kind: String?
        var title: String?
        var quote: String?
        var note: String?
        var citations: [Citation]?
        var imageAsset: String?
        var tags: [String]?
        var created: Date?
        var modified: Date?
        var removed: Date?
        var wholeBook: Bool?
    }
    struct Block: Decodable, Sendable {
        var id: String?
        var text: String?
        var record: Record?
    }
    struct Essay: Decodable, Sendable {
        var id: String
        var title: String?
        var blocks: [Block]?
        var tags: [String]?
        var created: Date?
        var modified: Date?
        var removed: Date?
    }
    struct State: Decodable, Sendable {
        var records: [Record]?
        var essays: [Essay]?
    }

    static let excerpt = "摘录", image = "图片摘录", note = "笔记"

    static func decode(_ data: Data) throws -> State {
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.records != nil || state.essays != nil else { throw KongFolioImportError.notCatalog }
        return state
    }
}

enum KongFolioImportError: LocalizedError, Equatable {
    case notCatalog, missing(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .notCatalog: "这个文件不是 KongFolio 的阅读记录（catalog.json）或导出的 Markdown。"
        case .missing(let path): "没有找到 KongFolio 的阅读记录：\(path)。请先在 KongFolio 里记一条摘录，或在设置里选择 catalog.json 的位置。"
        case .unreadable(let why): "读不了 KongFolio 的阅读记录：\(why)"
        }
    }
}

/// 一条要导入的材料
struct KongFolioEntry: Equatable, Sendable {
    enum Kind: String, Sendable { case highlight, note }
    /// 来源键：record:<编号>、essay:<编号>、md:<摘要>
    var key: String
    var kind: Kind
    /// 札记题目（摘录不用）
    var title = ""
    /// 摘录原文
    var text = ""
    /// 摘录的按语、札记正文（HTML）
    var html = ""
    var sourceTitle: String?
    var sourceAuthor = ""
    var location: String?
    var tags: [String] = []
    var created: Date
    var modified: Date
    /// 札记引用的摘录（各自也是一条摘录）
    var quotes: [KongFolioEntry] = []
    /// 只增不改（Markdown 没有修改时间）
    var appendOnly = false
}

/// 把 catalog.json 或导出的 Markdown 转成要导入的材料
enum KongFolioConverter {
    struct Result: Equatable, Sendable {
        var entries: [KongFolioEntry] = []
        /// 没有文字的图片摘录、空记录
        var skippedEmpty = 0
        /// KongFolio 里已移到“最近删除”的
        var skippedRemoved = 0
    }

    static let tag = "KongFolio"

    static func convert(_ state: KongFolioCatalog.State) -> Result {
        var r = Result()
        for rec in state.records ?? [] {
            if rec.removed != nil { r.skippedRemoved += 1; continue }
            if let e = entry(from: rec) { r.entries.append(e) } else { r.skippedEmpty += 1 }
        }
        for essay in state.essays ?? [] {
            if essay.removed != nil { r.skippedRemoved += 1; continue }
            if let e = entry(from: essay) { r.entries.append(e) } else { r.skippedEmpty += 1 }
        }
        return r
    }

    static func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 页码：有印刷页码用印刷页码，否则用 PDF 的页序
    static func location(_ c: KongFolioCatalog.Citation?) -> String? {
        guard let src = c?.source else { return nil }
        if let label = src.pageLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return "第 \(label) 页" }
        return src.page.map { "第 \($0 + 1) 页" }
    }

    static func tags(_ t: [String]?) -> [String] {
        var out: [String] = []
        for x in (t ?? []).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) + [tag] where !x.isEmpty && !out.contains(x) { out.append(x) }
        return out
    }

    /// 一条摘录（原文为空的不算）
    static func highlight(key: String, from rec: KongFolioCatalog.Record, withNote: Bool) -> KongFolioEntry? {
        let quote = trimmed(rec.quote)
        guard !quote.isEmpty else { return nil }
        let c = rec.citations?.first
        let note = withNote ? trimmed(rec.note) : ""
        return KongFolioEntry(key: key, kind: .highlight, text: quote, html: note.isEmpty ? "" : Markdown.richHTML(note),
                              sourceTitle: c.flatMap { t in trimmed(t.title).isEmpty ? nil : trimmed(t.title) },
                              sourceAuthor: trimmed(c?.author), location: location(c), tags: tags(rec.tags),
                              created: rec.created ?? Date(), modified: rec.modified ?? rec.created ?? Date())
    }

    static func entry(from rec: KongFolioCatalog.Record) -> KongFolioEntry? {
        let isNote = rec.kind == KongFolioCatalog.note || rec.wholeBook == true
        if !isNote { return highlight(key: "record:" + rec.id, from: rec, withNote: true) }
        // 笔记 → 札记；笔记里摘的原文另作一条摘录挂上
        let note = trimmed(rec.note), quote = trimmed(rec.quote)
        guard !note.isEmpty || !quote.isEmpty else { return nil }
        let c = rec.citations?.first
        var body = ""
        if !quote.isEmpty { body += blockquote(quote, cite: cite(c)) }
        if !note.isEmpty { body += Markdown.richHTML(note) }
        let book = trimmed(c?.title)
        var title = trimmed(rec.title)
        if title.isEmpty || (rec.wholeBook == true && title == "整本书心得") {
            title = rec.wholeBook == true && !book.isEmpty ? "读《\(book)》" : firstLine(note.isEmpty ? quote : note)
        }
        var e = KongFolioEntry(key: "record:" + rec.id, kind: .note, title: title, html: body, tags: tags(rec.tags),
                               created: rec.created ?? Date(), modified: rec.modified ?? rec.created ?? Date())
        if let q = highlight(key: "record:" + rec.id + "#quote", from: rec, withNote: false) { e.quotes = [q] }
        return e
    }

    static func entry(from essay: KongFolioCatalog.Essay) -> KongFolioEntry? {
        var body = "", quotes: [KongFolioEntry] = [], firstText = ""
        for block in essay.blocks ?? [] {
            if let rec = block.record {
                let quote = trimmed(rec.quote)
                if !quote.isEmpty {
                    body += blockquote(quote, cite: cite(rec.citations?.first))
                    // 引用的摘录：与阅读记录里的同一条共用一个来源键，不会导成两条
                    let isNote = rec.kind == KongFolioCatalog.note || rec.wholeBook == true
                    if let q = highlight(key: "record:" + rec.id + (isNote ? "#quote" : ""), from: rec, withNote: !isNote),
                       !quotes.contains(where: { $0.key == q.key }) { quotes.append(q) }
                }
            }
            let text = trimmed(block.text)
            if !text.isEmpty {
                body += Markdown.richHTML(text)
                if firstText.isEmpty { firstText = text }
            }
        }
        var title = trimmed(essay.title)
        if title.isEmpty || title == "未命名札记" { title = firstLine(firstText.isEmpty ? quotes.first?.text ?? "" : firstText) }
        guard !title.isEmpty, !body.isEmpty else { return nil }
        return KongFolioEntry(key: "essay:" + essay.id, kind: .note, title: title, html: body, tags: tags(essay.tags),
                              created: essay.created ?? Date(), modified: essay.modified ?? essay.created ?? Date(), quotes: quotes)
    }

    static func cite(_ c: KongFolioCatalog.Citation?) -> String {
        guard let c else { return "" }
        let title = trimmed(c.title), author = trimmed(c.author)
        guard !title.isEmpty else { return "" }
        return (author.isEmpty ? "" : author + "：") + "《" + title + "》" + (location(c).map { "，" + $0 } ?? "")
    }

    static func blockquote(_ quote: String, cite: String) -> String {
        let lines = quote.components(separatedBy: "\n").map(Markdown.escape).joined(separator: "<br>")
        return "<blockquote><p>" + lines + "</p>" + (cite.isEmpty ? "" : "<p>——" + Markdown.escape(cite) + "</p>") + "</blockquote>"
    }

    /// 题目：第一行，去掉 Markdown 记号，至多 40 字
    static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-_ \t　")) }.first { !$0.isEmpty } ?? ""
        let plain = Markdown.plainText(fromHTML: Markdown.richHTML(line)).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > 40 ? String(plain.prefix(40)) + "……" : plain
    }

    // MARK: 导出的 Markdown

    /// KongFolio“导出 → Markdown”的文件：# 标题；每条“## 题目”，下有“> 原文”、“我的笔记：”、出处行“作者：《书名》，第 N 页”、“标签：……”。
    /// 有原文的为摘录（笔记作按语），只有笔记的为札记；按内容记来源键，同一文件导入两次不重复。
    static func convertMarkdown(_ text: String) -> Result {
        var r = Result()
        var sections: [(String, [String])] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { sections.append((String(line.dropFirst(3)), [])) }
            else if line.hasPrefix("# ") && sections.isEmpty { continue }
            else if !sections.isEmpty { sections[sections.count - 1].1.append(raw) }
        }
        let citeRE = try? NSRegularExpression(pattern: #"^(?:(.+?)：)?《(.+?)》，第 (\d+) 页(?:（印刷页码 (.+?)）)?\s*$"#)
        for (heading, lines) in sections {
            var quote: [String] = [], note: [String] = [], tags: [String] = []
            var sourceTitle: String?, author = "", loc: String?
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix(">") { quote.append(unescape(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
                if line == "我的笔记：" || line.hasPrefix("[返回原文]") || line.hasPrefix("![") { continue }
                if line.hasPrefix("标签：") {
                    tags = String(line.dropFirst(3)).components(separatedBy: "、").map { unescape($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    continue
                }
                let plain = unescape(line)
                if let re = citeRE, let m = re.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                    func g(_ i: Int) -> String? { Range(m.range(at: i), in: plain).map { String(plain[$0]) } }
                    if sourceTitle == nil {
                        author = g(1) ?? ""; sourceTitle = g(2)
                        loc = g(4).map { "第 \($0) 页" } ?? g(3).map { "第 \($0) 页" }
                    }
                    continue
                }
                note.append(raw)
            }
            let q = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let n = note.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = unescape(heading).trimmingCharacters(in: .whitespaces)
            let key = "md:" + digest(title + "\u{1}" + q + "\u{1}" + n)
            let now = Date()
            if !q.isEmpty {
                r.entries.append(KongFolioEntry(key: key, kind: .highlight, text: q, html: n.isEmpty ? "" : Markdown.richHTML(n),
                                                sourceTitle: sourceTitle, sourceAuthor: author, location: loc, tags: self.tags(tags),
                                                created: now, modified: now, appendOnly: true))
            } else if !n.isEmpty {
                r.entries.append(KongFolioEntry(key: key, kind: .note, title: title.isEmpty ? firstLine(n) : title, html: Markdown.richHTML(n),
                                                tags: self.tags(tags), created: now, modified: now, appendOnly: true))
            } else {
                r.skippedEmpty += 1
            }
        }
        return r
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaped = false
        for ch in s {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        return out
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 读一个文件：catalog.json（或 KongFolio 的阅读记录备份）、导出的 Markdown
    static func read(_ url: URL) throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else { throw KongFolioImportError.missing(url.path) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw KongFolioImportError.unreadable(error.localizedDescription) }
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            return convertMarkdown(String(decoding: data, as: UTF8.self))
        }
        do { return convert(try KongFolioCatalog.decode(data)) }
        catch let e as KongFolioImportError { throw e }
        catch { throw KongFolioImportError.notCatalog }
    }
}

/// 自动导入的设置
enum KongFolioSettings {
    static let enabledKey = "kongfolio.autoImport"
    static let pathKey = "kongfolio.catalogPath"
    static let lastSeenKey = "kongfolio.lastSeen"
    static let lastReportKey = "kongfolio.lastReport"

    static var defaultCatalog: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("KongFolio/ReadingJournal/catalog.json")
    }
    static var catalog: URL {
        get { UserDefaults.standard.string(forKey: pathKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? defaultCatalog }
        set { UserDefaults.standard.set(newValue == defaultCatalog ? nil : newValue.path, forKey: pathKey) }
    }
    /// 默认开：启动、回到前台时和每分钟看一次，catalog.json 改过才导入
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// 文件的修改时间与大小，没变就不读
    static func signature(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(m)|\((a[.size] as? NSNumber)?.intValue ?? 0)"
    }
}
