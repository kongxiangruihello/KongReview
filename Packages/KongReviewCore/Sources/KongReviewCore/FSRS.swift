import Foundation

// MARK: - 排程算法的共同接口

public protocol CardScheduling: Sendable {
    func answer(_ card: Card, _ a: CardAnswer, now: Date) -> Card
    func preview(_ card: Card, now: Date) -> [CardAnswer: String]
}

extension CardScheduler: CardScheduling {}

// MARK: - FSRS-6

/// FSRS（Free Spaced Repetition Scheduler）第 6 版，与 Anki 25.x 内置的 FSRS 同一套公式与默认参数。
///
/// 记忆状态用两个量描述：稳定性 S（回忆概率从 100% 降到 90% 所需的天数）与难度 D（1–10）。
/// 每次评分后按公式更新 S、D，再按“期望记忆保留率”算出下次间隔：保留率设得越高，复习越频繁。
/// 公式与默认参数依据 open-spaced-repetition/py-fsrs（scheduler.py）与 FSRS 算法说明。
public struct FSRS: CardScheduling, Sendable {
    /// FSRS-6 默认参数（21 个）
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    /// 各参数的取值范围（参照 fsrs-rs 的参数裁剪范围）
    public static let bounds: [(Double, Double)] = [
        (0.001, 100), (0.001, 100), (0.001, 100), (0.001, 100),
        (1, 10), (0.001, 4), (0.001, 4), (0.001, 0.75),
        (0, 4.5), (0, 0.8), (0.001, 3.5), (0.001, 5), (0.001, 0.25), (0.001, 0.9), (0, 4),
        (0, 1), (1, 6), (0, 2), (0, 2), (0, 0.8), (0.1, 0.8),
    ]

    public static let minStability = 0.001

    public var w: [Double]
    public var desiredRetention: Double
    public var learningSteps: [TimeInterval]
    public var relearningSteps: [TimeInterval]
    public var maximumInterval: Double

    public init(parameters: [Double] = FSRS.defaultParameters, desiredRetention: Double = 0.9,
                learningSteps: [TimeInterval] = [60, 600], relearningSteps: [TimeInterval] = [600],
                maximumInterval: Double = 36_500) {
        self.w = parameters.count == 21 ? parameters : FSRS.defaultParameters
        self.desiredRetention = min(0.99, max(0.7, desiredRetention))
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
        self.maximumInterval = maximumInterval
    }

    var decay: Double { -w[20] }
    var factor: Double { pow(0.9, 1 / decay) - 1 }

    // MARK: 公式

