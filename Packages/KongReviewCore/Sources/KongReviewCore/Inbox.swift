import Foundation

// MARK: - 外部应用投递摘录（收件箱）

/// 其他应用（计划中的 PDF 批注应用、脚本等）把摘录写成 JSON 文件放进 KongReview 的“收件箱”文件夹，
/// KongReview 发现后导入，再把文件移到“已导入”子文件夹。格式（version 1）：
///
/// ```json
/// {
///   "version": 1,
///   "app": "KongPDF",
///   "source": { "title": "严复集", "author": "严复", "kind": "pdf",
///               "url": "file:///Users/me/Books/严复集.pdf", "publisher": "中华书局", "year": "1986", "isbn": "..." },
///   "highlights": [
///     { "id": "外部应用里这条批注的唯一 id", "text": "原文", "note": "按语", "translation": "译文",
///       "location": "第 12 页", "page": 12, "tags": ["严复"], "createdAt": "2026-10-13T08:00:00Z" }
///   ]
/// }
/// ```
/// 同一出处按 标题 + 作者 合并；同一条摘录按 来源应用 + id（没有 id 时按原文）去重，重复投递不会产生重复摘录。
public enum InboxPayload {
    public struct File: Decodable, Equatable, Sendable {
        public var version: Int?
        public var app: String?
        public var source: SourceInfo
        public var highlights: [Item]
    }

    public struct SourceInfo: Decodable, Equatable, Sendable {
        public var title: String
        public var author: String?
        public var kind: String?
        public var url: String?
        public var publisher: String?
        public var year: String?
        public var isbn: String?

        public var sourceKind: SourceKind {
            switch (kind ?? "").lowercased() {
            case "book": return .book
            case "article": return .article
            case "web": return .web
            case "ai": return .ai
            case "other": return .other
            default: return .pdf
            }
        }
    }

    public struct Item: Decodable, Equatable, Sendable {
        public var id: String?
        public var text: String
        public var note: String?
        public var translation: String?
        public var location: String?
        public var page: Int?
        public var tags: [String]?
        public var createdAt: Date?

        /// 位置：优先 location，其次“第 N 页”
        public var resolvedLocation: String? {
            if let l = location, !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            return page.map { "第 \($0) 页" }
        }
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case empty
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "收件箱文件格式版本 \(v) 暂不支持。"
            case .empty: return "收件箱文件里没有摘录。"
            }
        }
    }

    public static func parse(_ data: Data) throws -> File {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t) }
            let s = try c.decode(String.self)
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的日期：\(s)")
        }
        let f = try d.decode(File.self, from: data)
        if let v = f.version, v > 1 { throw ParseError.unsupportedVersion(v) }
        guard f.highlights.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ParseError.empty
        }
        return f
    }

    /// 去重用的键：来源应用 + 外部 id；没有 id 时用原文
    public static func key(app: String?, item: Item) -> String {
        (app ?? "external") + "|" + (item.id ?? ("text:" + item.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

// MARK: - 搜索词高亮

public enum SearchTerms {
    /// 把查询拆成若干词（空格分隔，去掉 # 标签与引号）
    /// 1.6 起按搜索语法拆（只取要找的词与整句，不含 出处:、-排除、标签 等条件）
    public static func terms(_ query: String) -> [String] {
        SearchSyntax.parse(query).terms
    }

    /// 文本里每个词出现的位置（不区分大小写）
    /// 1.2 起繁简通配：搜“红卫兵”也标出“紅衛兵”（逐字归一后比较，位置对回原文）
    public static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        let scalars = Array(text.unicodeScalars)
        let folded = scalars.map(ChineseFold.fold)
        var indices: [String.Index] = []
        indices.reserveCapacity(scalars.count + 1)
        var i = text.unicodeScalars.startIndex
        while i < text.unicodeScalars.endIndex {
            indices.append(i)
            i = text.unicodeScalars.index(after: i)
        }
        indices.append(text.endIndex)
        for t in terms {
            let needle = Array(ChineseFold.fold(t).unicodeScalars)
            guard !needle.isEmpty, needle.count <= folded.count else { continue }
            var s = 0
            while s + needle.count <= folded.count {
                if folded[s] == needle[0] && Array(folded[s..<(s + needle.count)]) == needle {
                    out.append(indices[s]..<indices[s + needle.count])
                    s += needle.count
                } else {
                    s += 1
                }
            }
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }
}
