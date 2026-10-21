import XCTest
@testable import KongReviewCore

/// 3.15：回顾抽样的权重系数与记忆卡的焦点优先
final class V315LearningLoopCoreTests: XCTestCase {
    func testMultipliersShiftSamplingTowardBoostedHighlights() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hs = (1...40).map { Highlight(id: Int64($0), text: "摘录\($0)") }
        let scheduler = ReviewScheduler(config: .init(dailyCount: 10, masteryLimit: 0))
        var boosted = 0, plain = 0
        for seed in 0..<200 {
            var rng = SeededGenerator(seed: UInt64(seed + 1))
            let s = scheduler.makeSession(highlights: hs, sourceWeights: [:],
                                          multipliers: Dictionary(uniqueKeysWithValues: (1...5).map { (Int64($0), 3.0) }), now: now, using: &rng)
            boosted += s.regular.filter { ($0.id ?? 0) <= 5 }.count
            var rng2 = SeededGenerator(seed: UInt64(seed + 1))
            plain += scheduler.makeSession(highlights: hs, sourceWeights: [:], now: now, using: &rng2).regular.filter { ($0.id ?? 0) <= 5 }.count
        }
        XCTAssertGreaterThan(boosted, plain * 2, "加权 3 倍的摘录明显更常被抽到")
        var rng = SeededGenerator(seed: 7)
        let damped = scheduler.makeSession(highlights: Array(hs.prefix(10)), sourceWeights: [:],
                                           multipliers: [1: 0.3], now: now, using: &rng)
        XCTAssertEqual(damped.regular.count, 10, "降权不排除，库小时仍能抽满")
    }

    func testStudyQueuePrefersFocusCardsWithinLimits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = [
            Card(id: 1, deck: "甲", front: "普通复习", highlightId: 10, state: .review, interval: 3, due: now - 7200),
            Card(id: 2, deck: "甲", front: "焦点复习", highlightId: 20, state: .review, interval: 3, due: now - 60),
            Card(id: 3, deck: "甲", front: "普通新卡", highlightId: 11, createdAt: now - 500),
            Card(id: 4, deck: "甲", front: "焦点新卡", highlightId: 21, createdAt: now - 100),
            Card(id: 5, deck: "甲", front: "学习中", state: .learning, step: 0, due: now - 10),
        ]
        let left: (String) -> DailyAmount = { _ in DailyAmount(new: 5, review: 5) }
        let prefer: (Card) -> Bool = { [20, 21].contains($0.highlightId ?? 0) }
        XCTAssertEqual(StudyQueue.next(from: cards, now: now, left: left, prefer: prefer)?.id, 5, "学习中仍最先")
        let rest = cards.filter { $0.id != 5 }
        XCTAssertEqual(StudyQueue.next(from: rest, now: now, left: left, prefer: prefer)?.id, 2, "焦点复习卡先于更早到期的普通卡")
        XCTAssertEqual(StudyQueue.next(from: rest.filter { $0.state == .new }, now: now, left: left, prefer: prefer)?.id, 4)
        XCTAssertEqual(StudyQueue.next(from: rest, now: now, left: { _ in DailyAmount(new: 5, review: 0) }, prefer: prefer)?.id, 4,
                       "复习余额为 0 时不因焦点突破上限")
        XCTAssertEqual(StudyQueue.next(from: rest, now: now, left: left)?.id, 1, "不设焦点时与原顺序一致")
    }
}
