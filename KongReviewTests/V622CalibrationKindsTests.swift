import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.2.2：要点对照扩到记忆卡、论证题、复述题——评分折算与统计
final class V622CalibrationKindsTests: XCTestCase {
    func testGradeMapping() {
        XCTAssertEqual(SelfTestResult(card: .again), .forgot)
        XCTAssertEqual(SelfTestResult(card: .hard), .partly)
        XCTAssertEqual(SelfTestResult(card: .good), .remembered)
        XCTAssertEqual(SelfTestResult(card: .easy), .remembered)
        XCTAssertEqual(SelfTestResult(block: .absorbed), .remembered)
        XCTAssertEqual(SelfTestResult(block: .reread), .forgot)
        XCTAssertEqual(SelfTestResult(block: .organize), .partly)
    }

    func testAllKindsCountedInTally() throws {
        let db = try AppDatabase(DatabaseQueue())
        let now = Date()
        // 记忆卡：判“良好”，背面四处一处也没写全——偏高
        let back = IdeaUnits.match(answer: "温故", standard: "温故而知新，可以为师矣；学而不思则罔，思而不学则殆")
        XCTAssertEqual(back.total, 4)
        try db.recordCalibration(kind: .card, recordId: 1, match: back, result: SelfTestResult(card: .good), now: now)
        // 论证题：判“忘了”，却写出全部——偏低
        let note = IdeaUnits.match(answer: "士以道自任，不以身份为限", standard: "士以道自任，不以身份为限")
        try db.recordCalibration(kind: .note, recordId: 1, match: note, result: .forgot, now: now)
        // 复述题：已吸收，写出大半——对得上
        let block = IdeaUnits.match(answer: "戴震以考据为手段，旨在重建义理", standard: "戴震以考据为手段，旨在重建义理，其书即是明证")
        try db.recordCalibration(kind: .block, recordId: 1, match: block, result: SelfTestResult(block: .absorbed), now: now)
        // 同一编号、不同类别各记一条
        let (start, end) = AppDatabase.dayBounds(now)
        let t = try db.calibrationTally(start: start, end: end.addingTimeInterval(1))
        XCTAssertEqual(t, CalibrationTally(written: 3, over: 1, under: 1))
        let kinds = try db.writer.read { try String.fetchAll($0, sql: "SELECT kind FROM exam_calibration ORDER BY kind") }
        XCTAssertEqual(kinds, ["block", "card", "note"])
    }
}
