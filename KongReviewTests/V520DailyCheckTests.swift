import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.2.0：笔记重温、今日检查（应做数快照、跳过整组）、每天带几道自测题
final class V520DailyCheckTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private let lim = RevisitLimits(notes: 2, questions: 1, books: 1, blocks: 2)
    private let long = "乾嘉学者并非一概反对理学，戴震以考据为手段，旨在重建义理，其《孟子字义疏证》即是明证。"

    /// 一本笔记本：小标题、一段够长的文字、一段太短的文字
    private func notebook(_ db: AppDatabase, at: Date) throws -> (nb: Int64, text: Int64, short: Int64) {
        let nb = try db.createNotebook(title: "清代学术", now: at)
        let blocks = try db.insertBlocks([
            NotebookBlock(notebookId: nb.id!, position: 1, kind: .heading, text: "第一节 考据与义理"),
            NotebookBlock(notebookId: nb.id!, position: 2, kind: .text, text: long),
            NotebookBlock(notebookId: nb.id!, position: 3, kind: .text, text: "太短"),
        ], into: nb.id!, after: nil, now: at)
        return (nb.id!, blocks[1].id!, blocks[2].id!)
    }

    func testBlockScheduleOutcomesAndOrganize() throws {
        let db = try AppDatabase(DatabaseQueue())
        let (_, text, short) = try notebook(db, at: t0)
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(6)).blocks.isEmpty, "新写的段落 7 天后才来")
        let first = try XCTUnwrap(try db.revisitQueue(limits: lim, now: d(7)).blocks.first)
        XCTAssertEqual(first.id, text, "太短的段落不排重温")
        XCTAssertEqual(first.notebookTitle, "清代学术")
        XCTAssertEqual(first.heading, "第一节 考据与义理", "提示用这一段之前最近的小标题")
        XCTAssertTrue(first.opening.hasSuffix("……"))
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notebook_block_review WHERE blockId = ?", arguments: [short]) }, 0)

        // 已吸收：7 → 21
        try db.recordBlockRevisit(blockId: text, outcome: .absorbed, now: d(7))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(27)).blocks.isEmpty)
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(28)).blocks.first?.intervalDays, 21)
        // 需重读：3 天后再来，间隔从头算
        try db.recordBlockRevisit(blockId: text, outcome: .reread, now: d(28))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(30)).blocks.isEmpty)
        var item = try XCTUnwrap(try db.revisitQueue(limits: lim, now: d(31)).blocks.first)
        XCTAssertEqual(item.intervalDays, 7)
        XCTAssertEqual(item.reviewCount, 2)
        // 待整理：一周后再来，列入待整理；改过文字就移除
        try db.recordBlockRevisit(blockId: text, outcome: .organize, now: d(31))
        XCTAssertEqual(try db.blocksToOrganize().map(\.id), [text])
        XCTAssertEqual(try db.blocksToOrganize().first?.heading, "第一节 考据与义理")
        item = try XCTUnwrap(try db.revisitQueue(limits: lim, now: d(38)).blocks.first)
        XCTAssertEqual(item.intervalDays, 7, "待整理不改间隔")
        try db.updateBlockText(text, text: long, now: d(38))
        XCTAssertEqual(try db.blocksToOrganize().count, 1, "文字没变不算整理过")
        try db.updateBlockText(text, text: long + "又，章学诚“六经皆史”之说亦当并观。", now: d(38))
        XCTAssertTrue(try db.blocksToOrganize().isEmpty, "改过文字就不再算待整理")
        // 已吸收也清掉待整理
        try db.recordBlockRevisit(blockId: text, outcome: .organize, now: d(38))
        try db.recordBlockRevisit(blockId: text, outcome: .absorbed, now: d(45))
        XCTAssertTrue(try db.blocksToOrganize().isEmpty)
        // 重温记在 revisit_log，不进 review_event
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM revisit_log WHERE kind = 'block'") }, 5)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_event") }, 0)
        // 删除段落连排程一起去掉
        try db.deleteBlocks([text], now: d(46))
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notebook_block_review") }, 0)
    }

    func testOldBlocksSpreadAndDailyLimit() throws {
        let db = try AppDatabase(DatabaseQueue())
        let nb = try db.createNotebook(title: "旧笔记", now: d(-200))
        let ids = try db.insertBlocks((0..<6).map {
            NotebookBlock(notebookId: nb.id!, position: Double($0), kind: .text, text: long + "第\($0)段")
        }, into: nb.id!, after: nil, now: d(-200)).map { $0.id! }
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: t0).blocks.isEmpty, "升级当天不来")
        let days = try db.writer.read { try String.fetchAll($0, sql: "SELECT dueDay FROM notebook_block_review ORDER BY dueDay") }
        XCTAssertEqual(days.count, 6)
        XCTAssertGreaterThan(days.first!, AppDatabase.revisitDay(t0))
        XCTAssertLessThanOrEqual(days.last!, AppDatabase.revisitDay(t0, plus: 60), "旧段落分散在之后 60 天内")
        // 到了第 60 天全部到期：每天至多 2 段，处理过的占名额
        var q = try db.revisitQueue(limits: lim, now: d(60))
        XCTAssertEqual(q.blocks.count, 2)
        try db.recordBlockRevisit(blockId: q.blocks[0].id, outcome: .absorbed, now: d(60))
        q = try db.revisitQueue(limits: lim, now: d(60, hour: 1))
        XCTAssertEqual(q.blocks.count, 1)
        XCTAssertEqual(q.blocksDone, 1)
        XCTAssertEqual(try db.revisitCounts(limits: lim, now: d(60, hour: 1)).blocksLeft, 1)
        XCTAssertTrue(try db.revisitQueue(limits: RevisitLimits(notes: 2, questions: 1, books: 1, blocks: 0), now: d(61)).blocks.isEmpty, "设为 0 不重温")
        // 清空的段落不来
        for id in ids { try db.updateBlockText(id, text: "", now: d(61)) }
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(62)).blocks.isEmpty)
    }

    func testDailyCheckSnapshotSkipAndNextDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        func c(_ done: Int, _ left: Int) -> DailyCheckCount { DailyCheckCount(done: done, left: left) }
        // 统计还没算出来时只显示、不定应做数
        var s = try db.dailyCheck(current: [.review: c(0, 0)], snapshot: false, now: t0)
        XCTAssertEqual(s.due, 0)
        XCTAssertNil(try db.writer.read { try String.fetchOne($0, sql: "SELECT day FROM daily_checkin") })
        // 第一次统计定下应做数
        s = try db.dailyCheck(current: [.review: c(0, 10), .cards: c(2, 18), .revisit: c(0, 3), .selfTest: c(0, 2)], now: t0)
        XCTAssertEqual(s.rows.map(\.due), [10, 20, 3, 2])
        XCTAssertEqual(s.due, 35)
        XCTAssertEqual(s.done, 2)
        // 新到期的不追加；做得比应做多按已做计（但合计中不超过应做）
        s = try db.dailyCheck(current: [.review: c(12, 0), .cards: c(10, 25), .revisit: c(3, 0), .selfTest: c(1, 1)], now: d(0, hour: 3))
        XCTAssertEqual(s.rows.map(\.due), [12, 20, 3, 2], "回顾再抽一组后按已做计；记忆卡新到期的不算")
        XCTAssertEqual(s.rows.filter(\.isComplete).map(\.group), [.review, .revisit])
        XCTAssertEqual(s.done, 12 + 10 + 3 + 1)
        XCTAssertEqual(s.due, 37)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT doneCount FROM daily_checkin") }, 26, "合计随之记下")
        // 跳过整组：不计入合计，可恢复
        try db.setDailyCheckGroup(.cards, skipped: true, now: d(0, hour: 4))
        s = try db.dailyCheck(current: [.review: c(12, 0), .cards: c(10, 25), .revisit: c(3, 0), .selfTest: c(2, 0)], now: d(0, hour: 4))
        XCTAssertTrue(s.rows.first { $0.group == .cards }!.skipped)
        XCTAssertEqual(s.due, 17)
        XCTAssertEqual(s.left, 0)
        XCTAssertEqual(s.completion, 1)
        try db.setDailyCheckGroup(.cards, skipped: false, now: d(0, hour: 5))
        s = try db.dailyCheck(current: [.cards: c(10, 25)], now: d(0, hour: 5))
        XCTAssertFalse(s.rows.first { $0.group == .cards }!.skipped)
        XCTAssertEqual(s.rows.first { $0.group == .cards }!.due, 20)
        // 第二天重新定
        s = try db.dailyCheck(current: [.review: c(0, 10), .cards: c(0, 25)], now: d(1))
        XCTAssertEqual(s.rows.map(\.due), [10, 25, 0, 0])
        XCTAssertFalse(s.rows.contains(where: \.skipped))
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM daily_checkin") }, 2)
        // 今天没有应做的：完成度为空
        XCTAssertNil(try db.dailyCheck(current: [:], now: d(2)).completion)
    }

    func testSelfTestPerDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "国史大纲", author: "钱穆"))
        for i in 0..<6 {
            var h = Highlight(text: "对本国历史应略有所知之\(i)"); h.sourceId = src.id; h.isFavorite = true; h.location = "引论\(i)"
            _ = try db.save(h)
        }
        let week = GrowthPeriod.week.window(containing: t0, now: t0)
        let set = try db.selfTestSet(week: week, now: t0)
        XCTAssertGreaterThanOrEqual(set.items.count, 5)
        XCTAssertEqual(try db.selfTestToday(perDay: 2, now: t0), DailyCheckCount(done: 0, left: 2))
        try db.recordSelfTest(set.items[0], result: .remembered, week: week, now: t0)
        XCTAssertEqual(try db.selfTestToday(perDay: 2, now: d(0, hour: 1)), DailyCheckCount(done: 1, left: 1))
        try db.recordSelfTest(set.items[1], result: .forgot, week: week, now: d(0, hour: 1))
        try db.recordSelfTest(set.items[2], result: .partly, week: week, now: d(0, hour: 1))
        XCTAssertEqual(try db.selfTestToday(perDay: 2, now: d(0, hour: 2)), DailyCheckCount(done: 3, left: 0), "多做的照记")
        // 同一周的第二天：只剩没做过的题
        let rest = set.items.count - 3
        let next = Calendar.current.isDate(d(1), equalTo: t0, toGranularity: .weekOfYear) ? d(1) : t0
        if next != t0 {
            XCTAssertEqual(try db.selfTestToday(perDay: 2, now: next), DailyCheckCount(done: 0, left: min(2, rest)))
        }
        XCTAssertEqual(try db.selfTestToday(perDay: 0, now: t0), DailyCheckCount(), "设为 0 不带自测")
    }

    func testStoreDailyCheckAndBlockRevisit() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let nb = try db.createNotebook(title: "清代学术", now: Date().addingTimeInterval(-90 * 86_400))
            let block = try db.insertBlocks([NotebookBlock(notebookId: nb.id!, position: 1, kind: .text, text: long)],
                                            into: nb.id!, after: nil, now: Date().addingTimeInterval(-90 * 86_400))[0]
            // 旧段落分散在之后 60 天，直接改成今天到期
            _ = try db.revisitQueue()
            try db.writer.write { try $0.execute(sql: "UPDATE notebook_block_review SET dueDay = ?", arguments: [AppDatabase.revisitDay(Date())]) }
            let store = LibraryStore(db: db)
            store.refreshRevisit()
            XCTAssertEqual(store.revisitCounts.blocksLeft, 1)
            XCTAssertEqual(store.dailyCheck.rows.map(\.group), DailyCheckGroup.exam, "6.0.3：自测并入卷子")
            XCTAssertEqual(store.dailyCheck.rows.first { $0.group == .revisit }?.due, 1)
            store.revisitBlock(block.id!, .organize)
            XCTAssertEqual(store.revisitCounts.blocksLeft, 0)
            let revisit = try XCTUnwrap(store.dailyCheck.rows.first { $0.group == .revisit })
            XCTAssertEqual(revisit.done, 1)
            XCTAssertTrue(revisit.isComplete)
            store.setDailyCheckGroup(.revisit, skipped: true)
            XCTAssertTrue(store.dailyCheck.rows.first { $0.group == .revisit }!.skipped)
            store.openDailyCheck()
            XCTAssertEqual(store.selection, .dailyCheck)
            store.openDailyCheckGroup(.revisit)
            XCTAssertEqual(store.selection, .revisit)
        }
    }
}
