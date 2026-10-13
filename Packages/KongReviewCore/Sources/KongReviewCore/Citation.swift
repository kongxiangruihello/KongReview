import Foundation

/// 引文体例
public enum CitationStyle: String, CaseIterable, Codable, Sendable {
    /// 中文人文社科常用脚注体例：作者：《书名》，出版地：出版者，年份，第X页。
    case footnote
    /// GB/T 7714—2015 参考文献著录规则（顺序编码制的单条格式，不含序号）
    case gbt7714

    public var label: String {
        switch self {
        case .footnote: return "中文脚注体例"
        case .gbt7714: return "GB/T 7714—2015"
        }
    }
}

public enum CitationFormatter {

    public static func citation(for highlight: Highlight, source: Source?, style: CitationStyle = .footnote,
                                accessed: Date = Date()) -> String {
        guard let s = source else { return highlight.location ?? "" }
        switch style {
        case .footnote: return footnote(s, location: highlight.location)
        case .gbt7714: return gbt(s, location: highlight.location, accessed: accessed)
        }
    }

    // MARK: 中文脚注

    static func footnote(_ s: Source, location: String?) -> String {
        var parts: [String] = []
        let author = s.author.trimmingCharacters(in: .whitespaces)
        let title = "《\(s.title)》"
        parts.append(author.isEmpty ? title : "\(author)：\(title)")

        switch s.kind {
        case .article:
            // 作者：《篇名》，《刊名》2012年第3期，第12页。
            var journal = ""
            if let c = s.container?.nonEmpty { journal = "《\(c)》" }
            if let y = s.year?.nonEmpty { journal += y.hasSuffix("年") ? y : "\(y)年" }
            if let i = s.issue?.nonEmpty { journal += i }
            if !journal.isEmpty { parts.append(journal) }
        case .web:
            if let site = (s.container ?? s.publisher)?.nonEmpty { parts.append(site) }
            if let y = s.year?.nonEmpty { parts.append(y.hasSuffix("年") ? y : "\(y)年") }
        case .ai:
            // 作者栏填模型名（如 Claude、ChatGPT），出版者栏填平台或提问人
            var gen = "人工智能生成内容"
            if let p = s.publisher?.nonEmpty { gen = "\(p)，" + gen }
            parts.append(gen)
            if let y = s.year?.nonEmpty { parts.append(y.hasSuffix("年") ? y : "\(y)年") }
        default:
            var pub = ""
            if let place = s.place?.nonEmpty { pub = place + "：" }
            if let p = s.publisher?.nonEmpty { pub += p }
            if !pub.isEmpty { parts.append(pub) }
            if let e = s.edition?.nonEmpty { parts.append(e) }
            if let y = s.year?.nonEmpty { parts.append(y.hasSuffix("年") ? y : "\(y)年") }
        }
        if let loc = location?.nonEmpty { parts.append(loc) }
        if s.kind == .web, let u = s.url?.nonEmpty { parts.append(u) }
        return parts.joined(separator: "，") + "。"
    }

    // MARK: GB/T 7714—2015

    /// 文献类型标识
    static func typeCode(_ kind: SourceKind) -> String {
        switch kind {
        case .book, .pdf: return "M"
        case .article: return "J"
        case .web: return "EB/OL"
        case .ai, .other: return "Z"
        }
    }

