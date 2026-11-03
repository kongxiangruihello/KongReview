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


}
