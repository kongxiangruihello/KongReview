import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.3.4：日课规则的七处修补——打卡按日课做完算、排在最前的三类至多占一半、新录先录先考、补考不过期、
/// 题数满了学习中的卡照旧回来、弃置的摘录不再出题
final class V634LessonRulesTests: XCTestCase {
    private let keys = [ReviewSessionRecord.key(theme: nil), ExamFresh.sessionKey, ExamFresh.perDayKey, SettingsKeys.dailyCount,
                        LibraryStore.examHandedInKey, ExamSettings.minutesKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private func c(_ done: Int, _ left: Int) -> DailyCheckCount { DailyCheckCount(done: done, left: left) }
    private func status(_ db: AppDatabase, _ n: Int) throws -> String? {
        let day = AppDatabase.revisitDay(t0, plus: n)
        return try db.writer.read { try String.fetchOne($0, sql: "SELECT status FROM daily_checkin WHERE day = ?", arguments: [day]) }
    }
    private func check(_ db: AppDatabase, _ current: [DailyCheckGroup: DailyCheckCount], handedIn: Bool = false, now: Date) throws {
        _ = try db.dailyCheck(current: current, groups: DailyCheckGroup.exam, rule: .lesson(handedIn: handedIn), now: now)
    }

    // MARK: 一、打卡

    func testCheckinNeedsWholeLesson() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 只标注完文章、题一道没做：不算
        try db.saveSelfScore(.three, note: "", now: d(0))
        try check(db, [.review: c(0, 10), .cards: c(0, 5), .revisit: c(0, 2), .annotate: c(5, 0)], now: d(0, hour: 1))
        XCTAssertNil(try status(db, 0), "只做完标注不算打卡")
        // 做完一组题、其余没做完：不算
        try check(db, [.review: c(10, 0), .cards: c(2, 3), .revisit: c(0, 2), .annotate: c(5, 0)], now: d(0, hour: 2))
        XCTAssertNil(try status(db, 0), "只做完一组题不算")
        // 三组题都做完：算（标注没做完也算）
        try check(db, [.review: c(10, 0), .cards: c(5, 0), .revisit: c(2, 0), .annotate: c(1, 4)], now: d(0, hour: 3))
        XCTAssertEqual(try status(db, 0), "checked")
    }

