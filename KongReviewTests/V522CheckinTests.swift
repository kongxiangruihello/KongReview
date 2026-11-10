import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.2.2：打卡条件、连续与最长、休息日、补签、中断原因、旧记录迁移；粘贴不弹窗
final class V522CheckinTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 9   // 星期三
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private func key(_ n: Int) -> String { AppDatabase.revisitDay(t0, plus: n) }
    private func c(_ done: Int, _ left: Int) -> DailyCheckCount { DailyCheckCount(done: done, left: left) }

    /// 直接记下某天打卡（测试连续天数用）
    private func mark(_ db: AppDatabase, _ offsets: [Int], status: String = "checked", score: Int? = 4) throws {
        try db.writer.write { conn in
            for n in offsets {
                try conn.execute(sql: "INSERT INTO daily_checkin(day, status, selfScore, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)",
                                 arguments: [self.key(n), status, score, self.t0, self.t0])
            }
        }
    }

    private func status(_ db: AppDatabase, _ n: Int) throws -> String? {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT status FROM daily_checkin WHERE day = ?", arguments: [self.key(n)]) }
    }

    func testCheckinNeedsOneGroupDoneAndSelfScore() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 先做完一组，再写日评
        _ = try db.dailyCheck(current: [.review: c(0, 10), .revisit: c(0, 2)], now: d(0))
        _ = try db.dailyCheck(current: [.review: c(4, 6), .revisit: c(2, 0)], now: d(0, hour: 1))
        XCTAssertNil(try status(db, 0), "只做完一组、没写日评不算")
        try db.saveSelfScore(.three, note: "", now: d(0, hour: 2))
        XCTAssertEqual(try status(db, 0), "checked")
        // 反过来：先写日评，后做完一组
        try db.saveSelfScore(.four, note: "", now: d(1))
        _ = try db.dailyCheck(current: [.review: c(3, 7)], now: d(1, hour: 1))
        XCTAssertNil(try status(db, 1), "写了日评、一组也没做完不算")
        _ = try db.dailyCheck(current: [.review: c(10, 0)], now: d(1, hour: 2))
        XCTAssertEqual(try status(db, 1), "checked")
        // 跳过的组做完不算；应做为 0 的组做了 1 条也算
        _ = try db.dailyCheck(current: [.review: c(0, 5), .cards: c(0, 3)], now: d(2))
        try db.setDailyCheckGroup(.cards, skipped: true, now: d(2))
        try db.saveSelfScore(.two, note: "", now: d(2))
        _ = try db.dailyCheck(current: [.review: c(1, 4), .cards: c(3, 0)], now: d(2, hour: 1))
        XCTAssertNil(try status(db, 2), "跳过的组不算")
        _ = try db.dailyCheck(current: [.review: c(1, 4), .cards: c(3, 0), .selfTest: c(1, 0)], now: d(2, hour: 2))
        XCTAssertEqual(try status(db, 2), "checked", "应做为 0 的自测做了 1 题")
        // 打卡后不撤销
        _ = try db.dailyCheck(current: [.review: c(0, 9)], now: d(2, hour: 3))
        XCTAssertEqual(try status(db, 2), "checked")
    }

    func testStreakCounts() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 前天、昨天打了，今天还没：连续 2（从昨天数）
        try mark(db, [-6, -5, -4, -2, -1])
        var s = try db.checkinSummary(now: d(0, hour: 5))
        XCTAssertEqual(s.current, 2)
        XCTAssertFalse(s.todayChecked)
        XCTAssertEqual(s.longest, 3, "-6…-4 三天")
        XCTAssertEqual(s.total, 5)
        XCTAssertNil(s.brokenOn, "连续没断")
        try mark(db, [0])
        s = try db.checkinSummary(now: d(0, hour: 6))
        XCTAssertEqual(s.current, 3)
        XCTAssertEqual(s.longest, 3)
        XCTAssertTrue(s.todayChecked)
        XCTAssertEqual(s.month, 6, "11 月的 6 天")
        XCTAssertEqual(s.year, 6)
        // 两天后再看：昨天、前天都没打 → 连续 0，断在第 1 天
        s = try db.checkinSummary(now: d(3))
        XCTAssertEqual(s.current, 0)
        XCTAssertEqual(s.brokenOn, key(1))
        try db.recordStreakBreak(day: key(1), reason: .travel, now: d(3))
        XCTAssertNil(try db.checkinSummary(now: d(3)).brokenOn, "记了原因就不再问")
        let w = GrowthPeriod.month.window(containing: d(3), now: d(3))
        XCTAssertEqual(try db.streakBreaks(start: w.start, end: w.fullEnd), [.travel: 1])
        XCTAssertEqual(try db.checkinDays(start: w.start, end: w.fullEnd), 6)
        // 断了超过 7 天不再问
        XCTAssertNil(try db.checkinSummary(now: d(12)).brokenOn)
    }

    func testRestDays() throws {
        let db = try AppDatabase(DatabaseQueue())
        let wd = Calendar.current.component(.weekday, from: d(-1))   // 昨天是星期几
        try mark(db, [-3, -2, 0])
        XCTAssertEqual(try db.checkinSummary(now: d(0, hour: 1)).current, 1, "昨天没打，连续从今天重新算")
        // 从三天前起把昨天那个星期几设为休息日：昨天不断
        try db.setRestWeekday(wd, now: d(-3))
        var s = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(s.current, 3, "休息日跳过不断，也不计入")
        XCTAssertEqual(s.restWeekday, wd)
        XCTAssertTrue(AppDatabase.isRestDay(key(-1), changes: try db.restDayChanges()))
        // 今天改为不设：过去按当时的设定算，连续不变
        try db.setRestWeekday(nil, now: d(0, hour: 2))
        s = try db.checkinSummary(now: d(0, hour: 3))
        XCTAssertEqual(s.current, 3)
        XCTAssertNil(s.restWeekday)
        XCTAssertEqual(try db.restDayChanges().count, 2)
        // 同一天改多次只留最后一次
        try db.setRestWeekday(2, now: d(0, hour: 4))
        XCTAssertEqual(try db.restDayChanges().map(\.weekday), [wd, 2])
    }

    func testMakeup() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "甲"))
        // 前天学过、没写日评；大前天什么都没做；五天前学过但超出 3 天
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-2)))
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-5)))
        var s = try db.checkinSummary(now: d(0))
        XCTAssertEqual(s.makeupDays, [key(-2)])
        XCTAssertEqual(s.makeupLeft, 2)
        XCTAssertThrowsError(try db.makeUpCheckin(day: key(-3), score: .three, note: "", now: d(0)), "没有检查记录")
        XCTAssertThrowsError(try db.makeUpCheckin(day: key(-5), score: .three, note: "", now: d(0)), "超出 3 天")
        XCTAssertThrowsError(try db.makeUpCheckin(day: key(0), score: .three, note: "", now: d(0)), "今天不用补签")
        try db.makeUpCheckin(day: key(-2), score: .four, note: " 补一句 ", now: d(0))
        XCTAssertEqual(try status(db, -2), "makeup")
        let sc = try db.dailyScore(day: key(-2), now: d(0))
        XCTAssertEqual(sc.selfScore, .four)
        XCTAssertEqual(sc.note, "补一句")
        XCTAssertThrowsError(try db.makeUpCheckin(day: key(-2), score: .five, note: "", now: d(0)), "已经打过卡")
        s = try db.checkinSummary(now: d(0))
        XCTAssertEqual(s.makeupLeft, 1)
        XCTAssertEqual(s.days[key(-2)]?.status, .makeup)
        XCTAssertTrue(s.makeupDays.isEmpty)
        // 每月 2 次
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-1)))
        try db.makeUpCheckin(day: key(-1), score: .three, note: "", now: d(0))
        db.log(ReviewEvent(kind: .card, cardId: 1, answer: 3, at: d(1)))
        XCTAssertEqual(try db.checkinSummary(now: d(2)).makeupLeft, 0)
        XCTAssertTrue(try db.checkinSummary(now: d(2)).makeupDays.isEmpty)
        XCTAssertThrowsError(try db.makeUpCheckin(day: key(1), score: .three, note: "", now: d(2)), "本月用完")
        XCTAssertEqual(try db.checkinSummary(now: d(0, hour: 1)).current, 2, "补签也算连续：-2、-1")
    }

    func testLegacyMigration() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "甲"))
        for n in [-4, -3, -2, -1] { db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(n))) }
        db.log(ReviewEvent(kind: .note, highlightId: h.id, at: d(-6)))      // 只写按语不算
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(0)))       // 升级当天不算
        try mark(db, [-3], status: "checked", score: 5)                      // 已打卡的不改
        try db.writer.write { try AppDatabase.installCheckinLegacy(in: $0, now: d(0, hour: 1)) }
        XCTAssertEqual(try status(db, -4), "legacy")
        XCTAssertEqual(try status(db, -3), "checked")
        XCTAssertEqual(try status(db, -1), "legacy")
        XCTAssertNil(try status(db, -6))
        XCTAssertNil(try status(db, 0))
        let s = try db.checkinSummary(now: d(0, hour: 2))
        XCTAssertEqual(s.current, 4, "升级前的连续天数保留")
        XCTAssertEqual(s.days[key(-4)]?.selfScore, nil)
        XCTAssertEqual(s.days[key(-3)]?.selfScore, 5)
    }

    func testStoreCheckinFlow() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            var changed = 0
            store.onCheckinChanged = { changed += 1 }
            XCTAssertFalse(store.checkin.todayChecked)
            // 今天没有任何应做：做了 1 条回顾也算（6.3.4：应用里按日课做完算）
            _ = try db.dailyCheck(current: [.review: DailyCheckCount(done: 1, left: 0)], groups: DailyCheckGroup.exam, rule: .lesson(handedIn: false))
            store.saveSelfScore(.four, note: "")
            XCTAssertTrue(store.checkin.todayChecked)
            XCTAssertEqual(store.checkin.current, 1)
            XCTAssertEqual(changed, 1, "打卡后通知提醒模块")
            store.setRestWeekday(3)
            XCTAssertEqual(store.checkin.restWeekday, 3)
        }
    }

    func testPasteKeepsFormatWithoutChooser() throws {
        try MainActor.assumeIsolated {
            UserDefaults.standard.removeObject(forKey: EditorPasteStyle.askKey)
            XCTAssertFalse(EditorPasteStyle.asksEveryTime, "默认不弹出选择界面")
            let handle = RichEditorHandle()
            let view = HTMLSourceTextView(frame: .zero)
            view.isEditable = true
            view.string = "<p>甲</p>"
            handle.textView = view
            let before = handle.attributionPulse
            handle.receivePaste(html: "<p><b>乙</b></p>", plain: "乙", original: view.string,
                                selection: NSRange(location: (view.string as NSString).length, length: 0), source: true)
            XCTAssertNil(handle.pasteProposal, "直接粘贴，不弹窗")
            XCTAssertEqual(view.string, "<p>甲</p><p><b>乙</b></p>", "保留原格式")
            XCTAssertEqual(handle.attributionPulse, before + 1, "照常识别末尾出处")
            // 打开设置后照旧先弹出选择界面
            UserDefaults.standard.set(true, forKey: EditorPasteStyle.askKey)
            defer { UserDefaults.standard.removeObject(forKey: EditorPasteStyle.askKey) }
            handle.receivePaste(html: "<p>丙</p>", plain: "丙", original: view.string, selection: NSRange(location: 0, length: 0), source: true)
            XCTAssertNotNil(handle.pasteProposal)
            // 编辑区已不在（直接粘贴失败）时退回选择界面
            UserDefaults.standard.removeObject(forKey: EditorPasteStyle.askKey)
            handle.pasteProposal = nil
            handle.textView = nil
            handle.receivePaste(html: "<p>丁</p>", plain: "丁", original: "x", source: true)
            XCTAssertNotNil(handle.pasteProposal, "粘贴不成时不丢内容")
        }
    }
}
