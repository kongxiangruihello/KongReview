import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.5：成绩册——各类掌握度、走势、常错的题、每日成绩、周报月报与一句话、考场门口的上次成绩
final class V605GradebookTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 3; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour - 10, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }

    /// 一本笔记本里一段够长的文字
    private func block(_ db: AppDatabase) throws -> (Int64, Int64) {
        let nb = try db.createNotebook(title: "清代学术", now: d(-30))
        let blocks = try db.insertBlocks([
            NotebookBlock(notebookId: nb.id!, position: 1, kind: .text,
                          text: "乾嘉学者并非一概反对理学，戴震以考据为手段，旨在重建义理，其《孟子字义疏证》即是明证。"),
        ], into: nb.id!, after: nil, now: d(-30))
        return (nb.id!, blocks[0].id!)
    }

    func testMasteryByKind() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎", due: d(-1)))
        // 同一天先重来、再良好：只算第一次（差）；第二天良好（好）
        var c = try db.answer(card, .again, now: d(0, hour: 9))
        c = try db.answer(c, .good, now: d(0, hour: 9).addingTimeInterval(600))
        _ = try db.answer(c, .good, now: d(1, hour: 9))
        let src = try db.save(Source(title: "论语译注"))
        let h = try db.save(Highlight(sourceId: src.id, text: "温故而知新", location: "为政第二"))
        try db.recordExamResult(kind: .gist, recordId: h.id!, result: .partly, now: d(0))
        let note = try db.createIdeaNote(title: "士以道自任", body: "<p>依据</p>", now: d(-30))
        try db.recordExamResult(kind: .argument, recordId: note.id!, result: .remembered, now: d(0))
        let (_, b) = try block(db)
        try db.recordBlockRevisit(blockId: b, outcome: .reread, now: d(0))

        let m = try db.writer.read { try AppDatabase.masteryByKind($0, start: d(0, hour: 0), end: d(2, hour: 0)) }
        XCTAssertEqual(m[.card], MasteryTally(good: 1, mid: 0, bad: 1), "每张每天取第一次评分")
        XCTAssertEqual(m[.highlight], MasteryTally(good: 0, mid: 1, bad: 0))
        XCTAssertEqual(m[.note], MasteryTally(good: 1, mid: 0, bad: 0))
        XCTAssertEqual(m[.block], MasteryTally(good: 0, mid: 0, bad: 1), "需重读算差")

        let trend = try db.masteryTrend(weeks: 12, now: d(1, hour: 20))
        XCTAssertEqual(trend.count, 12)
        XCTAssertEqual(trend.last?.all.total, 5, "本周五次作答都在最后一周")
        XCTAssertTrue(trend.dropLast(2).allSatisfy { $0.all.total == 0 })
        XCTAssertNil(trend.last?.tallies[.card]?.ratio, "一类不满 5 次不算比例")
    }

    func testWeakItems() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "论语译注"))
        let twice = try db.save(Highlight(sourceId: src.id, text: "学而不思则罔，思而不学则殆", location: "为政第二"))
        let lastForgot = try db.save(Highlight(sourceId: src.id, text: "三人行，必有我师焉"))
        let recovered = try db.save(Highlight(sourceId: src.id, text: "君子不器"))
        let deleted = try db.save(Highlight(sourceId: src.id, text: "已删去的一条"))
        try db.recordExamResult(kind: .gist, recordId: twice.id!, result: .forgot, now: d(-10))
        try db.recordExamResult(kind: .source, recordId: twice.id!, result: .forgot, now: d(-5))
        try db.recordExamResult(kind: .gist, recordId: twice.id!, result: .remembered, now: d(-1))
        try db.recordExamResult(kind: .gist, recordId: lastForgot.id!, result: .forgot, now: d(-2))
        try db.recordExamResult(kind: .gist, recordId: recovered.id!, result: .forgot, now: d(-6))
        try db.recordExamResult(kind: .gist, recordId: recovered.id!, result: .remembered, now: d(-1))
        try db.recordExamResult(kind: .gist, recordId: deleted.id!, result: .forgot, now: d(-3))
        try db.recordExamResult(kind: .gist, recordId: deleted.id!, result: .forgot, now: d(-2))
        try db.moveToTrash(deleted, now: d(-1))
        // 很久以前错的不算
        let old = try db.save(Highlight(sourceId: src.id, text: "很久以前错的"))
        try db.recordExamResult(kind: .gist, recordId: old.id!, result: .forgot, now: d(-200))

        var card = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎", due: d(-20)))
        card = try db.answer(card, .again, now: d(-8))
        card = try db.answer(card, .again, now: d(-4))
        card = try db.answer(card, .good, now: d(-1))
        var easy = try db.save(Card(deck: "甲", front: "温故而知新", back: "可以为师矣", due: d(-20)))
        easy = try db.answer(easy, .again, now: d(-3))
        let (nb, b) = try block(db)
        try db.recordBlockRevisit(blockId: b, outcome: .reread, now: d(-9))
        try db.recordBlockRevisit(blockId: b, outcome: .reread, now: d(-6))

        let weak = try db.weakItems(now: t0)
        let highlights = weak[.highlight] ?? []
        XCTAssertEqual(highlights.map(\.recordId), [twice.id!, lastForgot.id!], "错两次的在前；最近一次错的也列；答对了又只错过一次的不列；删去的不列")
        XCTAssertEqual(highlights.first?.misses, 2)
        XCTAssertEqual(highlights.first?.attempts, 3)
        XCTAssertEqual(highlights.first?.lastMissed, false)
        XCTAssertEqual(highlights.first?.detail, "《论语译注》 为政第二")
        XCTAssertEqual(highlights.last?.lastMissed, true)
        XCTAssertEqual(weak[.card]?.map(\.recordId), [card.id!], "重来两次以上")
        XCTAssertEqual(weak[.card]?.first?.detail, "甲")
        XCTAssertEqual(weak[.block]?.first?.recordId, b)
        XCTAssertEqual(weak[.block]?.first?.notebookId, nb)
        XCTAssertEqual(weak[.block]?.first?.detail, "《清代学术》")
        XCTAssertTrue((weak[.note] ?? []).isEmpty)
    }

    func testMonthReportRemarkAndLastScore() throws {
        let db = try AppDatabase(DatabaseQueue())
        let c = { (done: Int, left: Int) in DailyCheckCount(done: done, left: left) }
        // 前天：做完 4 / 4，写了日评（打卡）
        _ = try db.dailyCheck(current: [.review: c(4, 0)], groups: [.review], now: d(-2))
        try db.saveSelfScore(.four, note: "读完了学而篇", now: d(-2, hour: 21))
        // 昨天：只做了 1 / 5，没写日评
        _ = try db.dailyCheck(current: [.review: c(1, 4)], groups: [.review], now: d(-1))
        _ = try db.save(Highlight(text: "这一期新录的摘录", createdAt: d(-1)))

        let month = try db.gradebookMonth(containing: t0, now: t0)
        XCTAssertEqual(month.first?.day, AppDatabase.revisitDay(t0), "新的在前，到今天为止")
        XCTAssertTrue(month.first?.isToday == true)
        XCTAssertEqual(month.count, 3, "11 月 1 日到 3 日")
        let before = try XCTUnwrap(month.first { $0.day == AppDatabase.revisitDay(d(-2)) })
        XCTAssertEqual(before.done, 4); XCTAssertEqual(before.due, 4)
        XCTAssertEqual(before.checkin, .checked)
        XCTAssertEqual(before.score.note, "读完了学而篇")
        XCTAssertEqual(before.score.selfScore, .four)
        XCTAssertNotNil(before.score.total)
        let yesterday = try XCTUnwrap(month.first { $0.day == AppDatabase.revisitDay(d(-1)) })
        XCTAssertNil(yesterday.checkin)
        XCTAssertFalse(yesterday.isEmpty)

        let window = GrowthPeriod.month.window(containing: t0, now: t0)
        let r = try db.gradebookReport(window, now: t0)
        XCTAssertEqual(r.days, 3)
        XCTAssertEqual(r.checkinDays, 1)
        XCTAssertEqual(r.done, 5); XCTAssertEqual(r.due, 9)
        XCTAssertEqual(r.activeDays, 2)
        XCTAssertEqual(r.newHighlights, 1)
        XCTAssertEqual(r.scoredDays, 1)
        XCTAssertEqual(r.bestDay, AppDatabase.revisitDay(d(-2)))
        XCTAssertEqual(r.averageTotal, before.score.total)

        XCTAssertEqual(try db.gradebookRemark(window.key), "")
        try db.saveGradebookRemark("  这个月把学而篇读熟了  ", periodKey: window.key)
        XCTAssertEqual(try db.gradebookRemark(window.key), "这个月把学而篇读熟了")
        try db.saveGradebookRemark("   ", periodKey: window.key)
        XCTAssertEqual(try db.gradebookRemark(window.key), "", "写空即删去")

        let last = try XCTUnwrap(try db.lastGradedDay(now: t0))
        XCTAssertEqual(last.day, AppDatabase.revisitDay(d(-1)), "上次成绩取今天以前最近一个有记录的日子")
        XCTAssertEqual(last.done, 1)
        XCTAssertNil(try db.lastGradedDay(now: d(40)), "30 天内没有记录就不显示")
    }

    func testStoreNavigation() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let note = try db.createIdeaNote(title: "士以道自任", body: "<p>依据</p>")
            let store = LibraryStore(db: db)
            store.openGradebook(period: .month)
            XCTAssertEqual(store.selection, .gradebook)
            XCTAssertEqual(store.reflectionPeriod, .month)
            store.openGradebook(period: .day)
            XCTAssertEqual(store.reflectionPeriod, .month, "没有日报")
            store.openWeakItem(WeakItem(kind: .note, recordId: note.id!, title: note.title, detail: "札记",
                                        misses: 2, attempts: 2, lastAt: Date(), lastMissed: true))
            XCTAssertEqual(store.selection, .ideaNote(note.id!))
            let window = GrowthPeriod.week.window(containing: Date())
            var calls = 0
            store.onReflectionChanged = { calls += 1 }
            store.saveGradebookRemark("这周补了三次考", window: window)
            XCTAssertEqual(try db.gradebookRemark(window.key), "这周补了三次考")
            XCTAssertEqual(calls, 1)
        }
    }
}
