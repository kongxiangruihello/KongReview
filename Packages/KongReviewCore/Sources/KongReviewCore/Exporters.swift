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