    func testCheckinByHandingIn() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.saveSelfScore(.four, note: "", now: d(0))
        // 一道没答就点收工：不算
        try check(db, [.review: c(0, 10), .cards: c(0, 5)], handedIn: true, now: d(0, hour: 1))
        XCTAssertNil(try status(db, 0), "一道没答，收工也不算")
        // 答了几道后收工：算
        try check(db, [.review: c(3, 7), .cards: c(0, 5)], handedIn: true, now: d(0, hour: 2))
        XCTAssertEqual(try status(db, 0), "checked")
        // 之后收起接着答，不撤销
        try check(db, [.review: c(3, 7), .cards: c(0, 5)], handedIn: false, now: d(0, hour: 3))
        XCTAssertEqual(try status(db, 0), "checked")
    }

    func testCheckinFallsBackWhenNoLessonDue() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 今天三组题都没有应做：标注做完也算
        try db.saveSelfScore(.three, note: "", now: d(0))
        try check(db, [.review: c(0, 0), .cards: c(0, 0), .revisit: c(0, 0), .annotate: c(0, 5)], now: d(0, hour: 1))
        XCTAssertNil(try status(db, 0))
        try check(db, [.review: c(0, 0), .cards: c(0, 0), .revisit: c(0, 0), .annotate: c(5, 0)], now: d(0, hour: 2))
        XCTAssertEqual(try status(db, 0), "checked", "没有题可做的日子，标注做完也算")
        // 跳过的组不拦着：摘录跳过，其余做完
        try db.saveSelfScore(.three, note: "", now: d(1))
        try check(db, [.review: c(0, 10), .cards: c(0, 3)], now: d(1, hour: 1))
        try db.setDailyCheckGroup(.review, skipped: true, now: d(1, hour: 1))
        try check(db, [.review: c(0, 10), .cards: c(3, 0)], now: d(1, hour: 2))
        XCTAssertEqual(try status(db, 1), "checked", "跳过的组不算进去")
    }

    func testOldPlanStillCountsOneGroup() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 旧接口（不传 rule）照 5.2.2 的算法：做完一组即可
        try db.saveSelfScore(.three, note: "", now: d(0))
        _ = try db.dailyCheck(current: [.review: c(10, 0), .cards: c(0, 5)], now: d(0, hour: 1))
        XCTAssertEqual(try status(db, 0), "checked")
    }

    // MARK: 二、三、四：名额、先录先考、补考不过期

    func testPriorityTakesAtMostHalf() throws {
        try MainActor.assumeIsolated {
            UserDefaults.standard.set(6, forKey: SettingsKeys.dailyCount)
            UserDefaults.standard.set(3, forKey: ExamFresh.perDayKey)
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "清代学术概论", author: "梁启超"))
            let old = Date().addingTimeInterval(-90 * 86_400)
            for i in 0..<12 { _ = try db.save(Highlight(sourceId: src.id, text: "旧摘录 \(i)", location: "第\(i)页", createdAt: old)) }
            var forgotten: [Int64] = []
            for i in 0..<3 {
                let h = try db.save(Highlight(sourceId: src.id, text: "忘了的 \(i)", location: "第\(20 + i)页", createdAt: old))
                // 最早那条是 50 天前忘的：过了 30 天仍然补考
                try db.recordExamResult(kind: .gist, recordId: h.id!, result: .forgot, now: Date().addingTimeInterval(-Double(50 - i * 20) * 86_400))
                forgotten.append(h.id!)
            }
            var fresh: [Int64] = []
            for i in 0..<4 {
                fresh.append(try db.save(Highlight(sourceId: src.id, text: "新录 \(i)", location: "第\(30 + i)页",
                                                   createdAt: Date().addingTimeInterval(-Double(5 - i) * 86_400))).id!)
            }
            let store = LibraryStore(db: db)
            let record = try store.todayReviewSession()
            XCTAssertEqual(record.regularIds.count, 6)
            XCTAssertEqual(Array(record.regularIds.prefix(3)), forgotten, "补考在前，最早忘的在前；三类合计只占一半（3 条）")
            XCTAssertTrue(Set(record.regularIds.dropFirst(3)).isDisjoint(with: Set(forgotten)))
            XCTAssertEqual(store.examRetestsToday(), 3)
            let backlog = store.examBacklog()
            XCTAssertEqual(backlog.retests, 3)
            XCTAssertEqual(backlog.fresh, 4, "新录的没排上，页头显示还在等的条数")
            XCTAssertEqual(try db.examFreshCandidates(now: Date(), limit: 10).map(\.id), fresh, "先录的在前")
        }
    }

    // MARK: 五、六

    func testDiscardedHighlightLeavesPaper() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注", author: "杨伯峻"))
            for i in 0..<4 { _ = try db.save(Highlight(sourceId: src.id, text: "第 \(i) 条摘录", location: "第\(i)页")) }
            let store = LibraryStore(db: db)
            let before = store.examPaper().highlights
            XCTAssertEqual(before.count, 4)
            var gone = before[1]
            gone.isDiscarded = true
            _ = try db.save(gone)
            XCTAssertFalse(store.examPaper().highlights.contains { $0.id == gone.id }, "在别处弃置了的不再出题")
            XCTAssertEqual(store.examPaper().highlights.count, 3)
        }
    }

    func testLearningCardsComeBackWhenCapReached() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            _ = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎"))
            _ = try db.save(Card(deck: "甲", front: "有朋自远方来", back: "不亦乐乎"))
            let store = LibraryStore(db: db)
            XCTAssertNil(store.examNextCard(learningOnly: true), "只有新卡时，题数满了就不再出")
            let first = try XCTUnwrap(store.examNextCard())
            XCTAssertFalse(LibraryStore.isLearning(first))
            store.examAnswerCard(first, .again)
            let again = try XCTUnwrap(try db.cards().first { $0.id == first.id })
            XCTAssertTrue(LibraryStore.isLearning(again), "答了重来，卡在学习中")
            if StudyQueue.isDue(again, now: Date()) {
                XCTAssertEqual(store.examNextCard(learningOnly: true)?.id, first.id, "学习中的卡照旧回来")
            }
        }
    }
}
