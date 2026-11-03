import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.0.1：复盘——步骤与进度、数字、想法、问题、观点的变化、提醒时间、首页指向哪一周
final class V501ReflectionTests: XCTestCase {
    /// 2026 年 10 月某周三上午 9 点（以本地日历计）
    private let wed: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func days(_ n: Int, from d: Date) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d)! }




    func testReminderFiresSkipCompletedWeek() throws {
        let cal = Calendar.current
        let fires = ReflectionReminderPlan.fires(now: wed, weekday: 1, hour: 20, minute: 0, count: 3) { _ in false }
        XCTAssertEqual(fires.count, 3)
        XCTAssertTrue(fires.allSatisfy { cal.component(.weekday, from: $0) == 1 && cal.component(.hour, from: $0) == 20 })
        XCTAssertTrue(fires[0] > wed)
        let firstWeek = ReflectionReminderPlan.targetWeek(for: fires[0])
        XCTAssertTrue(firstWeek.start <= days(-1, from: fires[0]) && days(-1, from: fires[0]) < firstWeek.fullEnd, "对应提醒前一天所在的周")
        let skipped = ReflectionReminderPlan.fires(now: wed, weekday: 1, hour: 20, minute: 0, count: 3) { $0.key == firstWeek.key }
        XCTAssertEqual(skipped.first, fires[1], "那一周已复盘就跳过")
    }


}
