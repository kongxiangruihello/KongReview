import Foundation

// MARK: - 记忆卡负荷预测与实际保留率（1.1）

/// 统计页“记忆卡”部分用到的计算，与数据库无关，便于测试。
public enum CardForecast {

    /// 某一天到期的卡片数
    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        public var count: Int
        public var id: Date { date }
    }

    public struct Load: Equatable, Sendable {
        /// 今天起 N 天，每天到期张数（已过期的计入今天）
        public var days: [Day]
        public var overdue: Int
        public var total: Int { days.reduce(0) { $0 + $1.count } }
        public var peak: Day? { days.max { $0.count < $1.count } }
        public func average(first n: Int) -> Double {
            let slice = days.prefix(n)
            return slice.isEmpty ? 0 : Double(slice.reduce(0) { $0 + $1.count }) / Double(slice.count)
        }
    }

    /// 由各卡的到期时间算未来 N 天的复习量。新卡（未学过）不在其中，由调用方排除。
    public static func load(dues: [Date], now: Date, days: Int = 30, calendar: Calendar = .current) -> Load {
        let today = calendar.startOfDay(for: now)
        var counts = Array(repeating: 0, count: max(1, days))
        var overdue = 0
        for due in dues {
            let d = calendar.startOfDay(for: due)
            let offset = calendar.dateComponents([.day], from: today, to: d).day ?? 0
            if offset < 0 {
                overdue += 1
                counts[0] += 1
            } else if offset < counts.count {
                counts[offset] += 1
            }
        }
        let out = counts.enumerated().map { i, n in
            Day(date: calendar.date(byAdding: .day, value: i, to: today) ?? today, count: n)
        }
        return Load(days: out, overdue: overdue)
    }

    // MARK: 保留率

    /// 一次作答
    public struct Answer: Equatable, Sendable {
        public var cardId: Int64
        public var answer: Int      // 1 重来，2 困难，3 良好，4 简单
        public var at: Date
        public init(cardId: Int64, answer: Int, at: Date) {
            self.cardId = cardId; self.answer = answer; self.at = at
        }
    }

    /// 一周的复习与答对数
    public struct Week: Equatable, Sendable, Identifiable {
        public var start: Date
        public var reviews: Int
        public var passed: Int
        public var id: Date { start }
        public var retention: Double? { reviews == 0 ? nil : Double(passed) / Double(reviews) }
    }

    public struct Retention: Equatable, Sendable {
        public var weeks: [Week]              // 旧 → 新
        public var last30Reviews: Int
        public var last30Passed: Int
        public var last30: Double? { last30Reviews == 0 ? nil : Double(last30Passed) / Double(last30Reviews) }
    }

    /// 实际保留率：只算“隔天以上再见到”的复习（与上一次作答不在同一天）——
    /// 同一天里的学习步、重学步不算，第一次学新卡也不算。这与 Anki 统计里“真实保留率”只算复习卡的口径相近。
    /// 答“困难 / 良好 / 简单”算记住，“重来”算忘记。
    public static func retention(_ answers: [Answer], now: Date, weeks: Int = 12,
                                 calendar: Calendar = .current) -> Retention {
        let sorted = answers.sorted { $0.cardId == $1.cardId ? $0.at < $1.at : $0.cardId < $1.cardId }
        var cal = calendar
        cal.firstWeekday = 2   // 周一开头
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let starts = (0..<max(1, weeks)).reversed().compactMap {
            cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
        var buckets = starts.map { Week(start: $0, reviews: 0, passed: 0) }
        let since30 = cal.date(byAdding: .day, value: -30, to: now) ?? now
        var r30 = 0, p30 = 0

        var prev: Answer?
        for a in sorted {
            defer { prev = a }
            guard let p = prev, p.cardId == a.cardId else { continue }
            guard !cal.isDate(p.at, inSameDayAs: a.at), a.at <= now else { continue }
            let ok = a.answer > 1
            if a.at >= since30 {
                r30 += 1
                if ok { p30 += 1 }
            }
            if let i = buckets.lastIndex(where: { $0.start <= a.at }) {
                buckets[i].reviews += 1
                if ok { buckets[i].passed += 1 }
            }
        }
        return Retention(weeks: buckets, last30Reviews: r30, last30Passed: p30)
    }
}

/// 各状态的卡片张数（统计页“库存”用，SQL 直接汇总）
public struct CardStateCounts: Equatable, Sendable {
    public var total = 0
    public var new = 0
    public var learning = 0
    public var review = 0
    public var suspended = 0
    public init(total: Int = 0, new: Int = 0, learning: Int = 0, review: Int = 0, suspended: Int = 0) {
        self.total = total; self.new = new; self.learning = learning; self.review = review; self.suspended = suspended
    }
}
