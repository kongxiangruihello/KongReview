import Foundation

// MARK: - CSV 解析（RFC 4180：引号、转义引号、字段内换行、BOM、CRLF）

public enum CSV {
    /// 按 UTF-8 字节解析，3 万行、30 MB 级别的文件在一两秒内完成。
    public static func parse(_ text: String) -> [[String]] {
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }

        let quote: UInt8 = 0x22, comma: UInt8 = 0x2C, cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        field.reserveCapacity(256)
        var inQuotes = false
        var i = 0
        let n = bytes.count

        @inline(__always) func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }

        while i < n {
            let c = bytes[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case quote: inQuotes = true
                case comma: endField()
                case cr: break
                case lf:
                    endField()
                    rows.append(row)
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
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
        public var isDiscarded: Bool
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

            // 划线自身的标签里，Readwise 用 favorite / discard 表示“收藏”“弃置”；
            // 以 . 开头的（.h1、.c1 等）是 Readwise 的排版指令，不保留。
            // 文档标签（Document tags）原样并入（其中的 favorite 指“收藏的文档”，不等于收藏这条摘录）。
            let own = splitTags(value(row, .tags))
            let isFavorite = own.contains { $0.lowercased() == "favorite" }
            let isDiscarded = own.contains { $0.lowercased() == "discard" }
            let ownKept = own.filter {
                !$0.hasPrefix(".") && !["favorite", "discard"].contains($0.lowercased())
            }
            let tags = dedupe(ownKept + splitTags(value(row, .documentTags)).filter { !$0.hasPrefix(".") })

            let h = ImportedHighlight(
                text: body,
                note: value(row, .note),
                location: formatLocation(type: value(row, .locationType), value: value(row, .location)),
                tags: tags,
                isFavorite: isFavorite,
                isDiscarded: isDiscarded,
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

    /// 快速解析 “yyyy-MM-dd[ T]HH:mm:ss[.ffffff][Z|±hh:mm]”（Readwise 导出的格式），不经过 DateFormatter
    static func fastParse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= b.count else { return nil }
            var v = 0
            for k in from..<(from + len) {
                let c = b[k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 19, b[4] == 45, b[7] == 45, b[10] == 32 || b[10] == 84, b[13] == 58, b[16] == 58,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61
        else { return nil }

        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 {   // 小数秒
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count {
            switch b[i] {
            case 90: i += 1                                   // Z
            case 43, 45:                                      // + / -
                let sign = b[i] == 45 ? -1 : 1
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                if i + 3 < b.count, b[i + 3] == 58 { om = num(i + 4, 2) ?? 0; i += 6 }
                else { om = num(i + 3, 2) ?? 0; i += 5 }
                offset = sign * (oh * 3600 + om * 60)
            default: return nil
            }
        }
        guard i == b.count else { return nil }

        // 公历日期 → 1970 年起的天数（Howard Hinnant 算法）
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + h * 3600 + mi * 60 + se - offset) + frac
        return Date(timeIntervalSince1970: seconds)
    }

    // 日期格式器创建代价很高，必须复用（逐行新建会让 2 万行的文件慢上十几秒）
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fallbackFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ssZZZZZ",          // Readwise CSV：2023-01-18 15:43:26+00:00
        "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
        "MMMM d, yyyy h:mm:ss a",
        "MMMM d, yyyy h:mm a",
        "MMMM d, yyyy",
    ].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fmt
        return f
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = fastParse(s) { return d }
        for f in fallbackFormatters.prefix(1) {
            if let d = f.date(from: s) { return d }
        }
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        for f in fallbackFormatters.dropFirst() {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