    /// 超过 3 个责任者时只录前 3 个，后加“等”（英文加 et al.）
    public static func gbtAuthors(_ raw: String) -> String {
        let names = raw.split(whereSeparator: { ",，、;；/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard names.count > 3 else { return names.joined(separator: ",") }
        let latin = names[0].unicodeScalars.allSatisfy { $0.isASCII }
        return names.prefix(3).joined(separator: ",") + (latin ? ", et al" : ",等")
    }

    /// 从“第12页”“页12—15”“p. 12”中取出页码
    public static func pages(from location: String?) -> String? {
        guard let loc = location else { return nil }
        // 只认页码：含“页”/“p”，或整个就是数字；Kindle 位置、章节名都不算
        let lower = loc.lowercased()
        let looksLikePage = loc.contains("页") || lower.hasPrefix("p") || lower.contains(" p")
            || loc.allSatisfy { $0.isNumber || " -–—~～".contains($0) }
        guard looksLikePage else { return nil }
        var out = ""
        var seenDigit = false
        for ch in loc {
            if ch.isNumber && ch.isASCII { out.append(ch); seenDigit = true }
            else if seenDigit && "-–—~～至".contains(ch) { out.append("-") }
            else if seenDigit && !out.hasSuffix("-") && ch != " " { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    static func gbt(_ s: Source, location: String?, accessed: Date) -> String {
        var out = ""
        let authors = gbtAuthors(s.author)
        if !authors.isEmpty { out += authors + "." }
        out += "\(s.title)[\(typeCode(s.kind))]."
        let page = pages(from: location)

        switch s.kind {
        case .article:
            // 作者.题名[J].刊名,年,卷(期):页码.
            var tail: [String] = []
            if let c = s.container?.nonEmpty { tail.append(c) }
            if let y = s.year?.nonEmpty { tail.append(y) }
            var vi = s.issue?.nonEmpty ?? ""
            if let p = page { vi += (vi.isEmpty ? "" : ":") + p }
            if !vi.isEmpty { tail.append(vi) }
            if !tail.isEmpty { out += tail.joined(separator: ",") + "." }
        case .web:
            // 作者.题名[EB/OL].(年)[引用日期].网址.
            if let y = s.year?.nonEmpty { out += "(\(y))" }
            out += "[\(isoDay(accessed))]."
            if let u = s.url?.nonEmpty { out += u + "." }
        default:
            // 作者.题名[M].版本.出版地:出版者,年:页码.
            if let e = s.edition?.nonEmpty { out += e + "." }
            var pub = ""
            if let place = s.place?.nonEmpty { pub = place + ":" }
            if let p = s.publisher?.nonEmpty { pub += p }
            if let y = s.year?.nonEmpty { pub += (pub.isEmpty ? "" : ",") + y }
            if let p = page { pub += (pub.isEmpty ? "" : ":") + p }
            if !pub.isEmpty { out += pub + "." }
        }
        return out
    }

    static func isoDay(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - 参考文献表（1.2）

/// 按 GB/T 7714—2015 生成参考文献表（整部文献，不含页码）。
/// - numbered：顺序编码制，按给出的顺序编号 [1] [2] …；
/// - authorYear：著者-出版年制，“著者,出版年.题名[M].出版地:出版者.”，按著者排序（中文按拼音）。
public enum Bibliography {
    public enum Order: String, CaseIterable, Sendable {
        case numbered, authorYear
        public var label: String { self == .numbered ? "顺序编码制（编号）" : "著者-出版年制（按著者排序）" }
    }

    /// 去重：同一 id，或标题 + 作者相同
    public static func unique(_ sources: [Source]) -> [Source] {
        var seen = Set<String>()
        var out: [Source] = []
        for s in sources {
            let key = s.id.map { "id:\($0)" } ?? "t:\(s.title)|\(s.author)"
            let key2 = "t:\(s.title)|\(s.author)"
            if seen.contains(key) || seen.contains(key2) { continue }
            seen.insert(key); seen.insert(key2)
            out.append(s)
        }
        return out
    }

    public static func entries(_ sources: [Source], order: Order = .numbered, accessed: Date = Date()) -> [String] {
        let list = unique(sources)
        switch order {
        case .numbered:
            return list.enumerated().map { "[\($0.offset + 1)] " + CitationFormatter.gbt($0.element, location: nil, accessed: accessed) }
        case .authorYear:
            let zh = Locale(identifier: "zh_Hans_CN")
            let sorted = list.sorted { a, b in
                let ka = a.author.isEmpty ? a.title : a.author
                let kb = b.author.isEmpty ? b.title : b.author
                let r = ka.compare(kb, options: [.caseInsensitive], range: nil, locale: zh)
                if r != .orderedSame { return r == .orderedAscending }
                return (a.year ?? "") < (b.year ?? "")
            }
            return sorted.map { authorYear($0, accessed: accessed) }
        }
    }

    /// 著者-出版年制的单条
    static func authorYear(_ s: Source, accessed: Date) -> String {
        let authors = CitationFormatter.gbtAuthors(s.author)
        let year = s.year?.nonEmpty
        var out = ""
        if !authors.isEmpty { out += authors + (year.map { "," + $0 } ?? "") + "." }
        else if let year { out += year + "." }
        out += "\(s.title)[\(CitationFormatter.typeCode(s.kind))]."
        switch s.kind {
        case .article:
            var tail: [String] = []
            if let c = s.container?.nonEmpty { tail.append(c) }
            if let i = s.issue?.nonEmpty { tail.append(i) }
            if !tail.isEmpty { out += tail.joined(separator: ",") + "." }
        case .web:
            out += "[\(CitationFormatter.isoDay(accessed))]."
            if let u = s.url?.nonEmpty { out += u + "." }
        default:
            if let e = s.edition?.nonEmpty { out += e + "." }
            var pub = ""
            if let place = s.place?.nonEmpty { pub = place + ":" }
            if let p = s.publisher?.nonEmpty { pub += p }
            if !pub.isEmpty { out += pub + "." }
        }
        return out
    }
}
