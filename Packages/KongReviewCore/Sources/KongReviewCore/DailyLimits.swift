import Foundation

// MARK: - 3.13：每日学习量
//
// 一张卡今天能不能出现，要同时满足两级上限：
// 1. 牌组自己的每日上限（单独设置的值，否则用牌组默认值），再加上“仅今天”的加量；
// 2. 全库合计上限（可不设）：所有牌组今天加起来最多学多少新卡、复习多少张，同样可以“仅今天”加量。
// 某个牌组此刻还能学的张数 = min(牌组余额, 全库余额)。牌组之间先学先用全库余额。

/// 新卡、复习各多少张
public struct DailyAmount: Hashable, Codable, Sendable {
    public var new: Int
    public var review: Int

    public init(new: Int = 0, review: Int = 0) {
        self.new = new
        self.review = review
    }

    public static let zero = DailyAmount()
    public var isZero: Bool { new == 0 && review == 0 }

    public static func + (a: DailyAmount, b: DailyAmount) -> DailyAmount {
        DailyAmount(new: a.new + b.new, review: a.review + b.review)
    }

    public subscript(kind: DailyLimitKind) -> Int {
        get { kind == .new ? new : review }
        set { if kind == .new { new = newValue } else { review = newValue } }
    }
}

public enum DailyLimitKind: String, Codable, CaseIterable, Sendable {
    case new, review
    public var label: String { self == .new ? "新卡" : "复习" }
}

/// 牌组单独设置的上限；nil 表示跟随牌组默认值
public struct DailyLimitOverride: Hashable, Sendable {
    public var new: Int?
    public var review: Int?
    public init(new: Int? = nil, review: Int? = nil) {
        self.new = new
        self.review = review
    }
}

/// “仅今天”的加量：只在记录的那一天有效，换日后自动失效，不需要手动改回。
public struct DailyLimitExtra: Hashable, Codable, Sendable {
    /// 与 `DeckOverview.dayKey` 相同的 yyyy-MM-dd
    public var day: String
    public var decks: [String: DailyAmount]
    public var total: DailyAmount

    public init(day: String, decks: [String: DailyAmount] = [:], total: DailyAmount = .zero) {
        self.day = day
        self.decks = decks
        self.total = total
    }

    public var isEmpty: Bool { total.isZero && decks.values.allSatisfy(\.isZero) }

    public func deck(_ name: String, on day: String) -> DailyAmount {
        self.day == day ? decks[name] ?? .zero : .zero
    }

    public func totalAmount(on day: String) -> DailyAmount {
        self.day == day ? total : .zero
    }

    /// 在今天的加量上再叠加；记录的是别的日子时先清空
    public func adding(_ other: DailyLimitExtra) -> DailyLimitExtra {
        guard day == other.day else { return other }
        var result = self
        result.total = result.total + other.total
        for (name, amount) in other.decks { result.decks[name] = (result.decks[name] ?? .zero) + amount }
        return result
    }

    /// 牌组改名或合并时，今日加量跟着牌组走
    public mutating func renameDeck(_ old: String, to new: String) {
        guard old != new, let amount = decks.removeValue(forKey: old) else { return }
        decks[new] = (decks[new] ?? .zero) + amount
    }
}

/// 每日上限的全部设置：牌组默认值、全库合计上限与“仅今天”加量。
public struct DailyLimitSettings: Hashable, Sendable {
    /// 未单独设置的牌组每天新卡、复习上限
    public var newPerDay: Int
    public var reviewsPerDay: Int
    /// 全库合计；nil 表示不限
    public var totalNewPerDay: Int?
    public var totalReviewsPerDay: Int?
    public var extra: DailyLimitExtra?

    public init(newPerDay: Int = 20, reviewsPerDay: Int = 200,
                totalNewPerDay: Int? = nil, totalReviewsPerDay: Int? = nil,
                extra: DailyLimitExtra? = nil) {
        self.newPerDay = newPerDay
        self.reviewsPerDay = reviewsPerDay
        self.totalNewPerDay = totalNewPerDay
        self.totalReviewsPerDay = totalReviewsPerDay
        self.extra = extra
    }

