import Foundation

// MARK: - 记忆卡（仿 Anki）

/// 记忆卡：正面提问、背面答案，按 Anki 的 SM-2 规则安排复习。
/// 可以由摘录生成（highlightId 指回原摘录），也可以从 Anki 导入或手工新建。
public struct Card: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case new, learning, review, relearning
    }

    public var id: Int64?
    public var deck: String
    /// 正面 / 背面：Markdown 或 HTML（从 Anki 导入的是 HTML）
    public var front: String
    public var back: String
    public var tags: [String]
    public var highlightId: Int64?
    public var state: State
    /// 学习 / 重学阶段当前处于第几步
    public var step: Int
    /// 复习间隔（天）
    public var interval: Double
    /// 难度系数（Anki 的 ease，默认 2.5）
    public var ease: Double
    public var due: Date
    public var reps: Int
    public var lapses: Int
    public var isSuspended: Bool
    /// 从 Anki 导入时的笔记 guid，用于重复导入去重
    public var ankiGuid: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    /// 笔记类型（来自 Anki 的多字段笔记）；非 nil 时按该类型的模板从 fields 生成正反面
    public var noteType: String?
    /// 各字段内容（与笔记类型的字段名一一对应）
    public var fields: [String]
    /// FSRS 记忆状态：稳定性（天）与难度（1–10）；SM-2 卡片可为 nil
    public var stability: Double?
    public var difficulty: Double?
    /// 上次复习时间（FSRS 据此计算经过的天数）
    public var lastReview: Date?

    public init(id: Int64? = nil, deck: String = "默认", front: String, back: String = "", tags: [String] = [],
                highlightId: Int64? = nil, state: State = .new, step: Int = 0, interval: Double = 0,
                ease: Double = 2.5, due: Date = Date(), reps: Int = 0, lapses: Int = 0, isSuspended: Bool = false,
                ankiGuid: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.deck = deck
        self.front = front
        self.back = back
        self.tags = tags
        self.highlightId = highlightId
        self.state = state
        self.step = step
        self.interval = interval
        self.ease = ease
        self.due = due
        self.reps = reps
        self.lapses = lapses
        self.isSuspended = isSuspended
        self.ankiGuid = ankiGuid
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.noteType = nil
        self.fields = []
        self.stability = nil
        self.difficulty = nil
        self.lastReview = nil
    }
}

/// 回答按钮（与 Anki 相同的四档）
public enum CardAnswer: Int, CaseIterable, Codable, Sendable {
    case again = 1, hard, good, easy

    public var label: String {
        switch self {
        case .again: return "重来"
        case .hard: return "困难"
        case .good: return "良好"
        case .easy: return "简单"
        }
    }
}

/// Anki 默认参数下的 SM-2 调度（不含随机浮动）。
/// 参考 Anki 手册“Deck Options”：学习步骤 1m 10m、毕业间隔 1 天、简单间隔 4 天、起始难度 250%、
/// 困难间隔 ×1.2、简单奖励 ×1.3、重学步骤 10m、遗忘后新间隔 0%（最少 1 天）、最大间隔 36500 天。
public struct CardScheduler: Sendable {
    public var learningSteps: [TimeInterval] = [60, 600]
    public var relearningSteps: [TimeInterval] = [600]
    public var graduatingInterval: Double = 1
    public var easyInterval: Double = 4
    public var startingEase: Double = 2.5
    public var minimumEase: Double = 1.3
    public var hardMultiplier: Double = 1.2
    public var easyBonus: Double = 1.3
    public var lapseNewInterval: Double = 0
    public var maximumInterval: Double = 36_500

    public init() {}

    static let day: TimeInterval = 86_400

