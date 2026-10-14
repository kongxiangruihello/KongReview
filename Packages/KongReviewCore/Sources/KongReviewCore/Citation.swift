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
        if s.isClassic { return ClassicCitation.footnote(s, location: location) }
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

// MARK: - 古籍篇章体例（1.7）

/// 古籍按“《书名·篇名》”引用（如《论语·学而》《孟子·梁惠王上》《史记·项羽本纪》）。
///
/// 依据：《历史研究》等刊物通行的引文注释规范——常用古籍可只标书名、篇名，用间隔号“·”连接；
/// 引自今人注本、整理本时，其后再注明整理本的责任者、书名、出版信息与页码。
/// 篇名取自摘录的“位置”：去掉其中的页码部分（“第3页”“p. 3”），余下的就是篇名；
/// “学而第一”“学而篇”这类带篇次的写法简化为“学而”。
public enum ClassicCitation {

    static let separators: Set<Character> = ["·", "・", "•", "，", ",", "；", ";", "|", "/", "／"]

    /// 是否像页码：含“页”，“p. 12”“pp.12”，或整个是数字与连接号
    static func isPage(_ piece: String) -> Bool {
        let t = piece.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.contains("页") { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("p"), lower.dropFirst().contains(where: { $0.isNumber }),
           lower.allSatisfy({ $0.isNumber || "p. -–—~～".contains($0) }) { return true }
        return t.allSatisfy { $0.isNumber || " -–—~～".contains($0) }
    }

    /// 位置 → (篇名, 页码部分)
    public static func split(_ location: String?) -> (chapter: String?, page: String?) {
        guard let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { return (nil, nil) }
        let merged = tokens(loc)
        let p = parts(merged)
        let chapter: String?
        if let j = p.juan {
            chapter = ([j] + p.chapters).joined(separator: "·")
        } else {
            chapter = p.chapters.isEmpty ? nil : p.chapters.joined(separator: "·")
        }
        return (chapter, p.page)
    }

    /// 1.8：位置拆成卷次、篇名、页码，如“卷七 项羽本纪 第300页”→ (卷七, [项羽本纪], 第300页)
    public static func components(_ location: String?) -> (juan: String?, chapters: [String], page: String?) {
        guard let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { return (nil, [], nil) }
        return parts(tokens(loc))
    }

    static func tokens(_ loc: String) -> [String] {
        var pieces: [String] = []
        var cur = ""
        for ch in loc {
            if separators.contains(ch) || ch == " " || ch == "\u{3000}" {
                if !cur.isEmpty { pieces.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { pieces.append(cur) }
        var merged: [String] = []
        for p in pieces {
            if let last = merged.last, ["p", "p.", "pp", "pp."].contains(last.lowercased()), p.first?.isNumber == true {
                merged[merged.count - 1] = last + " " + p
            } else { merged.append(p) }
        }
        return merged
    }

    static func parts(_ merged: [String]) -> (juan: String?, chapters: [String], page: String?) {
        let pages = merged.filter(isPage)
        var juan: String?
        var chapters: [String] = []
        for piece in merged where !isPage(piece) {
            if juan == nil, let j = juanName(piece) { juan = j; continue }
            let c = chapterName(piece)
            if !c.isEmpty { chapters.append(c) }
        }
        return (juan, chapters, pages.isEmpty ? nil : pages.joined(separator: " "))
    }

    static let numeralChars = Set("〇零一二三四五六七八九十百千廿卅0123456789")

    /// “卷七”“卷一百二十”“卷三上”“第七卷”→ 卷次（统一写成“卷X”）；不是卷次返回 nil
    public static func juanName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("卷") {
            var body = t.dropFirst()
            if let last = body.last, "上中下".contains(last) { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ numeralChars.contains($0) }) else { return nil }
            return t
        }
        if t.hasPrefix("第"), t.hasSuffix("卷"), t.count > 2 {
            let body = t.dropFirst().dropLast()
            guard body.allSatisfy({ numeralChars.contains($0) }) else { return nil }
            return "卷" + body
        }
        return nil
    }

    static let ordinalChars = Set("〇零一二三四五六七八九十百廿卅")

    /// “学而第一”→“学而”，“学而篇”→“学而”，“《学而》”→“学而”；“第一章”这类整个是篇次的保持原样
    public static func chapterName(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "《》〈〉<>"))
        if let r = t.range(of: "第", options: .backwards), r.lowerBound != t.startIndex {
            let tail = t[r.upperBound...]
            if !tail.isEmpty, tail.allSatisfy({ ordinalChars.contains($0) || $0.isNumber }) {
                t = String(t[..<r.lowerBound])
            }
        }
        if t.count > 1, t.hasSuffix("篇") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 打开“古籍体例”时预填的原典书名：去掉书名里“译注”“集解”“校注”“今注今译”之类的后缀
    public static func guessClassicTitle(_ title: String) -> String {
        var t = bare(title)
        let suffixes = ["今注今译", "译注", "集解", "集释", "集注", "校注", "校释", "正义", "注疏", "新注", "今注", "今译",
                        "通释", "解题", "讲义", "选注", "选译", "全译", "注", "疏"]
        var changed = true
        while changed {
            changed = false
            for s in suffixes where t.count > s.count + 1 && t.hasSuffix(s) {
                t.removeLast(s.count)
                changed = true
                break
            }
        }
        return t
    }

    static func bare(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "《》"))
    }

    /// 只有书名、篇名：《论语·学而》
    /// 有卷次时按史部通行写法：《史记》卷七《项羽本纪》
    public static func short(_ s: Source, location: String?) -> String {
        let book = bare(s.classicTitle?.nonEmpty ?? s.title)
        let c = components(location)
        if let j = c.juan {
            return "《\(book)》\(j)" + (c.chapters.isEmpty ? "" : "《\(c.chapters.joined(separator: "·"))》")
        }
        if !c.chapters.isEmpty { return "《\(book)·\(c.chapters.joined(separator: "·"))》" }
        return "《\(book)》"
    }

    /// 2.0：按篇分组用的篇名——位置里的第一个篇名；只有卷次时用卷次；都没有为 nil
    public static func chapterKey(_ location: String?) -> String? {
        let c = components(location)
        return c.chapters.first ?? c.juan
    }

    /// 2.0：把摘录按篇分组（篇的先后按第一次出现的顺序；没有篇名的不在内）
    public static func groupByChapter(_ highlights: [Highlight]) -> [(name: String, highlights: [Highlight])] {
        var order: [String] = []
        var groups: [String: [Highlight]] = [:]
        for h in highlights {
            guard let k = chapterKey(h.location) else { continue }
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(h)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 1.8：常用古籍（原典书名 → 习惯上标注的朝代与作者；经部、子部多不标作者，留空）
    public static let presets: [(title: String, author: String)] = [
        ("论语", ""), ("孟子", ""), ("大学", ""), ("中庸", ""), ("周易", ""), ("尚书", ""), ("诗经", ""),
        ("礼记", ""), ("左传", ""), ("老子", ""), ("庄子", ""), ("荀子", ""), ("韩非子", ""),
        ("史记", "（汉）司马迁"), ("汉书", "（汉）班固"), ("后汉书", "（南朝宋）范晔"), ("三国志", "（晋）陈寿"),
        ("资治通鉴", "（宋）司马光"), ("四书章句集注", "（宋）朱熹"), ("朱子语类", "（宋）黎靖德编"),
        ("传习录", "（明）王守仁"), ("明夷待访录", "（清）黄宗羲"), ("日知录", "（清）顾炎武"),
    ]

    /// 预设里这部书的作者（没有或不标作者时为 nil）
    public static func presetAuthor(_ title: String) -> String? {
        let t = bare(title)
        return presets.first { $0.title == t }?.author.nonEmpty
    }

    /// 脚注：
    /// - 原典本身（原典书名与书名相同）：（汉）司马迁：《史记·项羽本纪》，北京：中华书局，1959年，第300页。
    /// - 注本、整理本：《论语·学而》，杨伯峻：《论语译注》，北京：中华书局，1980年，第3页。
    static func footnote(_ s: Source, location: String?) -> String {
        let parts = split(location)
        let head = short(s, location: location)
        var plain = s
        plain.classicTitle = nil
        let sameBook = bare(s.classicTitle ?? "") == bare(s.title)
        if sameBook {
            // 用普通脚注生成出版信息，再把开头的《书名》换成《书名·篇名》
            var rest = CitationFormatter.footnote(plain, location: parts.page)
            let author = s.author.trimmingCharacters(in: .whitespaces)
            let oldHead = author.isEmpty ? "《\(s.title)》" : "\(author)：《\(s.title)》"
            if rest.hasPrefix(oldHead) {
                rest.removeFirst(oldHead.count)
                return (author.isEmpty ? head : "\(author)：\(head)") + rest
            }
            return head + "。"
        }
        let edition = CitationFormatter.footnote(plain, location: parts.page)
        return head + "，" + edition
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
