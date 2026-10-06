import Foundation

/// 每日回顾的调度逻辑。
///
/// 设计参照 Readwise 公开说明的做法（docs.readwise.io → Reviewing Highlights）：
/// 1. 普通回顾按概率抽取：每条摘录基础权重相同，因此摘录越多的书被抽中的概率越大；
///    出处的 `reviewWeight` 可以调高、调低或设为 0（不再出现）。
/// 2. 刚出现过的摘录权重大幅降低，随时间逐渐恢复（这里用“恢复半衰期”建模）。
/// 3. Mastery（记忆卡）按半衰期衰减：回忆概率 p = 0.5^(经过天数 / 半衰期)，
///    p ≤ 0.5 时进入当天回顾，排在末尾。档位沿用 Readwise 的 7 / 14 / 28 天。
///
/// 以后如果要换成 FSRS，只需替换 Mastery 部分（见 docs/ROADMAP.md）。
public struct ReviewScheduler: Sendable {

    public struct Config: Codable, Hashable, Sendable {
        /// 每日普通回顾条数
        public var dailyCount: Int
        /// 每日最多附加的记忆卡条数
        public var masteryLimit: Int
        /// 出现过一次之后，权重恢复一半所需的天数
        public var resurfaceRecoveryHalfLifeDays: Double
        /// 收藏条目的权重倍数
        public var favoriteBoost: Double
        /// 权重下限，保证小库也能抽满
        public var minimumWeight: Double

        public init(
            dailyCount: Int = 10,
            masteryLimit: Int = 5,
            resurfaceRecoveryHalfLifeDays: Double = 30,
            favoriteBoost: Double = 1.5,
            minimumWeight: Double = 0.01
        ) {
            self.dailyCount = dailyCount
            self.masteryLimit = masteryLimit
            self.resurfaceRecoveryHalfLifeDays = resurfaceRecoveryHalfLifeDays
            self.favoriteBoost = favoriteBoost
            self.minimumWeight = minimumWeight
        }

        public static let `default` = Config()
    }

    /// 记忆卡评分档位
    public enum MasteryGrade: String, CaseIterable, Codable, Sendable {
        case again, soon, later, someday

        public var halfLifeDays: Double {
            switch self {
            case .again: return 1
            case .soon: return 7
            case .later: return 14
            case .someday: return 28
            }
        }

        public var label: String {
            switch self {
            case .again: return "没记住"
            case .soon: return "近期再看"
            case .later: return "稍后再看"
            case .someday: return "很久以后"
            }
        }
    }

    /// 普通回顾中对单条摘录的操作
    public enum Action: String, Codable, Sendable {
        /// 看过，保留
        case keep
        /// 弃置，以后不再出现
        case discard
        /// 收藏（提高权重）
        case favorite
    }

    public struct Session: Sendable {
        public var regular: [Highlight]
        public var mastery: [Highlight]
        public var all: [Highlight] { regular + mastery }
    }

    public var config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: 计算

    static let secondsPerDay: Double = 86_400

    public func daysBetween(_ start: Date, _ end: Date) -> Double {
        max(0, end.timeIntervalSince(start) / Self.secondsPerDay)
    }

    /// 回忆概率 p = 0.5^(t / h)
    public func recallProbability(of highlight: Highlight, now: Date) -> Double? {
        guard let h = highlight.masteryHalfLifeDays, h > 0 else { return nil }
        guard let last = highlight.masteryLastReviewedAt else { return 0 }
        return pow(0.5, daysBetween(last, now) / h)
    }

