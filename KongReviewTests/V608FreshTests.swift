import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.8：新录的摘录及早上卷；KongFolio 只有图片的摘录连图导入
final class V608FreshTests: XCTestCase {
    private let keys = [ReviewSessionRecord.key(theme: nil), ExamFresh.sessionKey, ExamFresh.perDayKey, SettingsKeys.dailyCount]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour - 10, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }

    func testFreshCandidatesRounds() throws {
        let db = try AppDatabase(DatabaseQueue())
        let today = try db.save(Highlight(text: "今天录的，明天才考", createdAt: d(0, hour: 8)))
        let yesterday = try db.save(Highlight(text: "昨天录的", createdAt: d(-1)))
        let older = try db.save(Highlight(text: "五天前录的", createdAt: d(-5)))
        let tooOld = try db.save(Highlight(text: "四十天前录的", createdAt: d(-40)))
        let article = try db.save(Highlight(text: String(repeating: "文章", count: 600), createdAt: d(-1)))
        var discarded = try db.save(Highlight(text: "弃置的", createdAt: d(-1)))
        discarded.isDiscarded = true
        discarded = try db.save(discarded)

        var c = try db.examFreshCandidates(now: d(0), limit: 10)
        XCTAssertEqual(c.map(\.id), [yesterday.id!, older.id!], "最近录的在前；今天录的、30 天前的、文章、弃置的不算")
        XCTAssertEqual(c.map(\.round), [1, 1])
        _ = (today, tooOld, article)

        // 五天前那条昨天考过一次：今天还不出第 2 次（隔两天起）
        try db.recordExamResult(kind: .gist, recordId: older.id!, result: .partly, now: d(-1))
        c = try db.examFreshCandidates(now: d(0), limit: 10)
        XCTAssertEqual(c.map(\.id), [yesterday.id!])
        // 隔两天：到了第 2 次，排在最前
        c = try db.examFreshCandidates(now: d(1), limit: 10)
        XCTAssertEqual(c.map(\.id), [older.id!, today.id!, yesterday.id!])
        XCTAssertEqual(c.first?.round, 2)
        // 考满两次就回到平常的抽样
        try db.recordExamResult(kind: .source, recordId: older.id!, result: .remembered, now: d(1))
        XCTAssertFalse(try db.examFreshCandidates(now: d(2), limit: 10).map(\.id).contains(older.id!))
        // 名额
        XCTAssertEqual(try db.examFreshCandidates(now: d(1), limit: 1).count, 1)
        XCTAssertTrue(try db.examFreshCandidates(now: d(1), limit: 0).isEmpty)
    }

    func testKongFolioImportCountsAsEnteredOnImportDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        // KongFolio 里三个月前的摘录，昨天才导入：按导入那天算新录
        let entry = KongFolioEntry(key: "record:X", kind: .highlight, text: "三个月前在 KongFolio 摘的", created: d(-90), modified: d(-90))
        _ = try db.importKongFolio(KongFolioConverter.Result(entries: [entry]), now: d(-1))
        let c = try db.examFreshCandidates(now: d(0), limit: 10)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(abs(c[0].enteredAt.timeIntervalSince(d(-1))), 0, accuracy: 1)
    }

    func testSessionPutsFreshAfterRetests() throws {
        try MainActor.assumeIsolated {
            UserDefaults.standard.set(5, forKey: SettingsKeys.dailyCount)
            UserDefaults.standard.set(2, forKey: ExamFresh.perDayKey)
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注", author: "杨伯峻"))
            for i in 0..<8 { _ = try db.save(Highlight(sourceId: src.id, text: "旧摘录 \(i)", location: "第\(i)页", createdAt: Date().addingTimeInterval(-60 * 86_400))) }
            let forgotten = try db.save(Highlight(sourceId: src.id, text: "忘了的", location: "第9页", createdAt: Date().addingTimeInterval(-60 * 86_400)))
            try db.recordExamResult(kind: .gist, recordId: forgotten.id!, result: .forgot, now: Date().addingTimeInterval(-3 * 86_400))
            let a = try db.save(Highlight(sourceId: src.id, text: "昨天新录甲", location: "第1页", createdAt: Date().addingTimeInterval(-86_400)))
            let b = try db.save(Highlight(sourceId: src.id, text: "昨天新录乙", location: "第2页", createdAt: Date().addingTimeInterval(-86_400 - 60)))
            _ = try db.save(Highlight(sourceId: src.id, text: "昨天新录丙", location: "第3页", createdAt: Date().addingTimeInterval(-86_400 - 120)))
            let store = LibraryStore(db: db)
            let record = try store.todayReviewSession()
            XCTAssertEqual(record.regularIds.count, 5)
            XCTAssertEqual(Array(record.regularIds.prefix(3)), [forgotten.id!, a.id!, b.id!], "补考在前，新录其次，至多 2 道")
            XCTAssertEqual(store.examFreshRound(a.id), 1)
            XCTAssertNil(store.examFreshRound(forgotten.id))
            XCTAssertEqual(store.examRetestsToday(), 3, "每天考多久时与补考一同优先")

            UserDefaults.standard.removeObject(forKey: ReviewSessionRecord.key(theme: nil))
            UserDefaults.standard.set(0, forKey: ExamFresh.perDayKey)
            _ = try store.todayReviewSession()
            XCTAssertNil(store.examFreshRound(a.id), "设为 0 不留名额")
        }
    }

    func testImageOnlyHighlightMode() {
        let image = Highlight(sourceId: 1, text: "![图片摘录](kr-media://media/kongfolio-a.png)", location: "第 3 页")
        XCTAssertEqual(ExamHighlightMode.pick(for: image, day: Date()), .gist, "只有图片的给出处想内容")
        XCTAssertEqual(ExamHighlightMode.pick(for: Highlight(text: "<img src=\"x.png\">"), day: Date()), .gist)
        XCTAssertEqual(ExamHighlightMode.pick(for: Highlight(text: "有字"), day: Date()), .opening)
    }

    func testKongFolioImageOnlyExcerptImportedWithImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kf-img-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        try png.write(to: assets.appendingPathComponent("b2.png"))
        let catalog = """
        {"version":1,"records":[
          {"id":"B2","kind":"图片摘录","title":"","quote":"","note":"图表：明代科举","imageAsset":"b2.png",
           "citations":[{"source":{"path":"","fileName":"国史大纲.pdf","page":9},"title":"国史大纲","author":"钱穆"}],"tags":[]},
          {"id":"B3","kind":"图片摘录","title":"","quote":"","note":"","imageAsset":"missing.png","citations":[],"tags":[]},
          {"id":"B4","kind":"图片摘录","title":"","quote":"","note":"","imageAsset":"../escape.png","citations":[],"tags":[]}
        ],"essays":[]}
        """
        let file = dir.appendingPathComponent("catalog.json")
        try Data(catalog.utf8).write(to: file)
        let r = try KongFolioConverter.read(file)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.skippedEmpty, 2, "找不到的图片、跳出文件夹的名字不导入")
        let e = r.entries[0]
        XCTAssertTrue(e.text.hasPrefix("![图片摘录](kr-media://media/kongfolio-"))
        XCTAssertEqual(e.media.values.first, png)
        XCTAssertEqual(e.location, "第 10 页")
        XCTAssertEqual(KongFolioConverter.convert(try KongFolioCatalog.decode(Data(catalog.utf8))).entries.count, 0, "没给图片文件夹时照旧跳过")

        let db = try AppDatabase(DatabaseQueue())
        let report = try db.importKongFolio(r, now: Date())
        XCTAssertEqual(report.newHighlights, 1)
        let name = try XCTUnwrap(e.media.keys.first)
        let stored = try db.writer.read { try Data.fetchOne($0, sql: "SELECT data FROM card_media WHERE name = ?", arguments: [name]) }
        XCTAssertEqual(stored, png, "图片存进媒体表")
        let h = try XCTUnwrap(try db.highlights(tag: nil).first)
        XCTAssertEqual(h.note?.contains("明代科举"), true)
        XCTAssertEqual(try db.importKongFolio(KongFolioConverter.read(file), now: Date()).added, 0, "再导入不重复")
    }
}