    public func answer(_ card: Card, _ a: CardAnswer, now: Date = Date()) -> Card {
        var c = card
        c.reps += 1
        c.updatedAt = now
        c.lastReview = now
        switch c.state {
        case .new, .learning:
            if c.state == .new { c.ease = startingEase; c.step = 0 }
            c.state = .learning
            learn(&c, a, steps: learningSteps, now: now, graduate: { card, easy in
                card.interval = easy ? easyInterval : graduatingInterval
            })
        case .relearning:
            learn(&c, a, steps: relearningSteps, now: now, graduate: { card, easy in
                // 重学完成：回到复习，间隔为遗忘时算好的新间隔（至少 1 天）
                card.interval = max(1, card.interval) + (easy ? 1 : 0)
            })
        case .review:
            review(&c, a, now: now)
        }
        return c
    }

    private func learn(_ c: inout Card, _ a: CardAnswer, steps: [TimeInterval], now: Date,
                       graduate: (inout Card, Bool) -> Void) {
        let steps = steps.isEmpty ? [600] : steps
        switch a {
        case .again:
            c.step = 0
            c.due = now.addingTimeInterval(steps[0])
        case .hard:
            // 困难：重复当前步骤；第一步时取前两步的平均
            let delay: TimeInterval
            if c.step == 0 && steps.count > 1 { delay = (steps[0] + steps[1]) / 2 }
            else { delay = steps[min(c.step, steps.count - 1)] * (steps.count == 1 ? 1.5 : 1) }
            c.due = now.addingTimeInterval(delay)
        case .good:
            if c.step + 1 < steps.count {
                c.step += 1
                c.due = now.addingTimeInterval(steps[c.step])
            } else {
                graduate(&c, false)
                c.state = .review
                c.step = 0
                c.due = dueDate(days: c.interval, from: now)
            }
        case .easy:
            graduate(&c, true)
            c.state = .review
            c.step = 0
            c.due = dueDate(days: c.interval, from: now)
        }
    }

    private func review(_ c: inout Card, _ a: CardAnswer, now: Date) {
        let current = max(1, c.interval)
        // 提前或延后复习都按实际经过的天数折算（与 Anki 一致：延迟天数的一部分计入）
        let overdue = max(0, now.timeIntervalSince(c.due) / Self.day)
        switch a {
        case .again:
            c.lapses += 1
            c.ease = max(minimumEase, c.ease - 0.2)
            c.interval = max(1, (current * lapseNewInterval).rounded())
            c.state = .relearning
            c.step = 0
            c.due = now.addingTimeInterval(relearningSteps.first ?? 600)
            return
        case .hard:
            c.ease = max(minimumEase, c.ease - 0.15)
            c.interval = max(current + 1, (current * hardMultiplier).rounded())
        case .good:
            c.interval = max(current + 1, ((current + overdue / 2) * c.ease).rounded())
        case .easy:
            c.ease += 0.15
            c.interval = max(current + 1, ((current + overdue) * c.ease * easyBonus).rounded())
        }
        c.interval = min(c.interval, maximumInterval)
        c.due = dueDate(days: c.interval, from: now)
    }

    public func dueDate(days: Double, from now: Date) -> Date {
        // 以“天”为单位的间隔：到期日取那一天的凌晨 4 点（与 Anki 的“次日开始时间”默认值一致）
        var cal = Calendar.current
        cal.timeZone = .current
        let start = cal.startOfDay(for: now)
        let target = start.addingTimeInterval(days * Self.day)
        return cal.date(bySettingHour: 4, minute: 0, second: 0, of: target) ?? target
    }

    /// 按钮上显示的“下次出现时间”（如“<1分钟”“10分钟”“4天”）
    public func preview(_ card: Card, now: Date = Date()) -> [CardAnswer: String] {
        var out: [CardAnswer: String] = [:]
        for a in CardAnswer.allCases {
            let next = answer(card, a, now: now)
            out[a] = Self.describe(next.due.timeIntervalSince(now), days: next.state == .review ? next.interval : nil)
        }
        return out
    }

