import Foundation

// MARK: - 每日提醒的排程

/// 提醒不再用“每天重复”的通知，而是逐日排好未来若干天的单次通知；
/// 当天已经回顾过（或提醒时间已过）就不排当天的。这样“回顾过就不提醒”才能实现。
public enum ReminderPlan {
    public static func days(now: Date, hour: Int, minute: Int, reviewedToday: Bool,
                            horizon: Int = 14, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        let start = calendar.startOfDay(for: now)
        for offset in 0..<horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if offset == 0 && (reviewedToday || fire <= now) { continue }
            out.append(fire)
        }
        return out
    }

    /// 通知标识：kongreview.review.2026-10-13
    public static func identifier(for date: Date, calendar: Calendar = .current) -> String {
        "kongreview.review." + dayKey(date, calendar: calendar)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - 回顾统计

public struct ReviewEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case keep, favorite, discard, toCard, note, card
    }
    public var id: Int64?
    public var kind: Kind
    public var highlightId: Int64?
    public var cardId: Int64?
    /// 记忆卡的回答（1–4）
    public var answer: Int?
    public var at: Date

    public init(id: Int64? = nil, kind: Kind, highlightId: Int64? = nil, cardId: Int64? = nil, answer: Int? = nil, at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.highlightId = highlightId
        self.cardId = cardId
        self.answer = answer
        self.at = at
    }
}

public enum ReviewStats {
    public struct Day: Equatable, Sendable {
        public var key: String          // yyyy-MM-dd
        public var highlights: Int      // 当天回顾的摘录条数
        public var cards: Int           // 当天复习的记忆卡次数
        public var total: Int { highlights + cards }
        public init(key: String, highlights: Int, cards: Int) {
            self.key = key; self.highlights = highlights; self.cards = cards
        }
    }

    public struct Summary: Equatable, Sendable {
        public var today: Day
        public var currentStreak: Int   // 连续回顾天数（含今天；今天还没回顾则从昨天算起）
        public var longestStreak: Int
        public var activeDays: Int
        public var totalHighlights: Int
        public var totalCards: Int
        public var lastDays: [Day]      // 最近 N 天，旧 → 新
        public var cardAccuracy: Double? // 记忆卡“非重来”的比例

        public static let empty = Summary(today: Day(key: "", highlights: 0, cards: 0), currentStreak: 0, longestStreak: 0,
                                          activeDays: 0, totalHighlights: 0, totalCards: 0, lastDays: [], cardAccuracy: nil)
    }

    public static func summarize(_ events: [ReviewEvent], now: Date, days: Int = 30, calendar: Calendar = .current) -> Summary {
        var byDay: [String: Day] = [:]
        var again = 0, answered = 0
        for e in events {
            let k = ReminderPlan.dayKey(e.at, calendar: calendar)
            var d = byDay[k] ?? Day(key: k, highlights: 0, cards: 0)
            switch e.kind {
            case .card:
                d.cards += 1
                answered += 1
                if e.answer == CardAnswer.again.rawValue { again += 1 }
            case .note:
                break   // 写按语不单独计数
            default:
                d.highlights += 1
            }
            byDay[k] = d
        }
        return summarize(byDay: byDay, again: again, now: now, days: days, calendar: calendar)
    }

    /// 由按日汇总的数字生成统计（数据库里用 SQL 按日汇总后调用，不必把上万条日志都读进内存）
    public static func summarize(byDay: [String: Day], again: Int, now: Date, days: Int = 30,
                                 calendar: Calendar = .current) -> Summary {
        let answered = byDay.values.reduce(0) { $0 + $1.cards }
        let start = calendar.startOfDay(for: now)
        func key(_ offset: Int) -> String {
            ReminderPlan.dayKey(calendar.date(byAdding: .day, value: -offset, to: start)!, calendar: calendar)
        }
        let todayKey = key(0)
        let today = byDay[todayKey] ?? Day(key: todayKey, highlights: 0, cards: 0)

        // 当前连续天数
        var streak = 0
        var offset = today.total > 0 ? 0 : 1
        while let d = byDay[key(offset)], d.total > 0 { streak += 1; offset += 1 }

        // 最长连续天数
        let activeKeys = byDay.filter { $0.value.total > 0 }.keys.sorted()
        var longest = 0, run = 0
        var prev: Date?
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        for k in activeKeys {
            guard let d = f.date(from: k) else { continue }
            if let p = prev, calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            prev = d
        }

        let last = (0..<days).reversed().map { byDay[key($0)] ?? Day(key: key($0), highlights: 0, cards: 0) }
        return Summary(
            today: today,
            currentStreak: streak,
            longestStreak: longest,
            activeDays: activeKeys.count,
            totalHighlights: byDay.values.reduce(0) { $0 + $1.highlights },
            totalCards: byDay.values.reduce(0) { $0 + $1.cards },
            lastDays: last,
            cardAccuracy: answered == 0 ? nil : Double(answered - again) / Double(answered)
        )
    }
}