    /// 经过 t 天后的回忆概率
    public func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        pow(1 + factor * max(0, t) / s, decay)
    }

    /// 达到期望保留率的间隔（天，取整，至少 1 天）
    public func interval(stability s: Double) -> Double {
        let raw = s / factor * (pow(desiredRetention, 1 / decay) - 1)
        return min(maximumInterval, max(1, raw.rounded()))
    }

    func initialStability(_ g: Int) -> Double { max(Self.minStability, w[g - 1]) }

    func initialDifficultyRaw(_ g: Int) -> Double { w[4] - exp(w[5] * Double(g - 1)) + 1 }

    func initialDifficulty(_ g: Int) -> Double { clampD(initialDifficultyRaw(g)) }

    func nextDifficulty(_ d: Double, _ g: Int) -> Double {
        let delta = -w[6] * Double(g - 3)
        let damped = d + (10 - d) * delta / 9
        return clampD(w[7] * initialDifficultyRaw(4) + (1 - w[7]) * damped)
    }

    func shortTermStability(_ s: Double, _ g: Int) -> Double {
        var inc = exp(w[17] * (Double(g) - 3 + w[18])) * pow(s, -w[19])
        if g >= 3 { inc = max(inc, 1) }
        return s * inc
    }

    func recallStability(_ s: Double, _ d: Double, _ r: Double, _ g: Int) -> Double {
        let hardPenalty = g == 2 ? w[15] : 1
        let easyBonus = g == 4 ? w[16] : 1
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus)
    }

    func forgetStability(_ s: Double, _ d: Double, _ r: Double) -> Double {
        let longTerm = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
        let shortTerm = s / exp(w[17] * w[18])
        return min(longTerm, shortTerm)
    }

    func clampD(_ d: Double) -> Double { min(10, max(1, d)) }

    /// 一次评分后的记忆状态。memory 为 nil 表示第一次学习；elapsedDays 为 0 表示当天重复（短期公式）
    public func nextMemory(_ memory: (s: Double, d: Double)?, elapsedDays: Int, rating g: Int) -> (s: Double, d: Double) {
        guard let m = memory else { return (initialStability(g), initialDifficulty(g)) }
        let s: Double
        if elapsedDays <= 0 {
            s = shortTermStability(m.s, g)
        } else {
            let r = retrievability(elapsedDays: Double(elapsedDays), stability: m.s)
            s = g == 1 ? forgetStability(m.s, m.d, r) : recallStability(m.s, m.d, r, g)
        }
        return (max(Self.minStability, s), nextDifficulty(m.d, g))
    }

    /// 由复习记录（按时间顺序的 日序号 + 评分）重算记忆状态
    public func memoryState(history: [FSRSReview]) -> (s: Double, d: Double)? {
        var m: (s: Double, d: Double)?
        var lastDay: Int?
        for r in history where (1...4).contains(r.rating) {
            let t = lastDay.map { r.day - $0 } ?? 0
            m = nextMemory(m, elapsedDays: t, rating: r.rating)
            lastDay = r.day
        }
        return m
    }

    /// 没有 FSRS 状态的旧卡（SM-2 排过的）按间隔与难度系数估算：S≈当前间隔，ease 越低越难
    public static func estimatedMemory(for c: Card) -> (s: Double, d: Double)? {
        if let s = c.stability, let d = c.difficulty { return (s, d) }
        guard c.state != .new else { return nil }
        let s = max(0.5, c.interval)
        let d = min(10, max(1, 5 + (2.5 - c.ease) / 0.25))
        return (s, d)
    }

    // MARK: 回答一张卡

    public func answer(_ card: Card, _ a: CardAnswer, now: Date = Date()) -> Card {
        var c = card
        let g = a.rawValue
        let elapsed = c.lastReview.map { max(0, Self.dayNumber(now) - Self.dayNumber($0)) } ?? 0
        let memory = c.state == .new ? nil : Self.estimatedMemory(for: c)
        let next = nextMemory(memory, elapsedDays: elapsed, rating: g)
        c.stability = next.s
        c.difficulty = next.d
        c.reps += 1
        c.updatedAt = now
        c.lastReview = now

        switch c.state {
        case .new, .learning:
            if c.state == .new { c.step = 0 }
            c.state = .learning
            steps(&c, a, learningSteps, s: next.s, now: now)
        case .relearning:
            steps(&c, a, relearningSteps, s: next.s, now: now)
        case .review:
            if a == .again {
                c.lapses += 1
                if relearningSteps.isEmpty {
                    graduate(&c, days: interval(stability: next.s), now: now)
                } else {
                    c.state = .relearning
                    c.step = 0
                    c.due = now.addingTimeInterval(relearningSteps[0])
                }
            } else {
                // 困难 ≤ 良好 < 简单：三个按钮的间隔保持顺序（与 Anki 相同）
                func ivl(_ r: Int) -> Double { interval(stability: nextMemory(memory, elapsedDays: elapsed, rating: r).s) }
                let hard = ivl(2), good = ivl(3), easy = ivl(4)
                let h = min(hard, good)
                let gd = max(good, h + 1)
                let e = max(easy, gd + 1)
                let days: Double = a == .hard ? h : (a == .good ? gd : e)
                graduate(&c, days: min(maximumInterval, days), now: now)
            }
        }
        return c
    }

    private func steps(_ c: inout Card, _ a: CardAnswer, _ steps: [TimeInterval], s: Double, now: Date) {
        guard !steps.isEmpty else {
            graduate(&c, days: interval(stability: s), now: now)
            return
        }
        switch a {
        case .again:
            c.step = 0
            c.due = now.addingTimeInterval(steps[0])
        case .hard:
            let delay: TimeInterval
            if c.step == 0 && steps.count > 1 { delay = (steps[0] + steps[1]) / 2 }
            else { delay = steps[min(c.step, steps.count - 1)] * (steps.count == 1 ? 1.5 : 1) }
            c.due = now.addingTimeInterval(delay)
        case .good:
            if c.step + 1 < steps.count {
                c.step += 1
                c.due = now.addingTimeInterval(steps[c.step])
            } else {
                graduate(&c, days: interval(stability: s), now: now)
            }
        case .easy:
            graduate(&c, days: interval(stability: s), now: now)
        }
    }

    private func graduate(_ c: inout Card, days: Double, now: Date) {
        c.state = .review
        c.step = 0
        c.interval = days
        c.due = CardScheduler().dueDate(days: days, from: now)
    }

    public func preview(_ card: Card, now: Date = Date()) -> [CardAnswer: String] {
        var out: [CardAnswer: String] = [:]
        for a in CardAnswer.allCases {
            let next = answer(card, a, now: now)
            out[a] = CardScheduler.describe(next.due.timeIntervalSince(now), days: next.state == .review ? next.interval : nil)
        }
        return out
    }

    /// 当前回忆概率（界面显示用）；没有记忆状态时为 nil
    public func currentRetrievability(_ c: Card, now: Date = Date()) -> Double? {
        guard let s = c.stability, let last = c.lastReview else { return nil }
        return retrievability(elapsedDays: Double(max(0, Self.dayNumber(now) - Self.dayNumber(last))), stability: s)
    }

    // MARK: 日序号

    /// 以凌晨 4 点为一天开始的日序号（与 Anki 默认的“次日开始时间”一致）
    public static func dayNumber(_ date: Date, timeZone: TimeZone = .current) -> Int {
        let t = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date)) - 4 * 3600
        return Int((t / 86_400).rounded(.down))
    }
}