    /// 输入框和备份共用的取值范围
    public static let valueRange: ClosedRange<Int> = 0...9999

    public static func clamp(_ value: Int) -> Int {
        min(max(value, valueRange.lowerBound), valueRange.upperBound)
    }
}

/// 某一天的上限账本：把设置、牌组单独设置和今天已学张数放在一起，回答“还能学几张”。
public struct DailyLimitLedger: Sendable {
    public let settings: DailyLimitSettings
    public let day: String
    public let overrides: [String: DailyLimitOverride]
    /// 今天已学（按卡片当前所在牌组）。已彻底删除、无法归入牌组的卡记在空字符串下，只计入全库合计。
    public let spent: [String: DailyAmount]
    /// 不按牌组划分的学习范围（如笔记本）今天已学；只用于该范围自己的余额，不重复计入全库合计。
    public let scopeSpent: [String: DailyAmount]

    public init(settings: DailyLimitSettings, day: String,
                overrides: [String: DailyLimitOverride] = [:], spent: [String: DailyAmount] = [:],
                scopeSpent: [String: DailyAmount] = [:]) {
        self.settings = settings
        self.day = day
        self.overrides = overrides
        self.spent = spent
        self.scopeSpent = scopeSpent
    }

    /// 笔记本学习的额度键：沿用牌组默认值作为这个笔记本的额度，也可单独“仅今天”加量
    public static func notebookKey(_ id: Int64) -> String { "\u{1}notebook:\(id)" }

    public static func isScopeKey(_ key: String) -> Bool { key.hasPrefix("\u{1}") }

    /// 记下某个学习范围今天已学的张数
    public func with(scope key: String, spent amount: DailyAmount) -> DailyLimitLedger {
        var scopes = scopeSpent
        scopes[key] = amount
        return DailyLimitLedger(settings: settings, day: day, overrides: overrides, spent: spent, scopeSpent: scopes)
    }

    /// 牌组自己的每日上限，含仅今天加量
    public func deckLimit(_ deck: String) -> DailyAmount {
        let o = overrides[deck]
        let extra = settings.extra?.deck(deck, on: day) ?? .zero
        return DailyAmount(new: (o?.new ?? settings.newPerDay) + extra.new,
                           review: (o?.review ?? settings.reviewsPerDay) + extra.review)
    }

    /// 牌组自己的上限是否单独设置过
    public func isOverridden(_ deck: String, _ kind: DailyLimitKind) -> Bool {
        kind == .new ? overrides[deck]?.new != nil : overrides[deck]?.review != nil
    }

    /// 全库合计上限，含仅今天加量；nil 表示不限
    public func totalLimit(_ kind: DailyLimitKind) -> Int? {
        let base = kind == .new ? settings.totalNewPerDay : settings.totalReviewsPerDay
        guard let base else { return nil }
        return base + (settings.extra?.totalAmount(on: day)[kind] ?? 0)
    }

    public func spent(_ deck: String) -> DailyAmount { scopeSpent[deck] ?? spent[deck] ?? .zero }

    /// 今天全库已学
    public var totalSpent: DailyAmount { spent.values.reduce(.zero, +) }

    /// 全库还剩；不限时为 Int.max
    public var totalLeft: DailyAmount {
        let s = totalSpent
        return DailyAmount(new: totalLimit(.new).map { max(0, $0 - s.new) } ?? .max,
                           review: totalLimit(.review).map { max(0, $0 - s.review) } ?? .max)
    }

    /// 只看牌组自己的上限还剩多少
    public func deckLeft(_ deck: String) -> DailyAmount {
        let limit = deckLimit(deck), s = spent(deck)
        return DailyAmount(new: max(0, limit.new - s.new), review: max(0, limit.review - s.review))
    }

    /// 这个牌组此刻实际还能学：牌组余额与全库余额取小
    public func left(_ deck: String) -> DailyAmount {
        let own = deckLeft(deck), total = totalLeft
        return DailyAmount(new: min(own.new, total.new), review: min(own.review, total.review))
    }

