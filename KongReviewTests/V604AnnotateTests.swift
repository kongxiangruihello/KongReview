import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.4：每天标注文章——哪些算文章、哪些算已标过、每天抽定、划线成摘录、标完、计入今日试卷
final class V604AnnotateTests: XCTestCase {
    private var savedPerDay: Any?

    override func setUp() {
        super.setUp()
        savedPerDay = UserDefaults.standard.object(forKey: AnnotateSettings.perDayKey)
        UserDefaults.standard.removeObject(forKey: AnnotateSettings.perDayKey)
    }

    override func tearDown() {
        if let savedPerDay { UserDefaults.standard.set(savedPerDay, forKey: AnnotateSettings.perDayKey) } else { UserDefaults.standard.removeObject(forKey: AnnotateSettings.perDayKey) }
        super.tearDown()
    }

    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 3; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour - 10, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }

    /// 一篇长文：第 i 篇，每段都不同
    private func longText(_ i: Int, paragraphs: Int = 12) -> String {
        (0..<paragraphs).map { p in "第\(i)篇第\(p)段：学而时习之，不亦说乎；有朋自远方来，不亦乐乎；人不知而不愠，不亦君子乎。温故而知新，可以为师矣。编号\(i)-\(p)。" }
            .joined(separator: "\n\n")
    }

    func testNormalizeAndAlreadyMarked() {
        XCTAssertEqual(AppDatabase.annotateNormalize("<b>学而</b>，时习 之！"), "学而时习之")
        let body = longText(1)
        XCTAssertTrue(AppDatabase.annotateAlreadyMarked(body: body, shorts: ["有朋自远方来，不亦乐乎"]), "以前划过的一句在正文里")
        XCTAssertFalse(AppDatabase.annotateAlreadyMarked(body: body, shorts: ["己所不欲，勿施于人"]))
        XCTAssertFalse(AppDatabase.annotateAlreadyMarked(body: body, shorts: ["学而"]), "太短的不算")
        XCTAssertFalse(AppDatabase.annotateAlreadyMarked(body: body, shorts: []))
        XCTAssertEqual(AnnotateSettings.perDay(), 5, "默认每天 5 篇")
    }

    func testPickDailyStableAndExclusions() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "论语"))
        let other = try db.save(Source(title: "孟子"))
        var articles: [Int64] = []
        for i in 0..<8 { articles.append(try db.save(Highlight(sourceId: src.id, text: longText(i))).id!) }
        // 不算：太短、弃置、删除
        _ = try db.save(Highlight(sourceId: src.id, text: "短摘录，不算文章"))
        _ = try db.save(Highlight(sourceId: src.id, text: longText(90), isDiscarded: true))
        _ = try db.save(Highlight(sourceId: src.id, text: longText(91), deletedAt: t0))
        // 以前在别处划过：同一出处下的短摘录出现在正文里
        let marked = try db.save(Highlight(sourceId: other.id, text: longText(50))).id!
        _ = try db.save(Highlight(sourceId: other.id, text: "第50篇第3段：学而时习之，不亦说乎"))

        let a = try db.annotateToday(count: 5, now: t0)
        XCTAssertEqual(a.items.count, 5)
        XCTAssertTrue(Set(a.items.map(\.id)).isSubset(of: Set(articles)), "只抽够长、未弃置、未删除、没在别处划过的")
        XCTAssertFalse(a.items.contains { $0.id == marked })
        XCTAssertEqual(a.items.first?.title, "论语", "开头一段太长，题目用出处名")
        XCTAssertEqual(a.done, 0); XCTAssertEqual(a.left, 5)
        XCTAssertEqual(try db.annotateToday(count: 5, now: d(0, hour: 15)).items.map(\.id), a.items.map(\.id), "同一天沿用")
        let more = try db.annotateToday(count: 7, now: d(0, hour: 16))
        XCTAssertEqual(Array(more.items.map(\.id).prefix(5)), a.items.map(\.id), "调多了当天补足，原来的不变")
        XCTAssertEqual(more.items.count, 7)
        XCTAssertEqual(try db.annotateToday(count: 3, now: d(0, hour: 17)).items.map(\.id), Array(a.items.map(\.id).prefix(3)), "调少了只显示前几篇")
        XCTAssertTrue(try db.annotateToday(count: 0, now: d(0, hour: 18)).items.isEmpty)
    }

    func testMarkFinishAndNextDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "论语", author: "孔子"))
        for i in 0..<4 { _ = try db.save(Highlight(sourceId: src.id, text: longText(i), location: "卷\(i)")) }
        let today = try db.annotateToday(count: 2, now: t0)
        let first = today.items[0], second = today.items[1]
        XCTAssertEqual(first.author, "孔子")

        let mark = try XCTUnwrap(try db.addAnnotationMark(articleId: first.id, text: "  温故而知新，可以为师矣  ", now: d(0, hour: 11)))
        XCTAssertEqual(mark.sourceId, src.id, "存为同一出处下的新摘录")
        XCTAssertEqual(mark.text, "温故而知新，可以为师矣")
        XCTAssertNotNil(mark.location)
        XCTAssertNil(try db.addAnnotationMark(articleId: first.id, text: "   ", now: d(0, hour: 11)), "空选不存")
        let original = try db.highlights(ids: [first.id]).first
        XCTAssertEqual(original?.text.count, longText(0).count, "原文不动")

        try db.finishAnnotation(articleId: second.id, now: d(0, hour: 12))
        var a = try db.annotateToday(count: 2, now: d(0, hour: 13))
        XCTAssertEqual(a.items.first { $0.id == first.id }?.marksToday, 1)
        XCTAssertEqual(a.items.first { $0.id == second.id }?.finishedToday, true)
        XCTAssertEqual(a.done, 2, "划过一条或点了标完即算完成")
        XCTAssertTrue(try db.annotationMarks(articleId: first.id).contains { $0.id == mark.id }, "划的这条在正文里标黄")

        // 第二天：标过的不再抽
        a = try db.annotateToday(count: 2, now: d(1))
        XCTAssertFalse(a.items.contains { $0.id == first.id || $0.id == second.id })
        XCTAssertEqual(a.items.count, 2)
        XCTAssertEqual(a.done, 0)
        let art = try db.annotationArticle(articleId: a.items[0].id)
        XCTAssertEqual(art?.id, -a.items[0].id, "当作文章打开时 id 取负")
        XCTAssertEqual(art?.sourceId, src.id)
    }

    func testDailyCheckAndStore() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语"))
            for i in 0..<3 { _ = try db.save(Highlight(sourceId: src.id, text: longText(i))) }
            let store = LibraryStore(db: db)
            UserDefaults.standard.set(2, forKey: AnnotateSettings.perDayKey)
            store.refreshDailyCheck()
            XCTAssertEqual(store.annotate.items.count, 2)
            XCTAssertTrue(store.dailyCheck.rows.contains { $0.group == .annotate }, "今日试卷上列“标注文章”")
            XCTAssertEqual(store.dailyCheck.rows.first { $0.group == .annotate }?.due, 2)

            // 阅读器里按 H：长摘录当作文章打开（id 取负），划的一段存为摘录并计入
            let id = store.annotate.items[0].id
            let article = try XCTUnwrap(try db.annotationArticle(articleId: id))
            store.addHighlight(from: article, text: "有朋自远方来")
            XCTAssertEqual(store.annotate.items[0].marksToday, 1)
            XCTAssertEqual(store.dailyCheck.rows.first { $0.group == .annotate }?.done, 1)

            store.openAnnotation(id)
            XCTAssertEqual(store.annotating?.articleId, id)
            store.finishAnnotation(store.annotate.items[1].id)
            store.openNextAnnotation(after: store.annotate.items[1].id)
            XCTAssertNil(store.annotating, "都做完了就关闭")
            XCTAssertEqual(store.annotate.done, 2)

            UserDefaults.standard.set(0, forKey: AnnotateSettings.perDayKey)
            store.refreshDailyCheck()
            XCTAssertTrue(store.annotate.items.isEmpty)
            XCTAssertFalse(store.examGroups.contains(.annotate), "设为 0 不出，也不计入")
        }
    }

    func testLegacyDefaultGroups() throws {
        let db = try AppDatabase(DatabaseQueue())
        let s = try db.dailyCheck(current: [:], now: t0)
        XCTAssertEqual(s.rows.map(\.group), DailyCheckGroup.legacy, "旧接口默认仍是四组")
        XCTAssertEqual(DailyCheckGroup.exam, [.review, .cards, .revisit, .annotate])
    }
}
