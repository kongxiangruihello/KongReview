import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.0.2：自测、小胜、学问检视、问题的经过
final class V502ProgressTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private var all: (Date, Date) { (Date.distantPast, Date.distantFuture) }

    func testMigrationBaselineIsQuietAndOnceOnly() throws {
        let db = try AppDatabase(DatabaseQueue(), upTo: "v20-revisit")
        let src = try db.save(Source(title: "孟子译注"))
        var h = Highlight(text: "无恒产而有恒心者，惟士为能"); h.sourceId = src.id
        h = try db.save(h)
        let target = try db.createIdeaNote(title: "士之可贵", now: d(-30))
        _ = try db.createIdeaNote(title: "引者", body: "<p>见 [[士之可贵]]</p>", highlightIDs: [h.id!], now: d(-29))
        let q = try db.createQuestion(title: "旧问题", now: d(-20))
        _ = try db.saveQuestion(id: q.id!, title: "旧问题", detail: "", answer: "<p>答</p>")
        try db.setQuestionStatus(id: q.id!, .solved, now: d(-10))
        try db.migrateIfNeeded()
        XCTAssertTrue(try db.progressEvents(start: all.0, end: all.1).isEmpty, "升级前的旧事记为底账，不显示")
        // 重新打开再解决：“解决”不重复记
        try db.setQuestionStatus(id: q.id!, .open, now: d(0))
        try db.setQuestionStatus(id: q.id!, .solved, now: d(0, hour: 1))
        XCTAssertFalse(try db.progressEvents(start: all.0, end: all.1).contains { $0.kind == .questionSolved })
        // 已被链接过的札记再被链接：不记；新札记第一次被链接：记
        _ = try db.createIdeaNote(title: "又一条", body: "<p>[[士之可贵]]</p>", now: d(1))
        XCTAssertFalse(try db.progressEvents(start: all.0, end: all.1).contains { $0.kind == .noteLinked && $0.recordId == target.id })
        let fresh = try db.createIdeaNote(title: "新论断", now: d(1))
        _ = try db.createIdeaNote(title: "再一条", body: "<p>参见 [[新论断]]</p>", now: d(2))
        XCTAssertEqual(try db.progressEvents(start: all.0, end: all.1).filter { $0.kind == .noteLinked }.map(\.recordId), [fresh.id!])
        // 同一出处再被引用：不记
        try db.addHighlights([h.id!], toIdeaNote: fresh.id!, now: d(3))
        XCTAssertFalse(try db.progressEvents(start: all.0, end: all.1).contains { $0.kind == .sourceCited })
    }

    func testProgressEventsAndTodayGains() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "论语译注"))
        var h = Highlight(text: "士不可以不弘毅"); h.sourceId = src.id
        h = try db.save(h)
        let q = try db.createQuestion(title: "弘毅何解", now: d(-5))
        try db.addQuestionMaterial(questionId: q.id!, kind: .highlight, recordId: h.id!, now: d(0))
        let note = try db.createIdeaNote(title: "弘毅", body: "<p>甲</p>", highlightIDs: [h.id!], now: d(-3))
        try db.saveIdeaNote(id: note.id!, title: "弘毅", body: "<p>甲乙</p>", now: d(0, hour: 2))
        try db.saveIdeaNote(id: note.id!, title: "弘毅", body: "<p>甲乙丙</p>", now: d(0, hour: 3))
        _ = try db.saveQuestion(id: q.id!, title: "弘毅何解", detail: "", answer: "<p>弘言其量</p>")
        try db.setQuestionStatus(id: q.id!, .solved, now: d(0, hour: 4))
        let events = try db.progressEvents(start: all.0, end: all.1)
        XCTAssertEqual(events.map(\.kind), [.questionSolved, .noteRevised, .questionLead, .sourceCited], "新的在前；同一天修订只记一次")
        XCTAssertEqual(events.first?.text, "解决了问题《弘毅何解》")
        let gains = try db.todayGains(now: d(0, hour: 5))
        XCTAssertEqual(gains, ["解决了问题《弘毅何解》", "修订了札记《弘毅》", "问题《弘毅何解》有了线索"])
        XCTAssertTrue(try db.todayGains(now: d(1)).isEmpty)
    }


}