    public static func describe(_ seconds: TimeInterval, days: Double?) -> String {
        if let d = days {
            if d >= 365 { return String(format: "%.1f年", d / 365) }
            if d >= 30 { return String(format: "%.1f月", d / 30) }
            return "\(Int(d))天"
        }
        if seconds < 60 { return "<1分钟" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))分钟" }
        if seconds < day { return "\(Int((seconds / 3600).rounded()))小时" }
        return "\(Int((seconds / day).rounded()))天"
    }
}

// MARK: - 学习队列

public enum StudyQueue {
    public struct Counts: Hashable, Sendable {
        public var new = 0, learning = 0, review = 0
        public var total: Int { new + learning + review }
        public init(new: Int = 0, learning: Int = 0, review: Int = 0) {
            self.new = new; self.learning = learning; self.review = review
        }
    }

    /// 今天的学习截止点：学习中卡片可以提前 20 分钟（Anki 的 learn ahead limit）
    public static func isDue(_ c: Card, now: Date, learnAhead: TimeInterval = 1200) -> Bool {
        guard !c.isSuspended, c.deletedAt == nil else { return false }
        switch c.state {
        case .new: return true
        case .learning, .relearning: return c.due <= now.addingTimeInterval(learnAhead)
        case .review:
            // 复习卡：当天到期即可
            var cal = Calendar.current
            cal.timeZone = .current
            let endOfDay = cal.startOfDay(for: now).addingTimeInterval(86_400)
            return c.due < endOfDay
        }
    }

    /// 选出下一张：学习中（最早到期）→ 复习（最早到期）→ 新卡（最早创建，受每日上限限制）
    public static func next(from cards: [Card], now: Date, newLimitLeft: Int, reviewLimitLeft: Int) -> Card? {
        let due = cards.filter { isDue($0, now: now) }
        if let l = due.filter({ ($0.state == .learning || $0.state == .relearning) && $0.due <= now })
            .min(by: { $0.due < $1.due }) { return l }
        if reviewLimitLeft > 0, let r = due.filter({ $0.state == .review }).min(by: { $0.due < $1.due }) { return r }
        if newLimitLeft > 0, let n = due.filter({ $0.state == .new }).min(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) { return n }
        // 学习中的卡如果只差几分钟到期，也提前拿出来（避免干等）
        return due.filter { $0.state == .learning || $0.state == .relearning }.min(by: { $0.due < $1.due })
    }

    public static func counts(_ cards: [Card], now: Date, newLimitLeft: Int, reviewLimitLeft: Int) -> Counts {
        var c = Counts()
        for card in cards where isDue(card, now: now) {
            switch card.state {
            case .new: c.new += 1
            case .learning, .relearning: c.learning += 1
            case .review: c.review += 1
            }
        }
        c.new = min(c.new, max(0, newLimitLeft))
        c.review = min(c.review, max(0, reviewLimitLeft))
        return c
    }
}

// MARK: - Anki 内容转换

