import Foundation

// MARK: - CSV 解析（RFC 4180：引号、转义引号、字段内换行、BOM、CRLF）

public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r":
                    break
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                default:
                    field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // 去掉完全空白的行
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

// MARK: - Readwise CSV 导入

/// 解析 Readwise 导出的 CSV（readwise.io/export → CSV）。
///
/// Readwise 官方文档没有公布 CSV 的列名，这里按常见导出文件的表头匹配，并做了宽松处理：
/// 列名不区分大小写，常见别名都能识别；只要有“Highlight”列就能导入。
/// 已知表头：Highlight, Book Title, Book Author, Amazon Book ID, Note, Color, Tags,
///          Location Type, Location, Highlighted at, Document tags
public enum ReadwiseCSVImporter {

    public struct ImportedHighlight: Equatable, Sendable {
        public var text: String
        public var note: String?
        public var location: String?
        public var tags: [String]
        public var isFavorite: Bool
        public var highlightedAt: Date?
    }

    public struct ImportedSource: Equatable, Sendable {
        public var title: String
        public var author: String
        public var url: String?
        public var kind: SourceKind
        public var highlights: [ImportedHighlight]
    }

    public struct Result: Equatable, Sendable {
        public var sources: [ImportedSource]
        public var skippedRows: Int
        public var highlightCount: Int { sources.reduce(0) { $0 + $1.highlights.count } }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case empty
        case missingHighlightColumn(found: [String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "文件是空的，或不是 CSV 格式。"
            case .missingHighlightColumn(let found):
                return "没有找到“Highlight”列，这可能不是 Readwise 导出的 CSV。文件中的列为：\(found.joined(separator: "、"))"
            }
        }
    }

    enum Field: CaseIterable {
        case text, title, author, note, tags, locationType, location, date, url, documentTags, amazonID

        var aliases: [String] {
            switch self {
            case .text: return ["highlight", "text", "highlight text"]
            case .title: return ["book title", "title", "document title"]
            case .author: return ["book author", "author", "authors"]
            case .note: return ["note", "notes"]
            case .tags: return ["tags", "highlight tags"]
            case .locationType: return ["location type"]
            case .location: return ["location", "page"]
            case .date: return ["highlighted at", "highlighted_at", "date", "created at"]
            case .url: return ["url", "source url", "source_url"]
            case .documentTags: return ["document tags", "book tags"]
            case .amazonID: return ["amazon book id"]
            }
        }
    }

    public static func parse(_ text: String) throws -> Result {
        let rows = CSV.parse(text)
        guard let header = rows.first else { throw ImportError.empty }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var index: [Field: Int] = [:]
        for field in Field.allCases {
            if let i = normalized.firstIndex(where: { field.aliases.contains($0) }) {
                index[field] = i
            }
        }
        guard index[.text] != nil else {
            throw ImportError.missingHighlightColumn(found: header)
        }

        func value(_ row: [String], _ f: Field) -> String? {
            guard let i = index[f], i < row.count else { return nil }
            let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        // 按（书名, 作者）分组，保持首次出现的顺序
        var order: [String] = []
        var groups: [String: ImportedSource] = [:]
        var skipped = 0

        for row in rows.dropFirst() {
            guard let body = value(row, .text) else {
                skipped += 1
                continue
            }
            let title = value(row, .title) ?? "Readwise 未命名"
            let author = value(row, .author) ?? ""
            let key = title + "\u{1F}" + author

            var tags = splitTags(value(row, .tags)) + splitTags(value(row, .documentTags))
            let isFavorite = tags.contains { $0.lowercased() == "favorite" }
            tags = tags.filter { !$0.hasPrefix(".") && $0.lowercased() != "favorite" }
            tags = dedupe(tags)

            let h = ImportedHighlight(
                text: body,
                note: value(row, .note),
                location: formatLocation(type: value(row, .locationType), value: value(row, .location)),
                tags: tags,
                isFavorite: isFavorite,
                highlightedAt: value(row, .date).flatMap(parseDate)
            )

            if groups[key] == nil {
                let url = value(row, .url)
                // CSV 没有“分类”列：有网址的当网页，其余当书籍（之后可在“编辑出处”里改）
                let kind: SourceKind = url != nil ? .web : .book
                groups[key] = ImportedSource(title: title, author: author, url: url, kind: kind, highlights: [])
                order.append(key)
            }
            groups[key]?.highlights.append(h)
        }

        return Result(sources: order.compactMap { groups[$0] }, skippedRows: skipped)
    }

    // MARK: 辅助

    static func splitTags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    static func dedupe(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    /// Readwise 的位置：page = 页码；location = Kindle 位置；order / offset 只是排序用，不保留
    static func formatLocation(type: String?, value: String?) -> String? {
        guard let value, !value.isEmpty, value != "0" else { return nil }
        switch type?.lowercased() {
        case "page": return "第\(value)页"
        case "location": return "Kindle 位置 \(value)"
        case "time_offset": return "\(value) 秒处"
        case "order", "offset": return nil
        case .none, .some(""): return value
        default: return value
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in [
            "yyyy-MM-dd HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
            "MMMM d, yyyy h:mm:ss a",
            "MMMM d, yyyy h:mm a",
            "MMMM d, yyyy",
        ] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