    /// 到期的记忆卡（p ≤ 0.5），越该复习的越靠前
    public func dueMastery(from highlights: [Highlight], now: Date) -> [Highlight] {
        highlights
            .filter { !$0.isDiscarded && !$0.isDeleted }
            .compactMap { h -> (Highlight, Double)? in
                guard let p = recallProbability(of: h, now: now), p <= 0.5 else { return nil }
                return (h, p)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// 单条摘录在普通回顾中的权重
    public func weight(of highlight: Highlight, sourceWeight: Double, now: Date) -> Double {
        guard !highlight.isDiscarded, !highlight.isDeleted, sourceWeight > 0 else { return 0 }
        var w = sourceWeight
        if highlight.isFavorite { w *= config.favoriteBoost }
        if let last = highlight.lastSurfacedAt {
            let days = daysBetween(last, now)
            // 刚出现时接近 0，经过一个恢复半衰期回到 0.5，之后逐渐趋近 1
            let recovery = 1 - pow(0.5, days / config.resurfaceRecoveryHalfLifeDays)
            w *= recovery
        }
        return max(w, config.minimumWeight)
    }

    /// 生成当日回顾。
    /// - Parameters:
    ///   - highlights: 候选摘录（通常是全库，或某个标签下的主题回顾）
    ///   - sourceWeights: 出处 id → 频率系数；缺省按 1 处理
    public func makeSession<R: RandomNumberGenerator>(
        highlights: [Highlight],
        sourceWeights: [Int64: Double],
        now: Date = Date(),
        using rng: inout R
    ) -> Session {
        let mastery = Array(dueMastery(from: highlights, now: now).prefix(config.masteryLimit))
        let masteryIDs = Set(mastery.compactMap(\.id))

        // Efraimidis–Spirakis 加权无放回抽样：key = ln(u) / w，取最大的 k 个
        var keyed: [(Highlight, Double)] = []
        keyed.reserveCapacity(highlights.count)
        for h in highlights {
            if let id = h.id, masteryIDs.contains(id) { continue }
            let sw = h.sourceId.flatMap { sourceWeights[$0] } ?? 1
            let w = weight(of: h, sourceWeight: sw, now: now)
            guard w > 0 else { continue }
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
            keyed.append((h, log(u) / w))
        }
        keyed.sort { $0.1 > $1.1 }
        let regular = keyed.prefix(config.dailyCount).map(\.0)
        return Session(regular: Array(regular), mastery: mastery)
    }

    public func makeSession(
        highlights: [Highlight],
        sourceWeights: [Int64: Double],
        now: Date = Date()
    ) -> Session {
        var rng = SystemRandomNumberGenerator()
        return makeSession(highlights: highlights, sourceWeights: sourceWeights, now: now, using: &rng)
    }

    // MARK: 状态更新

    /// 普通回顾中出现过之后调用（无论用户做何操作）
    public func markSurfaced(_ highlight: Highlight, now: Date = Date()) -> Highlight {
        var h = highlight
        h.lastSurfacedAt = now
        h.surfacedCount += 1
        h.updatedAt = now
        return h
    }

    public func apply(_ action: Action, to highlight: Highlight, now: Date = Date()) -> Highlight {
        var h = markSurfaced(highlight, now: now)
        switch action {
        case .keep: break
        case .discard: h.isDiscarded = true
        case .favorite: h.isFavorite = true
        }
        return h
    }

    /// 加入记忆卡（首次复习安排在明天）
    public func addToMastery(_ highlight: Highlight, now: Date = Date()) -> Highlight {
        var h = highlight
        h.masteryHalfLifeDays = MasteryGrade.again.halfLifeDays
        h.masteryLastReviewedAt = now
        h.updatedAt = now
        return h
    }

    public func removeFromMastery(_ highlight: Highlight, now: Date = Date()) -> Highlight {
        var h = highlight
        h.masteryHalfLifeDays = nil
        h.masteryLastReviewedAt = nil
        h.updatedAt = now
        return h
    }

    public func grade(_ grade: MasteryGrade, _ highlight: Highlight, now: Date = Date()) -> Highlight {
        var h = highlight
        h.masteryHalfLifeDays = grade.halfLifeDays
        h.masteryLastReviewedAt = now
        h.updatedAt = now
        return h
    }
}

// MARK: - 可复现的随机数（测试与“同一天同一组回顾”用）

/// SplitMix64：给定种子得到稳定序列。可用日期作种子，使同一天多次打开看到同一组回顾。
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 以本地日历日期（yyyyMMdd）作种子
    public static func forDay(_ date: Date, calendar: Calendar = .current) -> SeededGenerator {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year: Int = c.year ?? 0
        let month: Int = c.month ?? 0
        let day: Int = c.day ?? 0
        let ymd: Int = year * 10_000 + month * 100 + day
        return SeededGenerator(seed: UInt64(max(0, ymd)))
    }
}
