import XCTest
@testable import KongReviewCore

/// 3.13：每日学习量账本——牌组上限、全库合计、仅今天加量与跨牌组取卡
final class V313DailyLimitsTests: XCTestCase {
    private let today = "2026-10-20"

    private func ledger(_ settings: DailyLimitSettings, overrides: [String: DailyLimitOverride] = [:],
                        spent: [String: DailyAmount] = [:], day: String? = nil) -> DailyLimitLedger {
        DailyLimitLedger(settings: settings, day: day ?? today, overrides: overrides, spent: spent)
    }

    func testDeckLimitTotalAndTodayExtraCombine() {
        let extra = DailyLimitExtra(day: today, decks: ["甲": DailyAmount(new: 5)], total: DailyAmount(new: 10))
        let settings = DailyLimitSettings(newPerDay: 20, reviewsPerDay: 200, totalNewPerDay: 30, extra: extra)
        let spent = ["甲": DailyAmount(new: 8, review: 3), "乙": DailyAmount(new: 25), "": DailyAmount(new: 2, review: 1)]
        let l = ledger(settings, overrides: ["甲": DailyLimitOverride(new: 10)], spent: spent)
        XCTAssertEqual(l.deckLimit("甲"), DailyAmount(new: 15, review: 200), "单独设置 10 + 今日加量 5；复习跟随默认")
        XCTAssertEqual(l.deckLimit("乙"), DailyAmount(new: 20, review: 200))
        XCTAssertTrue(l.isOverridden("甲", .new))
        XCTAssertFalse(l.isOverridden("甲", .review))
        XCTAssertEqual(l.totalLimit(.new), 40, "合计 30 + 今日加量 10")
        XCTAssertNil(l.totalLimit(.review))
        XCTAssertEqual(l.totalSpent, DailyAmount(new: 35, review: 4), "已删除、无法归入牌组的卡也计入合计")
        XCTAssertEqual(l.totalLeft, DailyAmount(new: 5, review: .max))
        XCTAssertEqual(l.deckLeft("甲"), DailyAmount(new: 7, review: 197))
        XCTAssertEqual(l.left("甲"), DailyAmount(new: 5, review: 197), "牌组余额与全库余额取小")
        XCTAssertEqual(l.left("乙"), DailyAmount(new: 0, review: 200))
        XCTAssertEqual(l.effectiveLimit("乙"), DailyAmount(new: 20, review: 200))

        let tomorrow = ledger(settings, overrides: ["甲": DailyLimitOverride(new: 10)], day: "2026-10-21")
        XCTAssertEqual(tomorrow.deckLimit("甲"), DailyAmount(new: 10, review: 200), "加量只在记录的那一天有效")
        XCTAssertEqual(tomorrow.totalLimit(.new), 30)
    }

    func testOverLimitSpentNeverGoesNegative() {
        let l = ledger(DailyLimitSettings(newPerDay: 2, totalNewPerDay: 1), spent: ["甲": DailyAmount(new: 5)])
        XCTAssertEqual(l.deckLeft("甲").new, 0)
        XCTAssertEqual(l.totalLeft.new, 0)
        XCTAssertEqual(l.left("乙").new, 0, "全库合计已用完时，其他牌组也不再出新卡")
    }

    func testScopeSpentCountsOnlyForThatScope() {
        let key = DailyLimitLedger.notebookKey(7)
        XCTAssertTrue(DailyLimitLedger.isScopeKey(key))
        XCTAssertFalse(DailyLimitLedger.isScopeKey("甲"))
        let extra = DailyLimitExtra(day: today, decks: [key: DailyAmount(new: 2)])
        let base = ledger(DailyLimitSettings(newPerDay: 5, totalNewPerDay: 6, extra: extra), spent: ["甲": DailyAmount(new: 3)])
        let l = base.with(scope: key, spent: DailyAmount(new: 3))
        XCTAssertEqual(l.spent(key), DailyAmount(new: 3))
        XCTAssertEqual(l.totalSpent, DailyAmount(new: 3), "笔记本卡的学习记录已算在牌组里，不重复计入合计")
        XCTAssertEqual(l.deckLimit(key).new, 7, "笔记本额度＝牌组默认值＋本笔记本今日加量")
        XCTAssertEqual(l.left(key).new, 3, "笔记本余额 4 与全库余额 3 取小")
    }

    // MARK: 仅今天加量

    func testExtraPlanRaisesOnlyTheDeckWhenDeckLimitBlocks() {
        let l = ledger(DailyLimitSettings(newPerDay: 2), spent: ["甲": DailyAmount(new: 2)])
        let plan = l.extraPlan(adding: 3, kind: .new, available: ["甲": 5])
        XCTAssertEqual(plan.added, 3)
        XCTAssertEqual(plan.extra.decks["甲"], DailyAmount(new: 3))
        XCTAssertEqual(plan.extra.total, .zero, "没有全库合计时不加合计")
    }

    func testExtraPlanRaisesOnlyTheTotalWhenTotalBlocks() {
        let l = ledger(DailyLimitSettings(newPerDay: 20, totalNewPerDay: 5), spent: ["甲": DailyAmount(new: 5)])
        let plan = l.extraPlan(adding: 4, kind: .new, available: ["甲": 10])
        XCTAssertEqual(plan.added, 4)
        XCTAssertTrue(plan.extra.decks.isEmpty, "牌组自身还有余额，不必加牌组")
        XCTAssertEqual(plan.extra.total, DailyAmount(new: 4))
    }

