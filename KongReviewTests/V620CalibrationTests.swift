import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.2：对照要点——记下写出几处与自评；成绩册里的“自评准不准”
final class V620CalibrationTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour - 10, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private func match(_ hits: Int, of total: Int) -> IdeaUnitMatch {
        IdeaUnitMatch(units: (0..<total).map { IdeaUnit(text: "要点\($0)", hit: $0 < hits) })
    }

    func testRecordAndTally() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertTrue(try db.writer.read { try $0.tableExists("exam_calibration") }, "迁移 v29")
        // 判记得、只写出 1/4：偏高
        try db.recordCalibration(kind: .highlight, recordId: 1, match: match(1, of: 4), result: .remembered, now: d(0))
        // 同一天再答以最后一次为准：改判大致
        try db.recordCalibration(kind: .highlight, recordId: 2, match: match(1, of: 4), result: .remembered, now: d(0))
        try db.recordCalibration(kind: .highlight, recordId: 2, match: match(1, of: 4), result: .partly, now: d(0, hour: 11))
        // 判忘了、写出 5/5：偏低
        try db.recordCalibration(kind: .answer, recordId: 1, match: match(5, of: 5), result: .forgot, now: d(0))
        // 判记得、写出 3/4：对得上
        try db.recordCalibration(kind: .highlight, recordId: 3, match: match(3, of: 4), result: .remembered, now: d(0))
        // 没有要点的不记
        try db.recordCalibration(kind: .highlight, recordId: 4, match: IdeaUnitMatch(units: []), result: .remembered, now: d(0))
        // 前一天的另算
        try db.recordCalibration(kind: .highlight, recordId: 1, match: match(0, of: 2), result: .remembered, now: d(-1))

        let today = try db.calibrationTally(start: d(0, hour: 0), end: d(1, hour: 0))
        XCTAssertEqual(today, CalibrationTally(written: 4, over: 1, under: 1))
        XCTAssertEqual(today.fair, 2)
        XCTAssertNil(today.fairRatio, "不足 5 道不算比例")
        let both = try db.calibrationTally(start: d(-1, hour: 0), end: d(1, hour: 0))
        XCTAssertEqual(both.written, 5)
        XCTAssertEqual(both.over, 2)
        XCTAssertEqual(both.fairRatio, 0.4)

        let report = try db.gradebookReport(GrowthPeriod.week.window(containing: t0, now: t0), now: t0)
        XCTAssertEqual(report.calibration.written, Calendar.current.isDate(d(-1), equalTo: t0, toGranularity: .weekOfYear) ? 5 : 4)
        XCTAssertEqual(GradebookFormat.calibration(CalibrationTally()), "")
        XCTAssertEqual(GradebookFormat.calibration(CalibrationTally(written: 5, over: 2, under: 1)),
                       "写了回答 5 道：对得上 2 道（40%）；判“记得”而要点写出不到一半 2 道（偏高）；判“忘了”而写出八成以上 1 道（偏低）")
    }

    func testStoreRecordsAlongsideGrading() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注", author: "杨伯峻"))
            let h = try db.save(Highlight(sourceId: src.id, text: "学而时习之，不亦说乎？有朋自远方来，不亦乐乎？"))
            let store = LibraryStore(db: db)
            let m = IdeaUnits.match(answer: "学而时习之", standard: "学而时习之，不亦说乎？有朋自远方来，不亦乐乎？")
            XCTAssertEqual(m.hits, 1); XCTAssertEqual(m.total, 4)
            store.examRecordCalibration(.highlight, recordId: h.id!, match: m, result: .remembered)
            let (start, end) = AppDatabase.dayBounds(Date())
            XCTAssertEqual(try db.calibrationTally(start: start, end: end).over, 1, "判记得而只写出 1/4")
            // 出处题：对照作者、书名、位置
            let source = IdeaUnits.match(answer: "杨伯峻的论语译注", units: ["杨伯峻", "论语译注", "学而第一"])
            XCTAssertEqual(source.units.map(\.hit), [true, true, false])
        }
    }
}
