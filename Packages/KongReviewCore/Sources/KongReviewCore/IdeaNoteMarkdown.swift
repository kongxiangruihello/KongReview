import Foundation

// MARK: - 4.1.2：札记写成 Obsidian 的 Markdown 文件
//
// 一条札记一个文件，文件名就是题目（去掉文件名不允许的字符），放在同步文件夹的“札记”子文件夹里。
// 正文里的 [[题目]] 改写为对方的文件名（显示文字不变），Obsidian 打开即可跳转、看反向链接。
// 引用的摘录列在文末，带出处。文件开头的属性里有 kongreview-note，同步时只清理带这个标记的旧文件。

public enum IdeaNoteMarkdown {
    public static let marker = "kongreview-note"

    public struct Quote: Sendable {
        public var text: String
        public var cite: String
        public init(text: String, cite: String) { self.text = text; self.cite = cite }
    }

    public struct Note: Sendable {
        public var id: Int64
        public var title: String
        public var body: String
        public var createdAt: Date
        public var updatedAt: Date
        public var quotes: [Quote]
        public init(id: Int64, title: String, body: String, createdAt: Date, updatedAt: Date, quotes: [Quote]) {
            self.id = id; self.title = title; self.body = body; self.createdAt = createdAt; self.updatedAt = updatedAt; self.quotes = quotes
        }
    }

    /// 文件名（不含 .md）：去掉 / \ : 等字符；同名的加“ (2)”，大小写与 Unicode 归一后相同也算同名
    public static func fileStems(for notes: [Note]) -> [Int64: String] {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\n#^[]")
        var used = Set<String>(), out: [Int64: String] = [:]
        for n in notes.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            var base = n.title.components(separatedBy: illegal).joined(separator: "-").trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "札记 \(n.id)" }
            if base.count > 120 { base = String(base.prefix(120)) }
            var stem = base, k = 2
            while used.contains(stem.precomposedStringWithCanonicalMapping.lowercased()) { stem = "\(base) (\(k))"; k += 1 }
            used.insert(stem.precomposedStringWithCanonicalMapping.lowercased())
            out[n.id] = stem
        }
        return out
    }

    /// 一条札记的文件内容。resolve：按题目找到对方的文件名（找不到时保留原题目，Obsidian 里显示为未建的链接）
    public static func markdown(_ n: Note, resolve: (String) -> String?) -> String {
        var out = "---\n"
        out += "title: \(yaml(n.title))\n"
        out += "created: \(day(n.createdAt))\n"
        out += "updated: \(day(n.updatedAt))\n"
        out += "\(marker): \(n.id)\n"
        out += "tags: [札记]\n"
        out += "---\n\n"
        out += "# \(n.title)\n\n"
        let linked = WikiLinks.replacing(n.body) { title, display in
            let target = resolve(title) ?? title
            return target == display ? "[[\(target)]]" : "[[\(target)|\(display)]]"
        }
        let body = NotebookExporter.essayMarkdown(linked).trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { out += body + "\n\n" }
        if !n.quotes.isEmpty {
            out += "## 引用摘录\n\n"
            for q in n.quotes {
                let text = Markdown.plainText(fromHTML: q.text).trimmingCharacters(in: .whitespacesAndNewlines)
                out += text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n"
                if !q.cite.isEmpty { out += ">\n> — \(q.cite)\n" }
                out += "\n"
            }
        }
        return out
    }

    /// 文件是不是 KongReview 写的札记（同步时只删除这种旧文件）
    public static func isGenerated(_ text: String) -> Bool {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n") else { return false }
        return text[..<end.lowerBound].contains("\n\(marker): ")
    }

    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
