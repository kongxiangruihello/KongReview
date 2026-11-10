import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.3.5：补签更显眼——补签后连续会接到几天、默认先补哪一天
@MainActor
final class V635MakeupTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 9   // 星期三
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private func key(_ n: Int) -> String { AppDatabase.revisitDay(t0, plus: n) }

    private func mark(_ db: AppDatabase, _ offsets: [Int]) throws {
        try db.writer.write { conn in
            for n in offsets {
                try conn.execute(sql: "INSERT INTO daily_checkin(day, status, selfScore, createdAt, updatedAt) VALUES (?, 'checked', 4, ?, ?)",
                                 arguments: [self.key(n), self.t0, self.t0])
            }
        }
    }

    /// 今天打了、昨天漏了（做过题没写日评）、再往前连打 24 天：补签昨天后连续 26 天
    func testMakeupBridgesStreak() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "甲"))
        try mark(db, Array(-25 ... -2) + [0])
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-1)))
        let s = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(s.current, 1)
        XCTAssertEqual(s.makeupDays, [key(-1)])
        XCTAssertEqual(s.makeupStreak[key(-1)], 26)
        XCTAssertEqual(MakeupCard.defaultDay(s), key(-1))
        // 补签后真的接上
        try db.makeUpCheckin(day: key(-1), score: .three, note: "", now: d(0, hour: 1))
        let after = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(after.current, 26)
        XCTAssertTrue(after.makeupDays.isEmpty)
        XCTAssertTrue(after.makeupStreak.isEmpty)
    }

    /// 今天还没打、昨天和前天都漏了：先补昨天才有用（补前天单独接不上），默认选昨天
    func testDefaultDayIsTheOneThatHelps() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "甲"))
        try mark(db, Array(-10 ... -3))
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-1)))
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-2)))
        let s = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(s.current, 0)
        XCTAssertEqual(Set(s.makeupDays), [key(-1), key(-2)])
        XCTAssertEqual(s.makeupStreak[key(-1)], 1)
        XCTAssertEqual(s.makeupStreak[key(-2)], 0)
        XCTAssertEqual(MakeupCard.defaultDay(s), key(-1))
        // 两天都补上：连续 10 天（-10 … -1）
        try db.makeUpCheckin(day: key(-1), score: .three, note: "", now: d(0, hour: 1))
        let mid = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(mid.makeupStreak[key(-2)], 10)
        try db.makeUpCheckin(day: key(-2), score: .three, note: "", now: d(0, hour: 1))
        XCTAssertEqual(try db.checkinSummary(now: d(0, hour: 1)).current, 10)
    }

    /// 从没打过卡也能补：补后连续 1 天
    func testMakeupWithNoCheckinsYet() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "甲"))
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: d(-1)))
        let s = try db.checkinSummary(now: d(0, hour: 1))
        XCTAssertEqual(s.makeupDays, [key(-1)])
        XCTAssertEqual(s.makeupStreak[key(-1)], 1)
    }

    /// 连续天数的算法与 5.2.2 一致：休息日没打跳过
    func testCurrentStreakSkipsRestDays() {
        let checked: Set<String> = [key(0), key(-1), key(-3)]
        let rest: (String) -> Bool = { $0 == self.key(-2) }
        XCTAssertEqual(AppDatabase.currentStreak(checked: checked, todayChecked: true, now: d(0), rest: rest), 3)
        XCTAssertEqual(AppDatabase.currentStreak(checked: checked, todayChecked: true, now: d(0), rest: { _ in false }), 2)
        XCTAssertEqual(AppDatabase.currentStreak(checked: [], todayChecked: false, now: d(0), rest: { _ in false }), 0)
    }
}
