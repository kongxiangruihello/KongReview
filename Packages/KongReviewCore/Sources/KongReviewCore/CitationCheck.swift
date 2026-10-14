import Foundation

// MARK: - 引文核对（1.9）

/// 导出前把笔记本里每条引文的出处信息检查一遍：
/// - 没有出处；
/// - 书籍、PDF、文章缺页码（网页、人工智能生成内容不要求页码）；
/// - 按古籍体例引用的出处缺篇名（位置里既没有篇名也没有卷次）；
/// - 同一部古籍的卷次写法不统一（“卷七”“卷7”“第七卷”混用）；
/// - 书籍出处缺出版者或年份（每个出处只报一次）。
public enum CitationCheck {

    public enum Kind: String, Sendable, CaseIterable {
        case noSource, noPage, noChapter, juanStyle, sourceInfo, editionPage

        public var label: String {
            switch self {
            case .noSource: return "没有出处"
            case .noPage: return "缺页码"
            case .noChapter: return "缺篇名"
            case .juanStyle: return "卷次写法不统一"
            case .sourceInfo: return "出处信息不全"
            case .editionPage: return "缺所选版本的页码"
            }
        }
    }

    public struct Issue: Sendable, Equatable, Identifiable {
        public var kind: Kind
        /// 涉及的摘录（出处信息不全时为 nil）
        public var highlightId: Int64?
        public var sourceId: Int64?
        public var message: String
        public init(kind: Kind, highlightId: Int64?, sourceId: Int64?, message: String) {
            self.kind = kind; self.highlightId = highlightId; self.sourceId = sourceId; self.message = message
        }
        public var id: String { "\(kind.rawValue)-\(highlightId.map(String.init) ?? "")-\(sourceId.map(String.init) ?? "")" }
    }

    public struct Item: Sendable {
        public var highlight: Highlight
        public var source: Source?
        public init(highlight: Highlight, source: Source?) { self.highlight = highlight; self.source = source }
    }

    /// 卷次的写法：卷 + 汉字数字、卷 + 阿拉伯数字、第 X 卷
    enum JuanStyle: String { case hanzi, arabic, di }

    static func juanStyle(_ location: String?) -> JuanStyle? {
        guard let loc = location else { return nil }
        for t in ClassicCitation.tokens(loc) {
            guard ClassicCitation.juanName(t) != nil else { continue }
            if t.hasPrefix("第") { return .di }
            return t.contains(where: { $0.isASCII && $0.isNumber }) ? .arabic : .hanzi
        }
        return nil
    }

