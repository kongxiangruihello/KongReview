import Foundation

/// 专题汇编：把一批摘录整理成一份可读的材料（Markdown / Word 共用同一个结构）
public struct Compilation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var text: String
        public var translation: String?
        public var note: String?
        public var citation: String
        public var tags: [String]
    }

    public struct Section: Equatable, Sendable {
        /// 分组标题（按出处分组时为“《书名》 作者”；按时间排列时为 nil）
        public var heading: String?
        public var items: [Item]
    }

    public var title: String
    public var subtitle: String
    public var sections: [Section]
    public var count: Int { sections.reduce(0) { $0 + $1.items.count } }
}

public struct CompilationOptions: Equatable, Sendable {
    public enum Grouping: String, CaseIterable, Sendable {
        case bySource, chronological
        public var label: String { self == .bySource ? "按出处分组" : "按摘录时间排列" }
    }

    public var title: String
    public var grouping: Grouping
    public var includeTranslation: Bool
    public var includeNotes: Bool
    public var includeTags: Bool
    public var style: CitationStyle
    public var date: Date

    public init(title: String, grouping: Grouping = .bySource, includeTranslation: Bool = true,
                includeNotes: Bool = true, includeTags: Bool = false, style: CitationStyle = .footnote,
                date: Date = Date()) {
        self.title = title
        self.grouping = grouping
        self.includeTranslation = includeTranslation
        self.includeNotes = includeNotes
        self.includeTags = includeTags
        self.style = style
        self.date = date
    }
}

public enum CompilationBuilder {

    public static func build(highlights: [Highlight], sources: [Int64: Source], options o: CompilationOptions) -> Compilation {
        let live = highlights.filter { !$0.isDeleted }

        func item(_ h: Highlight) -> Compilation.Item {
            let src = h.sourceId.flatMap { sources[$0] }
            return Compilation.Item(
                text: h.text,
                translation: o.includeTranslation ? h.translation : nil,
                note: o.includeNotes ? h.note : nil,
                citation: CitationFormatter.citation(for: h, source: src, style: o.style, accessed: o.date),
                tags: o.includeTags ? h.tags : []
            )
        }

        var sections: [Compilation.Section] = []
        switch o.grouping {
        case .chronological:
            let sorted = live.sorted { $0.createdAt < $1.createdAt }
            sections = [Compilation.Section(heading: nil, items: sorted.map(item))]
        case .bySource:
            var groups: [Int64: [Highlight]] = [:]
            var orphan: [Highlight] = []
            for h in live {
                if let id = h.sourceId, sources[id] != nil { groups[id, default: []].append(h) } else { orphan.append(h) }
            }
            // 摘录多的出处在前；数量相同按书名
            let ordered = groups.keys.sorted { a, b in
                let ca = groups[a]!.count, cb = groups[b]!.count
                if ca != cb { return ca > cb }
                return sources[a]!.title < sources[b]!.title
            }
            for id in ordered {
                let s = sources[id]!
                let heading = s.author.isEmpty ? "《\(s.title)》" : "《\(s.title)》 \(s.author)"
                let hs = groups[id]!.sorted(by: locationOrder)
                sections.append(Compilation.Section(heading: heading, items: hs.map(item)))
            }
            if !orphan.isEmpty {
                sections.append(Compilation.Section(heading: "未注明出处", items: orphan.sorted { $0.createdAt < $1.createdAt }.map(item)))
            }
        }

        let count = sections.reduce(0) { $0 + $1.items.count }
        let subtitle = "共 \(count) 条摘录 · \(CitationFormatter.isoDay(o.date)) 整理 · 引文体例：\(o.style.label)"
        return Compilation(title: o.title, subtitle: subtitle, sections: sections)
    }

    /// 同一出处内：有页码的按页码，其余按摘录时间
    static func locationOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        let pa = CitationFormatter.pages(from: a.location).flatMap { Int($0.split(separator: "-").first ?? "") }
        let pb = CitationFormatter.pages(from: b.location).flatMap { Int($0.split(separator: "-").first ?? "") }
        switch (pa, pb) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt < b.createdAt
        }
    }

    public static func markdown(_ c: Compilation) -> String {
        var out = "# \(c.title)\n\n*\(c.subtitle)*\n\n"
        for section in c.sections {
            if let h = section.heading { out += "## \(h)\n\n" }
            for item in section.items {
                let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false)
                out += lines.map { "> \($0)" }.joined(separator: "\n") + "\n"
                if let t = item.translation, !t.isEmpty { out += "\n译：\(t)\n" }
                if let n = item.note, !n.isEmpty { out += "\n按：\(n)\n" }
                if !item.citation.isEmpty { out += "\n—— \(item.citation)\n" }
                if !item.tags.isEmpty { out += "\n" + item.tags.map { "#\($0)" }.joined(separator: " ") + "\n" }
                out += "\n"
            }
        }
        return out
    }
}

// MARK: - Anki

/// 导出为 Anki 可直接导入的文本文件（Anki 2.1.54 起支持文件头指令）。
/// 正面：原文；背面：译文、按语、出处。标签列：摘录标签 + KongGlean。
public enum AnkiExporter {
    public static func export(highlights: [Highlight], sources: [Int64: Source], deck: String = "KongGlean",
                              style: CitationStyle = .footnote, accessed: Date = Date()) -> String {
        var out = """
        #separator:tab
        #html:true
        #notetype:Basic
        #deck:\(deck)
        #columns:Front;Back;Tags
        #tags column:3

        """
        for h in highlights where !h.isDeleted {
            let src = h.sourceId.flatMap { sources[$0] }
            var back: [String] = []
            if let t = h.translation, !t.isEmpty { back.append(html(t)) }
            if let n = h.note, !n.isEmpty { back.append("按：" + html(n)) }
            let cite = CitationFormatter.citation(for: h, source: src, style: style, accessed: accessed)
            if !cite.isEmpty { back.append("<small>\(html(cite))</small>") }
            let tags = (h.tags + ["KongGlean"]).map(tag).joined(separator: " ")
            out += [html(h.text), back.joined(separator: "<br><br>"), tags].joined(separator: "\t") + "\n"
        }
        return out
    }

    /// 单次遍历转义（2 万条时比多次 replacingOccurrences 快得多）
    static func html(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\t": out += " "
            case "\r": break
            case "\n": out += "<br>"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Anki 标签不能含空格
    static func tag(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - 出处查重

public enum SourceDedup {
    /// 归一化书名：去掉空白与标点、书名号、括注（如“（修订本）”）、大小写
    public static func key(_ title: String) -> String {
        var t = title.lowercased()
        // 去掉末尾的版本括注（“修订本”“第二版”“增订本”等）；
        // “（上）（下）（一）（续）”这类分篇标记要保留，否则上下篇会被误判为重复
        for (open, close) in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】")] {
            if t.hasSuffix(close), let r = t.range(of: open, options: .backwards), r.lowerBound != t.startIndex {
                let note = t[r.upperBound...]
                let isEdition = ["版", "本", "修订", "增订", "edition", "ed."].contains { note.contains($0) }
                if isEdition { t = String(t[..<r.lowerBound]) }
            }
        }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// 返回疑似重复的出处 id 组（每组至少 2 个）
    public static func duplicateGroups(_ sources: [Source]) -> [[Int64]] {
        var groups: [String: [Int64]] = [:]
        for s in sources {
            guard let id = s.id else { continue }
            let k = key(s.title)
            guard !k.isEmpty else { continue }
            groups[k, default: []].append(id)
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