public enum AnkiContent {
    /// 完形填空：{{c1::答案::提示}} → 正面显示 [提示] 或 [...]，背面显示加粗的答案
    public static func cloze(_ text: String) -> (front: String, back: String) {
        guard let re = try? NSRegularExpression(pattern: #"\{\{c\d+::(.*?)(?:::(.*?))?\}\}"#, options: [.dotMatchesLineSeparators]) else {
            return (text, text)
        }
        let ns = text as NSString
        var front = "", back = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            front += before
            back += before
            let answer = ns.substring(with: m.range(at: 1))
            let hint = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
            front += "<span class=\"cloze\">[\(hint ?? "…")]</span>"
            back += "<span class=\"cloze\">\(answer)</span>"
            last = m.range.location + m.range.length
        }
        let tail = ns.substring(from: last)
        return (front + tail, back + tail)
    }

    /// 填空题里出现的编号（c1、c2…），升序
    public static func clozeNumbers(_ text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\{\{c(\d+)::"#) else { return [] }
        let ns = text as NSString
        let ns2 = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        return Array(Set(ns2)).sorted()
    }

    /// 与 Anki 相同：每个编号一张卡——只挖空这个编号，其余编号直接显示答案
    public static func cloze(_ text: String, number: Int) -> (front: String, back: String) {
        guard let re = try? NSRegularExpression(pattern: #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#, options: [.dotMatchesLineSeparators]) else {
            return (text, text)
        }
        let ns = text as NSString
        var front = "", back = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            front += before
            back += before
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let answer = ns.substring(with: m.range(at: 2))
            let hint = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
            if n == number {
                front += "<span class=\"cloze\">[\(hint ?? "…")]</span>"
                back += "<span class=\"cloze\">\(answer)</span>"
            } else {
                front += answer
                back += answer
            }
            last = m.range.location + m.range.length
        }
        let tail = ns.substring(from: last)
        return (front + tail, back + tail)
    }

    /// 在 text 的 range 处挖空：包成 {{cN::…}}，N 取现有最大编号 + 1（sameNumber 为 true 时沿用最大编号，同一张卡里挖多处）
    public static func wrapCloze(_ text: String, range: NSRange, sameNumber: Bool = false) -> String {
        let ns = text as NSString
        guard range.length > 0, range.location + range.length <= ns.length else { return text }
        let existing = clozeNumbers(text).max() ?? 0
        let n = sameNumber ? max(existing, 1) : existing + 1
        let picked = ns.substring(with: range)
        return ns.replacingCharacters(in: range, with: "{{c\(n)::\(picked)}}")
    }

    /// 去掉全部挖空标记，恢复原文
    public static func unwrapCloze(_ text: String) -> String {
        Markdown.replace(text, #"\{\{c\d+::(.*?)(?:::.*?)?\}\}"#, "$1")
    }

    public static func isCloze(_ text: String) -> Bool {
        text.range(of: #"\{\{c\d+::"#, options: .regularExpression) != nil
    }

    /// 去掉 Anki 的声音标记 [sound:xxx.mp3]
    public static func stripSound(_ s: String) -> String {
        Markdown.replace(s, #"\[sound:[^\]]+\]"#, "")
    }

    /// 由一条笔记的若干字段生成卡片正反面：第一个字段为正面，其余为背面；完形填空笔记特别处理
    public static func faces(fields: [String], isClozeModel: Bool) -> (front: String, back: String) {
        let fs = fields.map(stripSound)
        guard let first = fs.first else { return ("", "") }
        if isClozeModel || isCloze(first) {
            let c = cloze(first)
            let extra = fs.dropFirst().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return (c.front, ([c.back] + extra).joined(separator: "<hr>"))
        }
        let rest = fs.dropFirst().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (first, rest.joined(separator: "<hr>"))
    }
}

// MARK: - Anki 纯文本导出解析

/// 解析 Anki“导出 → 纯文本笔记（Notes in Plain Text）”生成的 .txt。
/// 文件头指令（#separator:tab、#html:true、#tags column:3、#guid column:1、#notetype column:2、#deck column:3）均支持。
public enum AnkiTextImporter {
    public struct Note: Equatable, Sendable {
        public var fields: [String]
        public var tags: [String]
        public var deck: String?
        public var guid: String?
        public var notetype: String?
    }

    public struct Result: Equatable, Sendable {
        public var notes: [Note]
        public var html: Bool
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        public var errorDescription: String? { "文件里没有可导入的笔记。" }
    }

    public static func parse(_ text: String) throws -> Result {
        var separator: Character = "\t"
        var html = true
        var tagsCol: Int?, guidCol: Int?, typeCol: Int?, deckCol: Int?
        var deckDefault: String?
        var bodyLines: [Substring] = []

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var inHeader = true
        for line in lines {
            if inHeader, line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let key = line[line.index(after: line.startIndex)..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "separator":
                    switch value.lowercased() {
                    case "tab": separator = "\t"
                    case "comma": separator = ","
                    case "semicolon": separator = ";"
                    case "space": separator = " "
                    case "pipe": separator = "|"
                    case "colon": separator = ":"
                    default: if let ch = value.first { separator = ch }
                    }
                case "html": html = value.lowercased() == "true"
                case "tags column": tagsCol = Int(value).map { $0 - 1 }
                case "guid column": guidCol = Int(value).map { $0 - 1 }
                case "notetype column": typeCol = Int(value).map { $0 - 1 }
                case "deck column": deckCol = Int(value).map { $0 - 1 }
                case "deck": deckDefault = value
                default: break
                }
                continue
            }
            inHeader = false
            bodyLines.append(line)
        }

        let rows = CSV.parse(bodyLines.joined(separator: "\n"), separator: separator)
        var notes: [Note] = []
        let special = Set([tagsCol, guidCol, typeCol, deckCol].compactMap { $0 })
        for row in rows {
            var fields: [String] = []
            for (i, v) in row.enumerated() where !special.contains(i) { fields.append(v) }
            guard fields.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            if !html { fields = fields.map(Markdown.escape) }
            let tags = tagsCol.flatMap { $0 < row.count ? row[$0] : nil }?
                .split(separator: " ").map(String.init).filter { !$0.isEmpty } ?? []
            notes.append(Note(
                fields: fields,
                tags: tags,
                deck: deckCol.flatMap { $0 < row.count ? row[$0] : nil } ?? deckDefault,
                guid: guidCol.flatMap { $0 < row.count ? row[$0] : nil },
                notetype: typeCol.flatMap { $0 < row.count ? row[$0] : nil }
            ))
        }
        guard !notes.isEmpty else { throw ParseError.empty }
        return Result(notes: notes, html: html)
    }
}

// MARK: - 导入用的中间结构

/// 一条待导入的 Anki 笔记（来自 .apkg 或纯文本），已转成正反面
public struct AnkiNote: Equatable, Sendable {
    public var front: String
    public var back: String
    public var tags: [String]
    public var deck: String
    public var guid: String?
    /// 来自 .apkg 时带复习进度；纯文本导入为 nil（作为新卡）
    public var schedule: Schedule?
    /// 多字段笔记：笔记类型名、字段名与各字段原文（来自 .apkg；完形填空也保留）
    public var noteType: String?
    public var fieldNames: [String] = []
    public var fields: [String] = []
    public var isCloze = false
    /// Anki 的 FSRS 记忆状态（cards.data 里的 s、d），没有则为 nil
    public var memory: Memory?
    /// 这张卡在 Anki 里的复习记录
    public var revlog: [Revlog] = []
    /// 该卡所在牌组在 Anki 里的选项（每日上限、算法、期望保留率）
    public var deckOptions: DeckOptions?

    public struct Memory: Equatable, Sendable {
        public var stability: Double
        public var difficulty: Double
        public init(stability: Double, difficulty: Double) { self.stability = stability; self.difficulty = difficulty }
    }

    public struct Revlog: Equatable, Sendable {
        /// Anki revlog 的 id（毫秒时间戳），用于去重
        public var id: Int64
        public var ease: Int
        public var at: Date { Date(timeIntervalSince1970: TimeInterval(id) / 1000) }
        public init(id: Int64, ease: Int) { self.id = id; self.ease = ease }
    }

    /// 解析 Anki cards.data 字段（JSON，如 {"s":362.2,"d":8.406,"dr":0.9}）
    public static func memory(fromCardData data: String?) -> Memory? {
        guard let data, !data.isEmpty, let d = data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let s = (obj["s"] as? NSNumber)?.doubleValue, let dd = (obj["d"] as? NSNumber)?.doubleValue,
              s > 0, dd > 0 else { return nil }
        return Memory(stability: s, difficulty: dd)
    }

    public struct Schedule: Equatable, Sendable {
        public var state: Card.State
        public var interval: Double
        public var ease: Double
        public var due: Date
        public var reps: Int
        public var lapses: Int
        public var suspended: Bool
        public init(state: Card.State, interval: Double, ease: Double, due: Date, reps: Int, lapses: Int, suspended: Bool) {
            self.state = state; self.interval = interval; self.ease = ease; self.due = due
            self.reps = reps; self.lapses = lapses; self.suspended = suspended
        }
    }

    public init(front: String, back: String, tags: [String], deck: String, guid: String?, schedule: Schedule?) {
        self.front = front; self.back = back; self.tags = tags; self.deck = deck; self.guid = guid; self.schedule = schedule
    }

    /// 由纯文本导入结果生成
    public static func from(_ r: AnkiTextImporter.Result, defaultDeck: String) -> [AnkiNote] {
        r.notes.map { n in
            let isCloze = (n.notetype ?? "").lowercased().contains("cloze") || (n.notetype ?? "").contains("填空")
            let f = AnkiContent.faces(fields: n.fields, isClozeModel: isCloze)
            return AnkiNote(front: f.front, back: f.back, tags: n.tags, deck: n.deck ?? defaultDeck, guid: n.guid, schedule: nil)
        }
    }

    /// 把 Anki 卡片表里的调度字段换算成本应用的格式。
    /// type：0 新卡 1 学习中 2 复习 3 重学；queue = -1 为暂停；
    /// due：复习卡为“距集合创建日的天数”，学习中为 Unix 秒；ivl 为天数；factor 为千分比（2500 = 250%）
    public static func schedule(type: Int, queue: Int, due: Int, ivl: Int, factor: Int, reps: Int, lapses: Int,
                                collectionCreated: Date, now: Date = Date()) -> Schedule? {
        let ease = factor > 0 ? Double(factor) / 1000 : 2.5
        let suspended = queue == -1
        switch type {
        case 0:
            guard suspended else { return nil }   // 普通新卡按新卡处理
            return Schedule(state: .new, interval: 0, ease: 2.5, due: now, reps: 0, lapses: 0, suspended: true)
        case 1, 3:
            let d = due > 1_000_000_000 ? Date(timeIntervalSince1970: TimeInterval(due)) : now
            return Schedule(state: type == 1 ? .learning : .relearning, interval: Double(max(ivl, 0)), ease: ease,
                            due: d, reps: reps, lapses: lapses, suspended: suspended)
        default:
            let d = collectionCreated.addingTimeInterval(TimeInterval(due) * 86_400)
            return Schedule(state: .review, interval: Double(max(ivl, 1)), ease: ease, due: d,
                            reps: reps, lapses: lapses, suspended: suspended)
        }
    }
}

extension Card {
    /// 由摘录生成记忆卡：正面原文，背面译文、按语与出处
    public static func from(_ h: Highlight, source: Source?, deck: String = "摘录", style: CitationStyle = .footnote) -> Card {
        var back: [String] = []
        if let t = h.translation, !t.isEmpty { back.append(t) }
        if let n = h.note, !n.isEmpty { back.append("按：" + n) }
        let cite = CitationFormatter.citation(for: h, source: source, style: style)
        if !cite.isEmpty { back.append("—— " + cite) }
        return Card(deck: deck, front: h.text, back: back.joined(separator: "\n\n"), tags: h.tags, highlightId: h.id)
    }

    /// 渲染用 HTML：Markdown 转 HTML；Anki 媒体文件名改成 kr-media:// 地址
    public static func renderHTML(_ face: String) -> String {
        let html = Markdown.html(face)
        return Markdown.replace(html, #"(<img\b[^>]*\bsrc\s*=\s*")(?![a-zA-Z][a-zA-Z0-9+.-]*:)([^"]+)(")"#, "$1kr-media://media/$2$3")
    }
}