/// 一次复习记录：日序号与评分（1 重来 2 困难 3 良好 4 简单）
public struct FSRSReview: Equatable, Sendable {
    public var day: Int
    public var rating: Int
    public init(day: Int, rating: Int) { self.day = day; self.rating = rating }
}

// MARK: - 参数优化

/// 用自己的复习记录拟合 FSRS 参数。
///
/// 目标函数与官方优化器相同：对每一次跨日复习，用复习前的记忆状态预测回忆概率 R，
/// 以实际结果（评分 > 1 记为记住）计算对数损失（交叉熵），取平均。
/// 官方 fsrs-rs 用自动求导 + Adam；这里改用不需要导数的 Nelder–Mead 单纯形法，
/// 并加一点向默认参数收缩的正则，避免记录少时过拟合。只有损失确实下降才采用新参数。
public enum FSRSOptimizer {
    public struct Result: Sendable {
        public var parameters: [Double]
        public var lossBefore: Double
        public var lossAfter: Double
        public var reviewCount: Int
        public var improved: Bool { lossAfter < lossBefore - 1e-6 }
    }

    /// 至少需要多少次跨日复习才做优化
    public static let minimumReviews = 400

    /// 平均对数损失与参与计算的复习次数
    public static func loss(_ w: [Double], _ histories: [[FSRSReview]]) -> (loss: Double, count: Int) {
        let f = FSRS(parameters: w)
        var total = 0.0
        var n = 0
        for h in histories {
            var m: (s: Double, d: Double)?
            var lastDay = 0
            for r in h where (1...4).contains(r.rating) {
                if let cur = m {
                    let t = r.day - lastDay
                    if t > 0 {
                        let p = min(1 - 1e-6, max(1e-6, f.retrievability(elapsedDays: Double(t), stability: cur.s)))
                        total += r.rating > 1 ? -log(p) : -log(1 - p)
                        n += 1
                    }
                    m = f.nextMemory(cur, elapsedDays: t, rating: r.rating)
                } else {
                    m = f.nextMemory(nil, elapsedDays: 0, rating: r.rating)
                }
                lastDay = r.day
            }
        }
        return (n > 0 ? total / Double(n) : 0, n)
    }

    static func clamp(_ w: [Double]) -> [Double] {
        var out = w
        for i in out.indices { out[i] = min(FSRS.bounds[i].1, max(FSRS.bounds[i].0, out[i])) }
        // 初始稳定性须满足 重来 ≤ 困难 ≤ 良好 ≤ 简单
        let s = out[0..<4].sorted()
        for i in 0..<4 { out[i] = s[i] }
        return out
    }

