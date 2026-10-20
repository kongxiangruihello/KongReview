import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 3.13：全库合计上限、仅今天加量、混合学习与各处口径一致
final class V313DailyLimitTests: XCTestCase {
    private let keys = [CardSettings.newPerDayKey, CardSettings.reviewsPerDayKey,
                        CardSettings.totalNewEnabledKey, CardSettings.totalNewPerDayKey,
                        CardSettings.totalReviewsEnabledKey, CardSettings.totalReviewsPerDayKey,
                        CardSettings.todayExtraKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 20, hour: 12))! }

    private func seed(_ db: AppDatabase, decks: [String: Int], at date: Date? = nil) throws {
        for (deck, count) in decks {
            for i in 0..<count {
                _ = try db.save(Card(deck: deck, front: "\(deck)\(i)", due: date ?? now,
                                     createdAt: (date ?? now).addingTimeInterval(Double(-1000 + i))))
            }
        }
    }

    // MARK: 统计口径

    func testTotalCapLimitsLibraryQueueButEachDeckShowsItsOwnShare() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 3, "乙": 3])
        let limits = DailyLimitSettings(newPerDay: 2, reviewsPerDay: 200, totalNewPerDay: 3)
        let global = try db.cardLearningSummary(scope: .all, now: now, calendar: calendar, limits: limits)
        XCTAssertEqual(global.pending.new, 3, "两个牌组各 2 张，合计受 3 张约束")
        XCTAssertEqual(global.availability.blockedNew, 3)
        XCTAssertTrue(global.availability.detail.contains("全库每天新卡合计 3 张"))
        let decks = try db.deckSummaries(now: now, calendar: calendar, limits: limits)
        XCTAssertEqual(decks.map(\.counts.new), [2, 2], "牌组页各自显示 min(牌组余额, 全库余额)")

        // 学掉 3 张后全库合计用完：所有牌组都不再出新卡，且明天可学
        // “简单”直接毕业为复习卡，不留下学习中的卡
        for card in try db.cards(deck: "甲").prefix(2) { _ = try db.answer(card, .easy, now: now) }
        _ = try db.answer(try XCTUnwrap(db.cards(deck: "乙").first), .easy, now: now)
        let after = try db.cardLearningSummary(scope: .deck("乙"), now: now, calendar: calendar, limits: limits)
        XCTAssertEqual(after.pending.new, 0)
        XCTAssertEqual(after.availability.kind, .dailyLimit)
        XCTAssertNotNil(after.availability.nextAvailableAt)
        XCTAssertEqual(try db.deckSummaries(now: now, calendar: calendar, limits: limits).map(\.counts.new), [0, 0])
    }

    func testZeroTotalCapIsReportedAsZeroLimitNotTomorrow() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 1])
        let summary = try db.cardLearningSummary(scope: .all, now: now, calendar: calendar,
                                                 limits: DailyLimitSettings(totalNewPerDay: 0))
        XCTAssertEqual(summary.pending.new, 0)
        XCTAssertTrue(summary.availability.detail.contains("全库新卡合计上限为 0"))
        XCTAssertNil(summary.availability.nextAvailableAt)
    }

    func testBackgroundSnapshotMatchesDirectSummariesWithTotalsAndExtras() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 4, "乙": 4, "丙": 1])
        _ = try db.save(Card(deck: "乙", front: "复习", state: .review, due: now))
        try db.save(DeckOptions(deck: "甲", newPerDay: 1))
        _ = try db.answer(try XCTUnwrap(db.cards(deck: "丙").first), .good, now: now)
        let day = ReminderPlan.dayKey(now, calendar: calendar)
        let limits = DailyLimitSettings(newPerDay: 3, reviewsPerDay: 200, totalNewPerDay: 5, totalReviewsPerDay: 0,
                                        extra: DailyLimitExtra(day: day, decks: ["甲": DailyAmount(new: 1)]))
        for scope in [CardLearningScope.all, .deck("甲"), .deck("乙")] {
            let snapshot = try db.derivedLibrarySnapshot(.init(now: now, dailyReviewCount: 5, limits: limits,
                                                               scope: scope, session: nil))
            XCTAssertEqual(snapshot.globalCards, try db.cardLearningSummary(now: now, limits: limits))
            XCTAssertEqual(snapshot.scopedCards, try db.cardLearningSummary(scope: scope, now: now, limits: limits))
            XCTAssertEqual(snapshot.decks, try db.deckSummaries(now: now, limits: limits))
            XCTAssertEqual(snapshot.home, try db.homeLearningSummary(now: now, dailyReviewCount: 5, limits: limits, session: nil))
        }
        let snapshot = try db.derivedLibrarySnapshot(.init(now: now, dailyReviewCount: 5, limits: limits, scope: .all, session: nil))
        XCTAssertEqual(snapshot.globalCards.pending.new, 4, "丙 已学 1 张，全库还剩 4；甲 2（含今日加量）+ 乙 3 被合计截到 4")
        XCTAssertEqual(snapshot.globalCards.pending.review, 0, "复习合计为 0")
        XCTAssertEqual(snapshot.home.cardsNewDueCount, 4, "首页不再把各牌组数字直接相加")
        XCTAssertEqual(snapshot.decks.first { $0.name == "甲" }?.counts.new, 2)
        XCTAssertEqual(snapshot.ledger.totalSpent.new, 1)
    }

    func testPermanentlyDeletedCardStillCountsTowardTotal() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 2])
        let gone = try db.save(Card(deck: "乙", front: "将删除", due: now))
        _ = try db.answer(gone, .good, now: now)
        _ = try db.writer.write { db in try Card.deleteOne(db, key: gone.id!) }
        let limits = DailyLimitSettings(newPerDay: 5, totalNewPerDay: 2)
        let ledger = try db.dailyLimitLedger(now: now, calendar: calendar, limits: limits)
        XCTAssertEqual(ledger.totalSpent.new, 1)
        XCTAssertEqual(try db.cardLearningSummary(scope: .deck("甲"), now: now, calendar: calendar, limits: limits).pending.new, 1)
    }

    func testNotebookKeepsItsOwnQuotaButRespectsTotal() throws {
        let db = try AppDatabase(DatabaseQueue())
        let notebook = try db.createNotebook(title: "经学")
        var blocks: [NotebookBlock] = []
        for i in 0..<3 {
            let h = try db.save(Highlight(text: "摘录\(i)"))
            blocks.append(NotebookBlock(notebookId: notebook.id!, position: i + 1, kind: .highlight, highlightId: h.id))
            _ = try db.save(Card(deck: "甲", front: "笔记本卡\(i)", highlightId: h.id, due: now))
        }
        _ = try db.insertBlocks(blocks, into: notebook.id!, after: nil)
        try db.save(DeckOptions(deck: "甲", newPerDay: 0))
        let ownQuota = try db.cardLearningSummary(scope: .notebook(notebook.id!), now: now, calendar: calendar,
                                                  limits: DailyLimitSettings(newPerDay: 3))
        XCTAssertEqual(ownQuota.pending.new, 3, "笔记本仍以牌组默认值为额度，不套用单个牌组选项")
        let capped = try db.cardLearningSummary(scope: .notebook(notebook.id!), now: now, calendar: calendar,
                                                limits: DailyLimitSettings(newPerDay: 3, totalNewPerDay: 1))
        XCTAssertEqual(capped.pending.new, 1, "3.13：同时受全库合计约束")
    }

    func testFutureReminderEstimateUsesEachDeckLimitAndTotal() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 5, "乙": 5])
        try db.save(DeckOptions(deck: "甲", newPerDay: 1))
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(try db.cardsDue(on: tomorrow, limits: DailyLimitSettings(newPerDay: 3)), 4, "甲 1 + 乙 3")
        XCTAssertEqual(try db.cardsDue(on: tomorrow, limits: DailyLimitSettings(newPerDay: 3, totalNewPerDay: 2)), 2)
    }

    func testSavingOverridesKeepsAlgorithmAndRetention() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(DeckOptions(deck: "甲", newPerDay: 5, algorithm: .fsrs, desiredRetention: 0.93))
        try db.saveDailyLimitOverrides(["甲": DailyLimitOverride(new: nil, review: 12_000), "乙": DailyLimitOverride(new: 8)])
        let options = try db.deckOptions()
        XCTAssertNil(options["甲"]?.newPerDay, "改回跟随默认")
        XCTAssertEqual(options["甲"]?.reviewsPerDay, 9999, "超出范围收回 9999")
        XCTAssertEqual(options["甲"]?.algorithm, .fsrs)
        XCTAssertEqual(options["甲"]?.desiredRetention, 0.93)
        XCTAssertEqual(options["乙"]?.newPerDay, 8)
    }

    func testOverviewListsDecksWithSpentAndAvailable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 3])
        _ = try db.save(Card(deck: "甲", front: "复习", state: .review, due: now))
        _ = try db.save(Card(deck: "甲", front: "暂停", isSuspended: true))
        try db.save(DeckOptions(deck: "空牌组", newPerDay: 4))
        _ = try db.answer(try XCTUnwrap(db.cards(deck: "甲").first { $0.state == .new && !$0.isSuspended }), .good, now: now)
        let overview = try db.dailyLimitOverview(now: now, calendar: calendar)
        XCTAssertEqual(overview.rows.map(\.deck), ["甲", "空牌组"])
        let row = try XCTUnwrap(overview.rows.first)
        XCTAssertEqual(row.spent, DailyAmount(new: 1))
        XCTAssertEqual(row.availableNew, 2, "暂停的卡不计")
        XCTAssertEqual(row.dueReview, 1)
        XCTAssertEqual(overview.rows.last?.override.new, 4)
    }

    func testDraftPreviewMatchesQueue() throws {
        let db = try AppDatabase(DatabaseQueue())
        try seed(db, decks: ["甲": 4, "乙": 4])
        let overview = try db.dailyLimitOverview(now: now, calendar: calendar)
        var draft = DailyLimitsDraft(overview: overview, newPerDay: 3, reviewsPerDay: 200,
                                     totalNewEnabled: false, totalNew: 5, totalReviewEnabled: false, totalReview: 300,
                                     overrides: [:], extra: nil)
        XCTAssertEqual(draft.preview.new, 6)
        draft.totalNewEnabled = true
        XCTAssertEqual(draft.preview.new, 5)
        draft.setLimit("甲", .new, 1)
        XCTAssertEqual(draft.preview.new, 4)
        XCTAssertEqual(draft.sumOfDeckLimits.new, 4)
        XCTAssertEqual(draft.deckPreview(overview.rows[0]).new, 1)
        let queue = try db.cardLearningSummary(scope: .all, now: now, calendar: calendar,
                                               limits: draft.settings).pending.new
        XCTAssertEqual(queue, 5, "草稿里的牌组单独设置未保存前不影响实际队列（甲 仍按默认 3 张，合计截到 5）")
    }

    // MARK: 学习会话

    func testStudyAllDecksMixesDecksAndStopsAtTotal() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            try seed(db, decks: ["甲": 3, "乙": 3], at: Date())
            CardSettings.totalNewPerDay = 4
            UserDefaults.standard.set(2, forKey: CardSettings.newPerDayKey)
            let store = LibraryStore(db: db)
            store.startStudyAllDecks()
            XCTAssertTrue(store.study.allDecks)
            XCTAssertEqual(store.currentCardLearningScope, .all)
            var decks: [String] = []
            while let card = store.study.current, decks.count < 10 {
                decks.append(card.deck)
                store.answerCurrent(.easy)
            }
            XCTAssertEqual(decks.count, 4, "合计 4 张后停止")
            XCTAssertEqual(decks.filter { $0 == "甲" }.count, 2, "每个牌组仍各自最多 2 张")
            XCTAssertTrue(store.study.finished)
            XCTAssertEqual(store.cardLearningSummary?.availability.kind, .dailyLimit)
            store.openCardsHome()
            XCTAssertFalse(store.study.allDecks)
        }
    }

    func testTodayExtraRaisesOnlyTheBlockingLevelAndResumesStudy() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            try seed(db, decks: ["甲": 5], at: Date())
            UserDefaults.standard.set(1, forKey: CardSettings.newPerDayKey)
            let store = LibraryStore(db: db)
            store.startStudy(deck: "甲")
            store.answerCurrent(.easy)
            XCTAssertNil(store.study.current)
            XCTAssertEqual(store.addTodayExtra(2, kind: .new), 2)
            let extra = try XCTUnwrap(CardSettings.todayExtra())
            XCTAssertEqual(extra.decks["甲"], DailyAmount(new: 2))
            XCTAssertEqual(extra.total, .zero)
            XCTAssertNotNil(store.study.current, "完成页加量后直接继续学习")

            // 再加全库合计后，合计挡住时只加合计
            store.clearTodayExtra()
            XCTAssertNil(CardSettings.todayExtra())
            UserDefaults.standard.set(10, forKey: CardSettings.newPerDayKey)
            CardSettings.totalNewPerDay = 1
            store.dailyLimitsChanged()
            XCTAssertEqual(store.addTodayExtra(1, kind: .new), 1)
            let second = try XCTUnwrap(CardSettings.todayExtra())
            XCTAssertTrue(second.decks.isEmpty)
            XCTAssertEqual(second.total, DailyAmount(new: 1))

            // 改名后加量跟着牌组走
            CardSettings.setTodayExtra(DailyLimitExtra(day: ReminderPlan.dayKey(Date()), decks: ["甲": DailyAmount(new: 3)]))
            store.renameDeck("甲", to: "甲甲")
            XCTAssertEqual(CardSettings.todayExtra()?.decks["甲甲"], DailyAmount(new: 3))
        }
    }

    func testTodayExtraExpiresNextDayAndTotalsPersistAsSettings() throws {
        let yesterday = Date().addingTimeInterval(-86_400)
        CardSettings.setTodayExtra(DailyLimitExtra(day: ReminderPlan.dayKey(yesterday), total: DailyAmount(new: 5)))
        XCTAssertNil(CardSettings.todayExtra(), "昨天的加量今天不再生效")
        XCTAssertNil(CardSettings.limits().extra)
        CardSettings.totalNewPerDay = 25
        CardSettings.totalReviewsPerDay = nil
        XCTAssertEqual(CardSettings.limits().totalNewPerDay, 25)
        XCTAssertNil(CardSettings.limits().totalReviewsPerDay)
        CardSettings.totalNewPerDay = nil
        XCTAssertEqual(CardSettings.lastTotal(.new), 25, "关闭后再打开沿用上次的数字")
    }

    func testBackupCarriesTotalsButNotTodayExtra() throws {
        let suite = "KongReview.V313.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CardSettings.totalNewEnabledKey)
        defaults.set(40, forKey: CardSettings.totalNewPerDayKey)
        defaults.set(false, forKey: CardSettings.totalReviewsEnabledKey)
        defaults.set(400, forKey: CardSettings.totalReviewsPerDayKey)
        defaults.set(Data("{}".utf8), forKey: CardSettings.todayExtraKey)
        let snapshot = try FullBackupService.settingsSnapshot(defaults)
        XCTAssertEqual(snapshot[CardSettings.totalNewEnabledKey] as? Bool, true)
        XCTAssertEqual(snapshot[CardSettings.totalNewPerDayKey] as? Int, 40)
        XCTAssertEqual(snapshot[CardSettings.totalReviewsPerDayKey] as? Int, 400)
        XCTAssertNil(snapshot[CardSettings.todayExtraKey], "临时加量只在当天有效，不进完整备份")
    }
}
