import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.3：自评偏高的题——近 30 天、以最近一次为准、已删去的不列
final class V630DailyTests: XCTestCase {
    private func match(_ hits: Int, of total: Int) -> IdeaUnitMatch {
        IdeaUnitMatch(units: (0..<total).map { IdeaUnit(text: "要点\($0)", hit: $0 < hits) })
    }

    func testOverconfidentItems() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = Date()
        let src = try db.save(Source(title: "论语译注"))
        let h1 = try db.save(Highlight(sourceId: src.id, text: "学而时习之，不亦说乎", location: "学而"))
        let h2 = try db.save(Highlight(text: "温故而知新"))
        let gone = try db.save(Highlight(text: "已删去的"))
        let card = try db.save(Card(deck: "史学", front: "钱穆论国史", back: "温情与敬意"))
        let note = try db.createIdeaNote(title: "士以道自任")
        // h1：判记得、写出 1/4——偏高
        try db.recordCalibration(kind: .highlight, recordId: h1.id!, match: match(1, of: 4), result: .remembered, now: now.addingTimeInterval(-3_600))
        // h2：先偏高，后来写全了——以最近一次为准，不列
        try db.recordCalibration(kind: .highlight, recordId: h2.id!, match: match(0, of: 3), result: .remembered, now: now.addingTimeInterval(-3 * 86_400))
        try db.recordCalibration(kind: .highlight, recordId: h2.id!, match: match(3, of: 3), result: .remembered, now: now.addingTimeInterval(-86_400))
        // 删去的不列
        try db.recordCalibration(kind: .highlight, recordId: gone.id!, match: match(0, of: 2), result: .remembered, now: now)
        try db.moveToTrash(gone, now: now)
        // 记忆卡、札记偏高
        try db.recordCalibration(kind: .card, recordId: card.id!, match: match(0, of: 2), result: .remembered, now: now.addingTimeInterval(-7_200))
        try db.recordCalibration(kind: .note, recordId: note.id!, match: match(1, of: 3), result: .remembered, now: now.addingTimeInterval(-10 * 86_400))
        // 判忘了的（偏低）不列；40 天前的不列
        let h3 = try db.save(Highlight(text: "三人行"))
        try db.recordCalibration(kind: .highlight, recordId: h3.id!, match: match(3, of: 3), result: .forgot, now: now)
        let old = try db.save(Highlight(text: "很久以前"))
        try db.recordCalibration(kind: .highlight, recordId: old.id!, match: match(0, of: 2), result: .remembered, now: now.addingTimeInterval(-40 * 86_400))

        let items = try db.overconfidentItems(now: now)
        XCTAssertEqual(items.map(\.recordId), [h1.id!, card.id!, note.id!], "新的在前")
        XCTAssertEqual(items.map(\.kind), [.highlight, .card, .note])
        XCTAssertEqual(items[0].detail, "《论语译注》 学而")
        XCTAssertEqual(items[0].hits, 1); XCTAssertEqual(items[0].units, 4)
        XCTAssertEqual(items[1].detail, "史学")
        XCTAssertEqual(items[0].weakItem.recordId, h1.id!)
        XCTAssertEqual(try db.overconfidentItems(limit: 1, now: now).count, 1)
    }
}
