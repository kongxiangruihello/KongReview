import Foundation

// MARK: - Markdown 导出（Obsidian 友好）

public enum MarkdownExporter {

    public static func export(source: Source, highlights: [Highlight], exportedAt: Date = Date(),
                              style: CitationStyle = .footnote) -> String {
        var out = "---\n"
        out += "title: \(yamlEscape(source.title))\n"
        if !source.author.isEmpty { out += "author: \(yamlEscape(source.author))\n" }
        out += "kind: \(source.kind.rawValue)\n"
        if let u = source.url { out += "url: \(yamlEscape(u))\n" }
        if let p = source.publisher { out += "publisher: \(yamlEscape(p))\n" }
        if let y = source.year { out += "year: \(yamlEscape(y))\n" }
        out += "exported: \(isoDay(exportedAt))\n"
        out += "source: KongReview\n"
        out += "---\n\n"
        out += "# \(source.title)\n\n"

        for h in highlights where !h.isDiscarded {
            out += block(for: h, source: source, style: style, accessed: exportedAt)
            out += "\n"
        }
        return out
    }

    public static func block(for h: Highlight, source: Source?, style: CitationStyle = .footnote,
                             accessed: Date = Date()) -> String {
        var out = ""
        for line in h.text.split(separator: "\n", omittingEmptySubsequences: false) {
            out += "> \(line)\n"
        }
        if let t = h.translation, !t.isEmpty { out += "\n译：\(t)\n" }
        if let n = h.note, !n.isEmpty { out += "\n按：\(n)\n" }
        let cite = CitationFormatter.citation(for: h, source: source, style: style, accessed: accessed)
        if !cite.isEmpty { out += "\n— \(cite)\n" }
        if !h.tags.isEmpty { out += "\n" + h.tags.map { "#\($0)" }.joined(separator: " ") + "\n" }
        return out
    }

    /// 生成可作文件名的标题
    public static func fileName(for source: Source) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\n")
        let cleaned = source.title.components(separatedBy: illegal).joined(separator: "-")
        return (cleaned.isEmpty ? "untitled" : cleaned) + ".md"
    }

    /// 一批出处的唯一文件名：同名、非法字符替换后同名，以及 macOS 大小写碰撞均保留。
    /// 碰撞时优先用稳定的出处 id；与“未归类”等保留文件也不能重名。
    public static func fileNames(for sources: [Source], reservedNames: Set<String> = []) -> [String] {
        func key(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.lowercased()
        }
        let names = sources.map { fileName(for: $0) }
        let counts = Dictionary(names.map { (key($0), 1) }, uniquingKeysWith: +)
        let reserved = Set(reservedNames.map(key))
        var used = reserved
        return sources.enumerated().map { index, source in
            let original = names[index]
            let stem = String(original.dropLast(3))
            let needsSuffix = (counts[key(original)] ?? 0) > 1 || reserved.contains(key(original))
            let base = needsSuffix ? stem + "-" + (source.id.map(String.init) ?? String(index + 1)) : stem
            var candidate = base + ".md"
            var suffix = 2
            while used.contains(key(candidate)) {
                candidate = base + "-\(suffix).md"
                suffix += 1
            }
            used.insert(key(candidate))
            return candidate
        }
    }

    static func yamlEscape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 搜索辅助

public enum SearchQuery {
    /// SQLite FTS5 trigram 分词器要求查询词至少 3 个字符；更短时应退回 LIKE。
    public static func usesFullText(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    /// 把用户输入转成 FTS5 短语查询（整体加引号，内部双引号转义），避免语法错误。
    public static func fts5Phrase(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// LIKE 模式，转义 % 与 _（配合 ESCAPE '\'）
    public static func likePattern(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(q)%"
    }
}