    public static func optimize(_ all: [[FSRSReview]], start: [Double] = FSRS.defaultParameters,
                                maxEvaluations: Int = 4000) -> Result {
        let base = loss(start, all)
        guard base.count >= minimumReviews else {
            return Result(parameters: start, lossBefore: base.loss, lossAfter: base.loss, reviewCount: base.count)
        }
        // 留出约 1/5 的卡片做检验：只在没参与拟合的记录上也变好，才算真的改进（防止过拟合）
        var histories: [[FSRSReview]] = []
        var holdout: [[FSRSReview]] = []
        for (i, h) in all.enumerated() { if i % 5 == 4 { holdout.append(h) } else { histories.append(h) } }
        let defaults = FSRS.defaultParameters
        func objective(_ w: [Double]) -> Double {
            let c = clamp(w)
            var reg = 0.0
            for i in c.indices {
                // 初始稳定性跨度大（0.001–100 天），按对数比较；其余按取值范围归一
                let z = i < 4 ? log(c[i] / defaults[i]) / 2
                              : (c[i] - defaults[i]) / (FSRS.bounds[i].1 - FSRS.bounds[i].0)
                reg += z * z
            }
            return loss(c, histories).loss + 0.01 * reg
        }

        // Nelder–Mead
        let n = start.count
        var simplex: [[Double]] = [clamp(start)]
        for i in 0..<n {
            var p = clamp(start)
            let step = max(0.05 * abs(p[i]), 0.01 * (FSRS.bounds[i].1 - FSRS.bounds[i].0))
            p[i] = p[i] + step <= FSRS.bounds[i].1 ? p[i] + step : p[i] - step
            simplex.append(p)
        }
        var values = simplex.map(objective)
        var evals = values.count
        while evals < maxEvaluations {
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if abs(values[n] - values[0]) < 1e-7 { break }
            var centroid = [Double](repeating: 0, count: n)
            for p in simplex.dropLast() { for i in 0..<n { centroid[i] += p[i] / Double(n) } }
            func along(_ t: Double) -> [Double] {
                clamp((0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) })
            }
            let xr = along(-1); let fr = objective(xr); evals += 1
            if fr < values[0] {
                let xe = along(-2); let fe = objective(xe); evals += 1
                if fe < fr { simplex[n] = xe; values[n] = fe } else { simplex[n] = xr; values[n] = fr }
            } else if fr < values[n - 1] {
                simplex[n] = xr; values[n] = fr
            } else {
                let xc = fr < values[n] ? along(-0.5) : along(0.5)
                let fc = objective(xc); evals += 1
                if fc < min(fr, values[n]) {
                    simplex[n] = xc; values[n] = fc
                } else {
                    for k in 1...n {
                        simplex[k] = clamp((0..<n).map { simplex[0][$0] + 0.5 * (simplex[k][$0] - simplex[0][$0]) })
                        values[k] = objective(simplex[k]); evals += 1
                    }
                }
            }
        }
        let bestIndex = values.indices.min { values[$0] < values[$1] } ?? 0
        let best = clamp(simplex[bestIndex])
        let testBefore = loss(start, holdout).loss
        let testAfter = loss(best, holdout).loss
        if testAfter < testBefore {
            return Result(parameters: best, lossBefore: base.loss, lossAfter: loss(best, all).loss, reviewCount: base.count)
        }
        return Result(parameters: start, lossBefore: base.loss, lossAfter: base.loss, reviewCount: base.count)
    }
}

// MARK: - 牌组选项

/// 每个牌组自己的设置；未设置的项沿用全局默认
public struct DeckOptions: Codable, Hashable, Identifiable, Sendable {
    public var id: String { deck }
    public enum Algorithm: String, Codable, CaseIterable, Sendable {
        case sm2, fsrs
        public var label: String { self == .sm2 ? "SM-2（Anki 传统算法）" : "FSRS（按记忆模型安排）" }
    }

    public var deck: String
    public var newPerDay: Int?
    public var reviewsPerDay: Int?
    public var algorithm: Algorithm
    public var desiredRetention: Double

    public init(deck: String, newPerDay: Int? = nil, reviewsPerDay: Int? = nil,
                algorithm: Algorithm = .sm2, desiredRetention: Double = 0.9) {
        self.deck = deck; self.newPerDay = newPerDay; self.reviewsPerDay = reviewsPerDay
        self.algorithm = algorithm; self.desiredRetention = desiredRetention
    }

    public func scheduler(parameters: [Double]) -> any CardScheduling {
        switch algorithm {
        case .sm2: return CardScheduler()
        case .fsrs: return FSRS(parameters: parameters, desiredRetention: desiredRetention)
        }
    }
}