    /// 实际生效的上限（牌组上限与全库合计取小），用来判断“上限为 0、永远学不到”
    public func effectiveLimit(_ deck: String) -> DailyAmount {
        let own = deckLimit(deck)
        return DailyAmount(new: min(own.new, totalLimit(.new) ?? .max),
                           review: min(own.review, totalLimit(.review) ?? .max))
    }

    // MARK: 仅今天加量的计划

    public struct ExtraPlan: Hashable, Sendable {
        /// 实际能多放出的张数（可能少于请求的张数：卡片本身不够）
        public var added: Int
        /// 要叠加到今天的加量
        public var extra: DailyLimitExtra
    }

    /// 让这些牌组今天再多学 n 张（新卡或复习）：只在真正卡住的那一级加量。
    /// - `available`：各牌组此刻实际有的卡（不考虑上限），新卡为未学新卡数，复习为今天到期的复习卡数。
    /// - 牌组自身卡住的部分按牌组名顺序补足；全库合计卡住时同时提高今天的合计。
    public func extraPlan(adding n: Int, kind: DailyLimitKind, available: [String: Int]) -> ExtraPlan {
        let decks = available.keys.sorted()
        let ownAllowed = decks.reduce(0) { $0 + min(deckLeft($1)[kind], max(0, available[$1] ?? 0)) }
        let totalRemaining = totalLeft[kind]
        let current = min(ownAllowed, totalRemaining)
        let supply = decks.reduce(0) { $0 + max(0, available[$1] ?? 0) }
        let added = max(0, min(n, supply - current))
        var extra = DailyLimitExtra(day: day)
        guard added > 0 else { return ExtraPlan(added: 0, extra: extra) }
        var deckNeed = max(0, current + added - ownAllowed)
        for deck in decks where deckNeed > 0 {
            let blocked = max(0, (available[deck] ?? 0) - deckLeft(deck)[kind])
            let give = min(blocked, deckNeed)
            guard give > 0 else { continue }
            var amount = DailyAmount()
            amount[kind] = give
            extra.decks[deck] = amount
            deckNeed -= give
        }
        if totalLimit(kind) != nil {
            let totalNeed = max(0, current + added - totalRemaining)
            extra.total[kind] = totalNeed
        }
        return ExtraPlan(added: added, extra: extra)
    }
}

public extension DailyAmount {
    static let max = DailyAmount(new: .max, review: .max)
}

// MARK: - 跨牌组取卡

public extension StudyQueue {
    /// 一组牌组里选下一张：学习中（最早到期）→ 复习（最早到期，所在牌组仍有余额）→ 新卡（最早创建，所在牌组仍有余额）。
    /// `left` 给出每个牌组此刻还能学的张数（已与全库合计取小），学完一张后应重新计算。
    static func next(from cards: [Card], now: Date, left: (String) -> DailyAmount) -> Card? {
        let due = cards.filter { isDue($0, now: now) }
        if let l = due.filter({ ($0.state == .learning || $0.state == .relearning) && $0.due <= now })
            .min(by: { $0.due < $1.due }) { return l }
        var cache: [String: DailyAmount] = [:]
        func remaining(_ deck: String) -> DailyAmount {
            if let v = cache[deck] { return v }
            let v = left(deck)
            cache[deck] = v
            return v
        }
        if let r = due.filter({ $0.state == .review && remaining($0.deck).review > 0 })
            .min(by: { $0.due < $1.due }) { return r }
        if let n = due.filter({ $0.state == .new && remaining($0.deck).new > 0 })
            .min(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) { return n }
        return due.filter { $0.state == .learning || $0.state == .relearning }.min(by: { $0.due < $1.due })
    }

    /// 一组牌组合计可学：各牌组按自己的余额计数，再与全库余额取小
    static func counts(_ cards: [Card], now: Date, ledger: DailyLimitLedger) -> Counts {
        var result = Counts()
        for (deck, group) in Dictionary(grouping: cards, by: \.deck) {
            let left = ledger.deckLeft(deck)
            let c = counts(group, now: now, newLimitLeft: left.new, reviewLimitLeft: left.review)
            result.new += c.new
            result.learning += c.learning
            result.review += c.review
        }
        let total = ledger.totalLeft
        result.new = min(result.new, total.new)
        result.review = min(result.review, total.review)
        return result
    }
}
