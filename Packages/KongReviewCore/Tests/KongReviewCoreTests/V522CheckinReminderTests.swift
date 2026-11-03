import XCTest
@testable import KongReviewCore

/// 5.2.2：晚间打卡提醒的排程
final class V522CheckinReminderTests: XCTestCase {
    private let cal = Calendar.current
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4 + day; c.hour = hour; c.minute = minute
        return cal.date(from: c)!
    }

    func testFires() {
        var f = CheckinReminderPlan.fires(now: at(9), hour: 21, minute: 0, checkedToday: false)
        XCTAssertEqual(f.count, 7)
        XCTAssertEqual(f.first, at(21), "还没打卡：今晚提醒")
        f = CheckinReminderPlan.fires(now: at(9), hour: 21, minute: 0, checkedToday: true)
        XCTAssertEqual(f.first, at(21, day: 1), "已打卡：从明晚起")
        XCTAssertEqual(f.count, 6)
        f = CheckinReminderPlan.fires(now: at(21, 30), hour: 21, minute: 0, checkedToday: false)
        XCTAssertEqual(f.first, at(21, day: 1), "时间已过：从明晚起")
        XCTAssertEqual(CheckinReminderPlan.identifier(for: at(21)), "kongreview.checkin.2026-11-04")
    }
}