    /// 直接引原典、不注版本（如只写《论语·学而》）的古籍出处
    static func bareClassic(_ s: Source) -> Bool {
        s.isClassic && ClassicCitation.bare(s.classicTitle ?? "") == ClassicCitation.bare(s.title)
            && (s.publisher ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func needsPage(_ s: Source) -> Bool {
        if bareClassic(s) { return false }
        switch s.kind {
        case .book, .pdf, .article, .other: return true
        case .web, .ai: return false
        }
    }

    public static func check(_ items: [Item]) -> [Issue] {
        var out: [Issue] = []
        var seen = Set<Int64>()
        var reportedSources = Set<Int64>()
        // 每部古籍里各种卷次写法的条目
        var juans: [Int64: [JuanStyle: [Int64]]] = [:]

        for it in items {
            let h = it.highlight
            guard let hid = h.id, seen.insert(hid).inserted else { continue }
            guard let s = it.source else {
                out.append(Issue(kind: .noSource, highlightId: hid, sourceId: nil, message: "这条摘录没有出处，导出时没有脚注。"))
                continue
            }
            let c = ClassicCitation.components(h.location)
            if needsPage(s), c.page == nil {
                out.append(Issue(kind: .noPage, highlightId: hid, sourceId: s.id,
                                 message: h.location?.trimmingCharacters(in: .whitespaces).isEmpty == false
                                    ? "位置“\(h.location!)”里没有页码。" : "没有填位置（页码）。"))
            }
            if s.isClassic, c.juan == nil, c.chapters.isEmpty {
                out.append(Issue(kind: .noChapter, highlightId: hid, sourceId: s.id,
                                 message: "按古籍体例引用，但位置里没有篇名，脚注只能写成《\(s.classicTitle ?? s.title)》。"))
            }
            if s.isClassic, let sid = s.id, let st = juanStyle(h.location) {
                juans[sid, default: [:]][st, default: []].append(hid)
            }
            if let sid = s.id, s.kind == .book, !bareClassic(s), !reportedSources.contains(sid) {
                var missing: [String] = []
                if (s.publisher ?? "").trimmingCharacters(in: .whitespaces).isEmpty { missing.append("出版者") }
                if (s.year ?? "").trimmingCharacters(in: .whitespaces).isEmpty { missing.append("年份") }
                if !missing.isEmpty {
                    reportedSources.insert(sid)
                    out.append(Issue(kind: .sourceInfo, highlightId: nil, sourceId: sid,
                                     message: "《\(s.title)》缺" + missing.joined(separator: "、") + "。"))
                }
            }
        }

        // 卷次写法：以条目最多的写法为准，其余的报出来
        for (sid, styles) in juans where styles.count > 1 {
            // 条数相同时以“卷七”（汉字数字）为准
            let rank: [JuanStyle: Int] = [.hanzi: 2, .di: 1, .arabic: 0]
            let major = styles.max { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : rank[a.key]! < rank[b.key]!
            }!.key
            let name: [JuanStyle: String] = [.hanzi: "“卷七”", .arabic: "“卷7”", .di: "“第七卷”"]
            for (st, ids) in styles where st != major {
                for hid in ids {
                    out.append(Issue(kind: .juanStyle, highlightId: hid, sourceId: sid,
                                     message: "这部书多数写作\(name[major]!)，这条写作\(name[st]!)。"))
                }
            }
        }
        // 顺序固定：先按种类，再按摘录在笔记本里的先后
        let order = Dictionary(items.enumerated().compactMap { i, it in it.highlight.id.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        let kinds = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return out.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if a.kind != b.kind { return kinds[a.kind]! < kinds[b.kind]! }
            let oa = a.highlightId.flatMap { order[$0] } ?? Int.max, ob = b.highlightId.flatMap { order[$0] } ?? Int.max
            return oa != ob ? oa < ob : x.offset < y.offset
        }.map(\.element)
    }
}

// MARK: - 补页码（2.0）

extension CitationCheck {
    /// 把输入的页码规范成“第 N 页”：纯数字或“12-15”写成“第12页”“第12—15页”；已带“页”或“p.”的照原样
    public static func pageText(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("页") || t.lowercased().hasPrefix("p") { return t }
        let parts = t.split(whereSeparator: { "-–—~～至".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        // 其他写法（如罗马数字页码 xii）也包成“第…页”，否则会被当成篇名
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return "第\(t)页" }
        return parts.count == 1 ? "第\(parts[0])页" : "第\(parts[0])—\(parts[1])页"
    }

    /// 在原有位置后面补上页码：“学而第一”+“3”→“学而第一 · 第3页”
    public static func addingPage(_ raw: String, to location: String?) -> String? {
        guard let page = pageText(raw) else { return nil }
        let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return loc.isEmpty ? page : loc + " · " + page
    }
}

// MARK: - 日课卡（1.9：每日提醒）

public enum DailyCard {
    /// 通知标题，如“日课 · 十月十五日 · 星期四”
    public static func title(_ date: Date, calendar: Calendar = .current) -> String {
        "日课 · " + DeckOverview.chineseDate(date, calendar: calendar)
    }

    /// 预计用时（分钟）：摘录每条约 20 秒，记忆卡按 DeckOverview.estimatedMinutes 的估算
    public static func minutes(highlights: Int, cards: StudyQueue.Counts) -> Int {
        let s = highlights * 20 + cards.new * 20 + cards.learning * 12 + cards.review * 8
        return s == 0 ? 0 : max(1, Int((Double(s) / 60).rounded()))
    }

    /// 通知正文：今天的功课 + 昨天做了多少 + 连续天数
    public static func body(highlights: Int, cards: StudyQueue.Counts,
                            yesterday: (highlights: Int, cards: Int)?, streak: Int) -> String {
        var lines: [String] = []
        var today: [String] = []
        if highlights > 0 { today.append("摘录 \(highlights) 条") }
        if cards.total > 0 {
            var detail: [String] = []
            if cards.new > 0 { detail.append("新 \(cards.new)") }
            if cards.learning > 0 { detail.append("学习中 \(cards.learning)") }
            if cards.review > 0 { detail.append("复习 \(cards.review)") }
            today.append("记忆卡 \(cards.total) 张" + (detail.count > 1 ? "（" + detail.joined(separator: " · ") + "）" : ""))
        }
        let m = minutes(highlights: highlights, cards: cards)
        lines.append(today.isEmpty ? "今天没有到期的功课，翻几条旧摘录吧。" : "今天：" + today.joined(separator: "，") + (m > 0 ? "，约 \(m) 分钟" : ""))
        if let y = yesterday {
            if y.highlights + y.cards == 0 {
                lines.append("昨天没有回顾。")
            } else {
                var parts: [String] = []
                if y.highlights > 0 { parts.append("看了 \(y.highlights) 条摘录") }
                if y.cards > 0 { parts.append("复习 \(y.cards) 次记忆卡") }
                lines.append("昨天" + parts.joined(separator: "、") + (streak > 1 ? "，已连续 \(streak) 天。" : "。"))
            }
        }
        return lines.joined(separator: "\n")
    }
}


// MARK: - 篇目进度（2.1）

public struct ChapterProgress: Sendable, Equatable, Identifiable {
    public var name: String
    public var total: Int
    /// 在每日回顾里出现过的条数
    public var reviewed: Int
    /// 已做成记忆卡的条数
    public var withCards: Int
    public var id: String { name }
    public init(name: String, total: Int, reviewed: Int, withCards: Int) {
        self.name = name; self.total = total; self.reviewed = reviewed; self.withCards = withCards
    }
    public var reviewedRatio: Double { total == 0 ? 0 : Double(reviewed) / Double(total) }
    /// 菜单里的简短说明，如“12 条 · 回顾 8 · 卡 5”
    public var summary: String {
        "\(total) 条 · 回顾 \(reviewed)" + (withCards > 0 ? " · 卡 \(withCards)" : "")
    }

    /// 由按篇分组的摘录和“有卡片的摘录 id”算出各篇进度
    public static func compute(_ groups: [(name: String, highlights: [Highlight])], carded: Set<Int64>) -> [ChapterProgress] {
        groups.map { g in
            ChapterProgress(name: g.name, total: g.highlights.count,
                            reviewed: g.highlights.filter { $0.surfacedCount > 0 }.count,
                            withCards: g.highlights.filter { $0.id.map(carded.contains) ?? false }.count)
        }
    }
}
