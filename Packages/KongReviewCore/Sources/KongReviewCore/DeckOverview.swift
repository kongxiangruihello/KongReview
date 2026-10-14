import Foundation

// MARK: - 牌组概览（1.7：记忆卡首页重新设计）

/// 牌组的“熟练度”构成：沿用 Anki 的分法——复习间隔 ≥ 21 天为熟记（mature），否则为生疏（young）。
/// 参见 Anki 手册 “Statistics → Card Counts”：Mature cards have an interval of 21 days or greater.
public struct DeckMaturity: Hashable, Sendable {
    public var new = 0
    public var learning = 0
    public var young = 0
    public var mature = 0
    public var suspended = 0

    public init(new: Int = 0, learning: Int = 0, young: Int = 0, mature: Int = 0, suspended: Int = 0) {
        self.new = new; self.learning = learning; self.young = young; self.mature = mature; self.suspended = suspended
    }

    public static let matureDays: Double = 21

    public init(_ cards: [Card]) {
        for c in cards where c.deletedAt == nil {
            if c.isSuspended { suspended += 1; continue }
            switch c.state {
            case .new: new += 1
            case .learning, .relearning: learning += 1
            case .review:
                if c.interval >= Self.matureDays { mature += 1 } else { young += 1 }
            }
        }
    }

    /// 不含暂停的卡
    public var active: Int { new + learning + young + mature }

    /// 已开始学习的卡中“熟记”的比例（0–1）；没有学过任何卡时为 nil
    public var matureRatio: Double? {
        let started = learning + young + mature
        return started == 0 ? nil : Double(mature) / Double(started)
    }

    /// 条形图各段占比（新卡、学习中、生疏、熟记），和为 1；没有卡时全 0
    public var fractions: (new: Double, learning: Double, young: Double, mature: Double) {
        let t = Double(active)
        guard t > 0 else { return (0, 0, 0, 0) }
        return (Double(new) / t, Double(learning) / t, Double(young) / t, Double(mature) / t)
    }

    public static func + (a: DeckMaturity, b: DeckMaturity) -> DeckMaturity {
        DeckMaturity(new: a.new + b.new, learning: a.learning + b.learning, young: a.young + b.young,
                     mature: a.mature + b.mature, suspended: a.suspended + b.suspended)
    }
}

public enum DeckOverview {
    /// “A::B::C” → (上级 “A · B”, 本级 “C”)
    public static func split(_ deck: String) -> (parent: String?, leaf: String) {
        let parts = deck.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return (nil, parts.first ?? deck) }
        return (parts.dropLast().joined(separator: " · "), parts.last!)
    }

    /// 粗估今天剩余的学习时间（分钟）：新卡约 20 秒、学习中约 12 秒、复习约 8 秒（含翻面与评分）。
    /// 只是给人一个量级的感觉，不参与调度。
    public static func estimatedMinutes(_ c: StudyQueue.Counts) -> Int {
        let seconds = c.new * 20 + c.learning * 12 + c.review * 8
        return seconds == 0 ? 0 : max(1, Int((Double(seconds) / 60).rounded()))
    }

    /// 首页标题日期，如“十月十四日 · 星期三”
    public static func chineseDate(_ d: Date, calendar: Calendar = .current) -> String {
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        func num(_ n: Int) -> String {
            if n <= 10 { return n == 10 ? "十" : digits[n] }
            if n < 20 { return "十" + digits[n % 10] }
            return digits[n / 10] + "十" + (n % 10 == 0 ? "" : digits[n % 10])
        }
        let m = calendar.component(.month, from: d), day = calendar.component(.day, from: d)
        let w = calendar.component(.weekday, from: d)   // 1 = 星期日
        let week = ["日", "一", "二", "三", "四", "五", "六"][w - 1]
        return "\(num(m))月\(num(day))日 · 星期\(week)"
    }

    /// 牌组名映射到配色表里的一个位置（同一上级牌组同色），给牌组书脊配色用
    public static func colorIndex(_ deck: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let root = deck.components(separatedBy: "::").first ?? deck
        var h: UInt64 = 0xcbf29ce484222325
        for b in root.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(count))
    }
}
