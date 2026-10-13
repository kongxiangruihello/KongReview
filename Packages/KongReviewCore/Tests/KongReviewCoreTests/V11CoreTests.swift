import XCTest
@testable import KongReviewCore

final class V11CoreTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testLoadPutsOverdueOnToday() {
        let now = date("2026-10-13 20:00")
        let dues = [date("2026-10-01 08:00"), date("2026-10-13 23:00"), date("2026-10-14 01:00"),
                    date("2026-10-20 09:00"), date("2026-12-01 09:00")]
        let l = CardForecast.load(dues: dues, now: now, days: 30, calendar: cal)
        XCTAssertEqual(l.days.count, 30)
        XCTAssertEqual(l.overdue, 1)
        XCTAssertEqual(l.days[0].count, 2)
        XCTAssertEqual(l.days[1].count, 1)
        XCTAssertEqual(l.days[7].count, 1)
        XCTAssertEqual(l.total, 4, "30 天以外的不计")
        XCTAssertEqual(l.peak?.count, 2)
        XCTAssertEqual(l.average(first: 2), 1.5)
    }

    func testRetentionCountsOnlyLaterDayReviews() {
        let now = date("2026-10-13 20:00")
        let a: [CardForecast.Answer] = [
            .init(cardId: 1, answer: 1, at: date("2026-10-01 09:00")),   // 新卡第一次：不算
            .init(cardId: 1, answer: 3, at: date("2026-10-01 09:05")),   // 同一天的学习步：不算
            .init(cardId: 1, answer: 3, at: date("2026-10-03 09:00")),   // 隔天复习：记住
            .init(cardId: 1, answer: 1, at: date("2026-10-10 09:00")),   // 忘记
            .init(cardId: 1, answer: 3, at: date("2026-10-10 09:10")),   // 重学步：不算
            .init(cardId: 2, answer: 3, at: date("2026-10-12 09:00")),
            .init(cardId: 2, answer: 4, at: date("2026-10-13 09:00")),   // 记住
        ]
        let r = CardForecast.retention(a, now: now, weeks: 4, calendar: cal)
        XCTAssertEqual(r.last30Reviews, 3)
        XCTAssertEqual(r.last30Passed, 2)
        XCTAssertEqual(r.weeks.count, 4)
        XCTAssertEqual(r.weeks.last?.reviews, 1, "本周（10-12 周一起）只有 10-13 一次")
        XCTAssertEqual(r.weeks.map(\.reviews).reduce(0, +), 3)
        XCTAssertEqual(cal.component(.weekday, from: r.weeks.last!.start), 2)
    }

    func testTagRenameMergesAndMovesChildren() {
        XCTAssertEqual(TagOps.rename(["儒家", "儒家/孟子", "严复"], from: "儒家", to: "先秦儒家"),
                       ["先秦儒家", "先秦儒家/孟子", "严复"])
        XCTAssertEqual(TagOps.rename(["论语", "論語"], from: "論語", to: "论语"), ["论语"], "合并后去重")
        XCTAssertEqual(TagOps.rename(["a/b"], from: "a", to: ""), ["b"], "删去父层，子标签升一级")
        XCTAssertEqual(TagOps.remove(["儒家", "儒家/孟子", "儒家学派"], tag: "儒家"), ["儒家学派"])
        XCTAssertEqual(TagOps.normalize(" #儒家 ／ 孟子 /"), "儒家/孟子")
        XCTAssertTrue(TagOps.isWithin("儒家/孟子", "儒家"))
        XCTAssertFalse(TagOps.isWithin("儒家学派", "儒家"))
    }

    func testTagTree() {
        let t = TagNode.tree(["儒家/孟子": 3, "儒家": 2, "儒家/荀子": 1, "严复": 4, "近代/思想/梁启超": 1])
        XCTAssertEqual(t.map(\.name).count, 3)
        let ru = t.first { $0.name == "儒家" }!
        XCTAssertEqual(ru.count, 6)
        XCTAssertEqual(ru.ownCount, 2)
        XCTAssertEqual(ru.children.map(\.path).sorted(), ["儒家/孟子", "儒家/荀子"])
        let jin = t.first { $0.name == "近代" }!
        XCTAssertEqual(jin.ownCount, 0)
        XCTAssertEqual(jin.children.first?.children.first?.path, "近代/思想/梁启超")
        XCTAssertNil(t.first { $0.name == "严复" }!.childrenOrNil)
    }
}
