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

    func testSelfTestDrawRulesAndRecovery() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "国史大纲", author: "钱穆"))
        func hl(_ text: String, fav: Bool = false, note: String? = nil, loc: String? = nil, source: Bool = true, discarded: Bool = false) throws -> Highlight {
            var h = Highlight(text: text); h.sourceId = source ? src.id : nil; h.isFavorite = fav; h.note = note; h.location = loc; h.isDiscarded = discarded
            return try db.save(h)
        }
        let fav = try hl("对本国历史应略有所知", fav: true, loc: "引论")
        let noted = try hl("温故而知新", note: "<p>可与《学而》互参</p>")
        let plain = try hl("没有任何标记的摘录")
        let noSource = try hl("无出处的收藏", fav: true, source: false)
        let gone = try hl("弃置的收藏", fav: true, discarded: true)
        let carded = try hl("已做卡的收藏", fav: true)
        _ = try db.save(Card(deck: "摘录", front: "问", back: "答", highlightId: carded.id!))
        let note = try db.createIdeaNote(title: "士由身份转为德行", highlightIDs: [plain.id!])
        let cited = plain   // 被札记引用后也可抽
        let items = try db.drawSelfTest(seed: "growth.week.2026-10-18", now: t0)
        let ids = Set(items.filter { $0.kind != .argument }.map(\.recordId))
        XCTAssertEqual(ids, [fav.id!, noted.id!, cited.id!], "收藏、按语、被引用的；排除无出处、弃置、已做卡")
        XCTAssertFalse(ids.contains(noSource.id!)); XCTAssertFalse(ids.contains(gone.id!)); XCTAssertFalse(ids.contains(carded.id!))
        XCTAssertEqual(items.filter { $0.kind == .argument }.map(\.recordId), [note.id!])
        XCTAssertTrue(items.filter { $0.kind == .gist }.allSatisfy { [fav.id!, noted.id!].contains($0.recordId) }, "要点题要有位置或按语作线索")
        XCTAssertEqual(try db.drawSelfTest(seed: "growth.week.2026-10-18", now: t0), items, "同一周抽出的相同")

        let week = GrowthPeriod.week.window(containing: t0, now: t0)
        let set = try db.selfTestSet(week: week, now: t0)
        XCTAssertEqual(try db.selfTestSet(week: week, now: d(2)), set, "本周沿用已抽的题")
        let item = try XCTUnwrap(set.items.first { $0.recordId == fav.id && $0.kind != .argument }, "札记与摘录的编号可能相同，取摘录的题")
        try db.recordSelfTest(item, result: .forgot, week: week, now: t0)
        try db.recordSelfTest(item, result: .partly, week: week, now: d(0, hour: 1))
        XCTAssertEqual(try db.selfTestResults(week: week)[item], .partly, "同一题重评以最后一次为准")
        XCTAssertTrue(try db.drawSelfTest(seed: "x", now: d(10)).allSatisfy { $0.recordId != fav.id || $0.kind == .argument }, "28 天内测过的不抽")
        // 下一次（另一周）从“忘了”到“记得”：记一件小胜
        try db.recordSelfTest(item, result: .forgot, week: week, now: d(0, hour: 2))
        let next = GrowthPeriod.week.window(containing: d(30), now: d(30))
        try db.recordSelfTest(item, result: .remembered, week: next, now: d(30))
        XCTAssertEqual(try db.progressEvents(start: all.0, end: all.1).filter { $0.kind == .selfTestRecovered }.count, 1)
    }

    func testInspectionTimelineAndYearMarkdown() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "士志于道"))
        let a = try db.createIdeaNote(title: "甲", body: "<p>见 [[乙]]</p>", highlightIDs: [h.id!], now: d(-400))
        _ = try db.createIdeaNote(title: "乙", now: d(-400))
        try db.saveIdeaNote(id: a.id!, title: "甲", body: "<p>见 [[乙]]，又改</p>", now: d(0))
        let q = try db.createQuestion(title: "问", now: d(-4))
        try db.addQuestionMaterial(questionId: q.id!, kind: .highlight, recordId: h.id!, now: d(-2))
        _ = try db.saveQuestion(id: q.id!, title: "问", detail: "", answer: "<p>答</p>")
        try db.setQuestionStatus(id: q.id!, .solved, now: d(0, hour: 1))
        _ = try db.createQuestion(title: "另一问", now: d(0))
        let month = GrowthPeriod.month.window(containing: t0, now: d(1))
        let x = try await db.inspection(start: month.start, end: month.end, now: d(1))
        XCTAssertEqual(x.notes, 2)
        XCTAssertEqual(x.avgCited, 0.5, accuracy: 0.001)
        XCTAssertEqual(x.avgBacklinks, 0.5, accuracy: 0.001)
        XCTAssertEqual(x.revisedNotes, 1)
        XCTAssertEqual(x.solvedInPeriod, 1)
        XCTAssertEqual(x.open, 1)
        XCTAssertEqual(x.avgDaysToSolve ?? 0, 4 + 1.0 / 24, accuracy: 0.01)
        XCTAssertEqual(x.untouchedNoteCount, 1, "乙半年多没改、没重温")

        let steps = try db.questionTimeline(id: q.id!)
        XCTAssertEqual(steps.map(\.text), ["记下这个问题", "挂上摘录：士志于道", "有了线索", "解决"])

        let year = GrowthPeriod.year.window(containing: t0, now: d(1))
        let md = try await db.yearMarkdown(year)
        XCTAssertTrue(md.hasPrefix("# 2026 年的学问"))
        XCTAssertTrue(md.contains("## 进展"))
        XCTAssertTrue(md.contains("## 观点的变化（1）"))
        XCTAssertTrue(md.contains("### 解决的问题（1）"))
    }
}