    func testExtraPlanRaisesBothLevelsAndDistributesByDeckName() {
        let l = ledger(DailyLimitSettings(newPerDay: 2, totalNewPerDay: 3),
                       spent: ["甲": DailyAmount(new: 2), "乙": DailyAmount(new: 1)])
        let plan = l.extraPlan(adding: 3, kind: .new, available: ["甲": 4, "乙": 1])
        XCTAssertEqual(plan.added, 3)
        XCTAssertEqual(plan.extra.decks["甲"], DailyAmount(new: 2), "乙 还有 1 张余额可用，甲 补 2 张")
        XCTAssertNil(plan.extra.decks["乙"])
        XCTAssertEqual(plan.extra.total, DailyAmount(new: 3))
        // 叠加后正好多放出 3 张
        var settings = l.settings
        settings.extra = DailyLimitExtra(day: today).adding(plan.extra)
        let after = DailyLimitLedger(settings: settings, day: today, spent: l.spent)
        let allowed = min(min(after.deckLeft("甲").new, 4) + min(after.deckLeft("乙").new, 1), after.totalLeft.new)
        XCTAssertEqual(allowed, 3)
    }

    func testExtraPlanIsBoundedByAvailableCards() {
        let l = ledger(DailyLimitSettings(reviewsPerDay: 10), spent: ["甲": DailyAmount(review: 10)])
        let plan = l.extraPlan(adding: 50, kind: .review, available: ["甲": 7])
        XCTAssertEqual(plan.added, 7)
        XCTAssertEqual(plan.extra.decks["甲"], DailyAmount(review: 7))
        XCTAssertEqual(l.extraPlan(adding: 5, kind: .review, available: ["甲": 0]).added, 0)
    }

    func testExtraAddingRenamingAndExpiry() {
        var extra = DailyLimitExtra(day: today, decks: ["甲": DailyAmount(new: 2)])
        extra = extra.adding(DailyLimitExtra(day: today, decks: ["甲": DailyAmount(new: 3), "乙": DailyAmount(review: 5)],
                                             total: DailyAmount(new: 1)))
        XCTAssertEqual(extra.decks["甲"], DailyAmount(new: 5))
        XCTAssertEqual(extra.decks["乙"], DailyAmount(review: 5))
        XCTAssertEqual(extra.total, DailyAmount(new: 1))
        extra.renameDeck("甲", to: "乙")
        XCTAssertNil(extra.decks["甲"])
        XCTAssertEqual(extra.decks["乙"], DailyAmount(new: 5, review: 5), "合并进已有牌组时加量相加")
        let fresh = extra.adding(DailyLimitExtra(day: "2026-10-21", total: DailyAmount(new: 2)))
        XCTAssertEqual(fresh.day, "2026-10-21")
        XCTAssertTrue(fresh.decks.isEmpty, "换日后旧加量不再沿用")
        XCTAssertEqual(extra.deck("乙", on: "2026-10-21"), .zero)
        XCTAssertTrue(DailyLimitExtra(day: today, decks: ["甲": .zero]).isEmpty)
        let data = try! JSONEncoder().encode(extra)
        XCTAssertEqual(try! JSONDecoder().decode(DailyLimitExtra.self, from: data), extra)
    }

    func testClampKeepsValuesInRange() {
        XCTAssertEqual(DailyLimitSettings.clamp(-3), 0)
        XCTAssertEqual(DailyLimitSettings.clamp(12_000), 9999)
        XCTAssertEqual(DailyLimitSettings.clamp(35), 35)
    }

    // MARK: 跨牌组取卡

    func testNextAcrossDecksRespectsEachDeckRemaining() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = [
            Card(id: 1, deck: "甲", front: "甲新", createdAt: now - 100),
            Card(id: 2, deck: "乙", front: "乙新（更早）", createdAt: now - 200),
            Card(id: 3, deck: "乙", front: "乙复习", state: .review, interval: 3, due: now - 10),
            Card(id: 4, deck: "甲", front: "甲学习中", state: .learning, step: 1, due: now - 5),
        ]
        let left: [String: DailyAmount] = ["甲": DailyAmount(new: 1, review: 0), "乙": DailyAmount(new: 0, review: 1)]
        func next(_ cs: [Card], _ l: [String: DailyAmount] = left) -> Int64? {
            StudyQueue.next(from: cs, now: now, left: { l[$0] ?? .zero })?.id
        }
        XCTAssertEqual(next(cards), 4, "学习中优先，不受上限限制")
        XCTAssertEqual(next(cards.filter { $0.id != 4 }), 3)
        XCTAssertEqual(next(cards.filter { $0.id != 4 && $0.id != 3 }), 1, "乙 新卡余额为 0，跳过更早的乙新卡")
        XCTAssertNil(next(cards.filter { $0.id == 1 || $0.id == 2 }, ["甲": .zero, "乙": .zero]))
    }

    func testCountsAcrossDecksAreCappedByTotal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = (1...6).map { Card(id: Int64($0), deck: $0 <= 3 ? "甲" : "乙", front: "新\($0)", createdAt: now - Double($0)) }
        let l = ledger(DailyLimitSettings(newPerDay: 2, totalNewPerDay: 3))
        XCTAssertEqual(StudyQueue.counts(cards, now: now, ledger: l).new, 3, "各牌组 2 张，合计受 3 张约束")
        let unlimited = ledger(DailyLimitSettings(newPerDay: 2))
        XCTAssertEqual(StudyQueue.counts(cards, now: now, ledger: unlimited).new, 4)
    }
}
