import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.0-b：写作量——笔记本自动记录、手记、外部稿件全文、项目与全库统计
final class V40WritingTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 21, hour: 12))! }
    private func day(_ offset: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .hour, value: hour - 12, to: now.addingTimeInterval(Double(offset) * 86_400))!
    }
    private func rows(_ db: AppDatabase) throws -> [Row] {
        try db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM writing_log ORDER BY id") }
    }

    func testNotebookEditsAreLoggedPerNotebookAndDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "学而时习之，不亦说乎"))
        let n = try db.createNotebook(title: "论语专题")
        let blocks = try db.insertBlocks([NotebookBlock(notebookId: n.id!, position: 0, kind: .text, text: "<p>学与习有别</p>"),
                                          NotebookBlock(notebookId: n.id!, position: 0, kind: .highlight, highlightId: h.id, text: h.text)],
                                         into: n.id!, after: nil, now: day(0))
        var r = try rows(db)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?["added"] as Int?, 5, "引文不计，只计自写的 5 字")
        let text = blocks[0].id!, quote = blocks[1].id!
        try db.updateBlockText(text, text: "<p>学与习有别：学是效法，习是温习</p>", now: day(0, hour: 15))
        try db.updateBlockNote(quote, note: "按：时习", now: day(0, hour: 16))
        try db.updateBlockText(text, text: "<p>学是效法</p>", now: day(0, hour: 17))
        r = try rows(db)
        XCTAssertEqual(r.count, 1, "同一笔记本同一天合并为一行")
        XCTAssertEqual(r.first?["added"] as Int?, 5 + 8 + 3, "改写增加 8 字，批注 3 字")
        XCTAssertEqual(r.first?["removed"] as Int?, 9, "改短 9 字")
        try db.deleteBlocks([quote], now: day(1))
        r = try rows(db)
        XCTAssertEqual(r.count, 2, "第二天另起一行")
        XCTAssertEqual(r.last?["removed"] as Int?, 3, "删除带批注的摘录块，批注计入删减")
        _ = try db.insertBlocks([NotebookBlock(notebookId: n.id!, position: 0, kind: .text, text: "撤销恢复的文字")],
                                into: n.id!, after: nil, logsWriting: false, now: day(1))
        XCTAssertEqual(try rows(db).count, 2, "撤销删除时重新插入不计")
        XCTAssertEqual(try db.notebookOwnWords(n.id!), 4 + 7)
    }

    func testManualEntriesExternalTotalsAndProjectWriting() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let p = try db.saveResearchProject(ResearchProject(title: "论文", targetWords: 20_000), now: day(-30))
        let linked = try db.createNotebook(title: "所归专题")
        let other = try db.createNotebook(title: "无关专题")
        try db.linkToResearchProject(p.id!, kind: .notebook, recordId: linked.id!)
        _ = try db.insertBlocks([NotebookBlock(notebookId: linked.id!, position: 0, kind: .text, text: "一二三四五六七八九十")],
                                into: linked.id!, after: nil, now: day(-8))
        _ = try db.insertBlocks([NotebookBlock(notebookId: other.id!, position: 0, kind: .text, text: "不属于项目")],
                                into: other.id!, after: nil, now: day(-8))
        try db.addManualWriting(projectId: p.id!, words: 1_500, day: day(-2), note: "第一节", now: day(-2))
        try db.addManualWriting(projectId: p.id!, words: 0, day: day(-2)) // 0 字不记
        XCTAssertEqual(try db.recordExternalWritingTotal(projectId: p.id!, total: 3_000, day: day(-1), now: day(-1)), 0, "第一次全文字数只作起点")
        XCTAssertEqual(try db.recordExternalWritingTotal(projectId: p.id!, total: 3_800, day: day(0), now: day(0)), 800)
        XCTAssertEqual(try db.recordExternalWritingTotal(projectId: p.id!, total: 3_500, day: day(0), now: day(0)), 0, "减少时只记删减")

        let w = try await db.projectWriting(projectId: p.id!, now: now, calendar: calendar)
        XCTAssertEqual(w.weeks.count, 12)
        XCTAssertEqual(w.weeks.reduce(0) { $0 + $1.added }, 10 + 1_500 + 800, "无关专题不计入项目")
        XCTAssertEqual(w.recent.added, 2_310)
        XCTAssertEqual(w.recent.days, 3)
        XCTAssertEqual(w.notebookWords, 10)
        XCTAssertEqual(w.external?.total, 3_500)
        XCTAssertEqual(w.manuscriptWords, 3_510)
        XCTAssertEqual(w.entries.first?.manual, true)
        XCTAssertTrue(w.entries.contains { $0.notebookTitle == "所归专题" && !$0.manual })

        let all = try await db.writingSummary(start: day(-10, hour: 0), end: day(1, hour: 0))
        XCTAssertEqual(all.added, 10 + 5 + 1_500 + 800, "全库包括不属于项目的专题")
        XCTAssertEqual(all.removed, 300)
        XCTAssertEqual(all.days, 3)
        let projectWeek = try await db.projectWritingSummary(projectId: p.id!, start: day(-3, hour: 0), end: day(1, hour: 0))
        XCTAssertEqual(projectWeek.added, 2_300)
        let today = try await db.writingSummary(start: day(0, hour: 0), end: day(0, hour: 13))
        XCTAssertEqual(today.added, 800, "进行中的周期包括今天")

        let manual = try XCTUnwrap(w.entries.first { $0.manual && $0.added == 1_500 })
        try db.deleteWritingEntry(manual.id)
        let after = try await db.projectWriting(projectId: p.id!, now: now, calendar: calendar)
        XCTAssertEqual(after.recent.added, 810)
    }

    func testStoreRecordsWritingAndRefreshes() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            let p = try db.saveResearchProject(ResearchProject(title: "讲稿", kind: .lecture))
            store.refreshResearchProjects()
            let revision = store.researchProjectRevision
            XCTAssertTrue(store.recordWriting(p, words: 600, byTotal: false, day: Date(), note: ""))
            XCTAssertGreaterThan(store.researchProjectRevision, revision)
            XCTAssertTrue(store.recordWriting(p, words: 2_000, byTotal: true, day: Date(), note: ""))
            let entries = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writing_log WHERE origin = 'manual'") }
            XCTAssertEqual(entries, 1, "第一次全文字数不记一行")
        }
    }
}
