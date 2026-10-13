import Foundation

// MARK: - 每周小结（1.3）

/// 上一周（周一到周日）的回顾情况：每周一在今日回顾页顶部显示一张小结卡，并推送一条通知。
public struct WeeklyDigest: Equatable, Sendable {
    /// 上周一 00:00
    public var start: Date
    /// 本周一 00:00（不含）
    public var end: Date
    public var highlightsReviewed = 0
    public var cardsReviewed = 0
    public var cardsCorrect = 0
    public var newHighlights = 0
    public var newCards = 0
    public var activeDays = 0
    /// 本周金句：上周收藏或回顾过的一条（按周固定）
    public var quoteID: Int64?

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// 以周一为一周开始的日历
    public static func mondayCalendar(_ base: Calendar = .current) -> Calendar {
        var c = base
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// now 所在周的周一 00:00，以及上一周的起止
    public static func previousWeek(of now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let c = mondayCalendar(calendar)
        let thisMonday = c.dateInterval(of: .weekOfYear, for: now)?.start ?? c.startOfDay(for: now)
        let lastMonday = c.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday
        return (lastMonday, thisMonday)
    }

    /// 周的标识（上周一的日期），用于“这一周已看过 / 已通知”
    public var key: String { Self.dayKey(start) }

    public static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public var isEmpty: Bool { highlightsReviewed == 0 && cardsReviewed == 0 && newHighlights == 0 && newCards == 0 }

    public var accuracy: Double? { cardsReviewed > 0 ? Double(cardsCorrect) / Double(cardsReviewed) : nil }

    /// “10月5日—10月11日”
    public func rangeLabel(calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let a = calendar.dateComponents([.month, .day], from: start)
        let b = calendar.dateComponents([.month, .day], from: last)
        if a.month == b.month { return "\(a.month ?? 0)月\(a.day ?? 0)日—\(b.day ?? 0)日" }
        return "\(a.month ?? 0)月\(a.day ?? 0)日—\(b.month ?? 0)月\(b.day ?? 0)日"
    }

    /// 通知正文
    public var notificationBody: String {
        var parts: [String] = []
        if highlightsReviewed > 0 { parts.append("回顾摘录 \(highlightsReviewed) 条") }
        if cardsReviewed > 0 {
            var s = "记忆卡 \(cardsReviewed) 次"
            if let a = accuracy { s += "（答对 \(Int((a * 100).rounded()))%）" }
            parts.append(s)
        }
        if newHighlights > 0 { parts.append("新增摘录 \(newHighlights) 条") }
        parts.append("\(activeDays) 天有回顾")
        return parts.joined(separator: "，") + "。"
    }

    /// 按周固定地从候选里挑一条（同一周每次挑到同一条）
    public static func pick(_ ids: [Int64], weekKey: String) -> Int64? {
        guard !ids.isEmpty else { return nil }
        let h = SHA1.digest(Data(weekKey.utf8))
        let n = h.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return ids.sorted()[Int(n % UInt32(ids.count))]
    }
}
