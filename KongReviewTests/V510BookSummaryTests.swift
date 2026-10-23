import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.1：精简提要——保存、读完后 1 个月、半年、一年重温、每日上限、小胜与读完的书
final class V510BookSummaryTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 1; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: t0)! }
    private let lim = RevisitLimits(notes: 2, questions: 1, books: 1)

    func testSaveFinishAndRevisitStages() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "国史大纲", author: "钱穆"))
        try db.saveBookSummary(sourceId: src.id!, oneLine: "  以温情与敬意读国史  ", body: "<p>要点</p>", finishedAt: nil, now: t0)
        var s = try XCTUnwrap(try db.bookSummary(sourceId: src.id!))
        XCTAssertEqual(s.oneLine, "以温情与敬意读国史")
        XCTAssertNil(s.dueDay, "未读完不重温")
        XCTAssertTrue(try db.progressEvents(start: .distantPast, end: .distantFuture).isEmpty)

        try db.saveBookSummary(sourceId: src.id!, oneLine: s.oneLine, body: s.body, finishedAt: t0, now: t0)
        XCTAssertEqual(try db.progressEvents(start: .distantPast, end: .distantFuture).map(\.text), ["读完了《国史大纲》"])
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(29)).books.isEmpty)
        let item = try XCTUnwrap(try db.revisitQueue(limits: lim, now: d(30)).books.first, "读完后 30 天")
        XCTAssertEqual(item.title, "国史大纲"); XCTAssertEqual(item.stage, 0)
        XCTAssertEqual(try db.revisitCounts(limits: lim, now: d(30)).booksLeft, 1)

        try db.recordBookRevisit(sourceId: src.id!, outcome: .later, now: d(30))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(36)).books.isEmpty, "以后再说：一周后")
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(37)).books.first?.stage, 0)
        try db.recordBookRevisit(sourceId: src.id!, outcome: .agree, now: d(37))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(181)).books.isEmpty)
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(182)).books.first?.stage, 1, "半年")
        try db.recordBookRevisit(sourceId: src.id!, outcome: .revise, now: d(182))
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(365)).books.first?.stage, 2, "一年")
        try db.recordBookRevisit(sourceId: src.id!, outcome: .agree, now: d(365))
        s = try XCTUnwrap(try db.bookSummary(sourceId: src.id!))
        XCTAssertEqual(s.stage, 3)
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(800)).books.isEmpty, "三次之后不再来")

        // 再存一次（读完日期不变）：不重排、不再记小胜
        try db.saveBookSummary(sourceId: src.id!, oneLine: "改了一句", body: "", finishedAt: t0, now: d(400))
        XCTAssertEqual(try db.bookSummary(sourceId: src.id!)?.stage, 3)
        XCTAssertEqual(try db.progressEvents(start: .distantPast, end: .distantFuture).count, 1)
        // 改读完日期：从头排
        try db.saveBookSummary(sourceId: src.id!, oneLine: "改了一句", body: "", finishedAt: d(400), now: d(400))
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(430)).books.first?.stage, 0)
    }

    func testDailyLimitAndFinishedBooks() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Source(title: "甲书"))
        let b = try db.save(Source(title: "乙书"))
        try db.saveBookSummary(sourceId: a.id!, oneLine: "甲", body: "", finishedAt: d(0), now: d(0))
        try db.saveBookSummary(sourceId: b.id!, oneLine: "乙", body: "", finishedAt: d(1), now: d(1))
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(40)).books.map(\.id), [a.id!], "每天至多 1 本，到期早的先来")
        try db.recordBookRevisit(sourceId: a.id!, outcome: .agree, now: d(40))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(40)).books.isEmpty)
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(41)).books.map(\.id), [b.id!])
        XCTAssertTrue(try db.revisitQueue(limits: RevisitLimits(notes: 2, questions: 1, books: 0), now: d(41)).books.isEmpty, "设为 0 不重温")
        let month = GrowthPeriod.month.window(containing: t0, now: d(40))
        XCTAssertEqual(try db.finishedBooks(start: month.start, end: month.fullEnd).map(\.title), ["甲书", "乙书"])
    }

    func testStoreRevisitOpensEditorOnRevise() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "孟子译注"))
            try db.saveBookSummary(sourceId: src.id!, oneLine: "性善", body: "", finishedAt: Date().addingTimeInterval(-40 * 86_400))
            let store = LibraryStore(db: db)
            XCTAssertEqual(store.revisitCounts.booksLeft, 1)
            store.revisitBook(src.id!, .revise)
            XCTAssertEqual(store.bookSummaryEditor?.sourceId, src.id)
            XCTAssertEqual(store.revisitCounts.booksLeft, 0)
        }
    }
}
