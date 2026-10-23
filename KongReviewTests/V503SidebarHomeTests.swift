import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.0.3：侧栏四组的默认折叠、首页“常念的问题”“去年今日”
final class V503SidebarHomeTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    func testSidebarV5DefaultsCollapseResearchOnce() {
        let first = SidebarLayout.applyV5Defaults(collapsed: ["materials"], applied: false)
        XCTAssertEqual(first.collapsed, ["materials", "research"], "第一次：研究与写作折叠")
        XCTAssertTrue(first.applied)
        let later = SidebarLayout.applyV5Defaults(collapsed: [], applied: true)
        XCTAssertEqual(later.collapsed, [], "之后按自己的折叠状态")
        XCTAssertEqual(SidebarLayout.groups, ["review", "thinking", "materials", "research"])
    }

    func testOnThisDaySameDayPreviousYearsNewestFirst() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = date(2026, 10, 23, 15)
        _ = try db.save(Highlight(text: "两年前的摘录", createdAt: date(2024, 10, 23, 9)))
        _ = try db.createIdeaNote(title: "去年的札记", now: date(2025, 10, 23, 21))
        _ = try db.createQuestion(title: "去年的问题", now: date(2025, 10, 23, 8))
        _ = try db.save(Highlight(text: "今年今天的不算", createdAt: date(2026, 10, 23, 8)))
        _ = try db.save(Highlight(text: "去年前一天的不算", createdAt: date(2025, 10, 22, 23)))
        let gone = try db.save(Highlight(text: "已删除的不算", createdAt: date(2025, 10, 23, 9)))
        try db.writer.write { try $0.execute(sql: "UPDATE highlight SET deletedAt = ? WHERE id = ?", arguments: [Date(), gone.id!]) }
        let items = try db.onThisDay(now: now)
        XCTAssertEqual(items.map(\.text), ["去年的札记", "去年的问题", "两年前的摘录"], "新的在前；同年札记、问题在摘录前")
        XCTAssertEqual(items.map(\.yearsAgo), [1, 1, 2])
        XCTAssertTrue(try db.onThisDay(now: date(2026, 10, 24)).isEmpty)
    }

    func testOnThisDayLeapDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.createIdeaNote(title: "闰日写的", now: date(2024, 2, 29))
        _ = try db.createIdeaNote(title: "二月廿八写的", now: date(2025, 2, 28))
        XCTAssertEqual(Set(try db.onThisDay(now: date(2026, 2, 28)).map(\.text)), ["闰日写的", "二月廿八写的"], "平年 2 月 28 日一并列出 2 月 29 日")
        XCTAssertEqual(try db.onThisDay(now: date(2028, 2, 29)).map(\.text), ["闰日写的"])
        XCTAssertEqual(try db.onThisDay(now: date(2028, 2, 28)).map(\.text), ["二月廿八写的"], "闰年的 2 月 28 日不列 2 月 29 日")
    }

    func testPinnedQuestionsTopThree() throws {
        let db = try AppDatabase(DatabaseQueue())
        var ids: [Int64] = []
        for i in 0..<5 {
            let q = try db.createQuestion(title: "常念\(i)", now: date(2026, 10, 1 + i))
            try db.setQuestionPinned(id: q.id!, true)
            ids.append(q.id!)
        }
        let shelved = try db.createQuestion(title: "搁置的常念", now: date(2026, 10, 20))
        try db.setQuestionPinned(id: shelved.id!, true)
        try db.setQuestionStatus(id: shelved.id!, .shelved, now: date(2026, 10, 21))
        _ = try db.createQuestion(title: "不常念", now: date(2026, 10, 22))
        let r = try db.pinnedQuestions()
        XCTAssertEqual(r.total, 5, "常念且未解决的")
        XCTAssertEqual(r.items.map(\.id), [ids[4], ids[3], ids[2]], "最近改过的前三个")
    }
}
