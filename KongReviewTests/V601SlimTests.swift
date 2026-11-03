import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.1：精简——舍弃功能里的内容导出为 Markdown 并留快照、只做一次；精简提要不再进重温；搜索不列网页存档
final class V601SlimTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v601-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func defaults() -> UserDefaults {
        let name = "v601-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testExportsDroppedContentOnceWithSnapshot() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "国史大纲", author: "钱穆"))
        try db.saveBookSummary(sourceId: src.id!, oneLine: "以温情与敬意读国史", body: "<p>要点<b>一</b></p>", finishedAt: nil)
        _ = try db.saveResearchProject(ResearchProject(title: "晚明讲学与士风", question: "讲学如何改变士风"))
        _ = try db.saveArticle(Article(url: "https://example.com/a", title: "存档的网页", contentHTML: "<p>网页正文</p>", contentText: "网页正文", wordCount: 4))

        let dir = try tempDir(), d = defaults()
        let r = try XCTUnwrap(try SlimUpgrade.run(db: db, defaults: d, directory: dir))
        XCTAssertEqual(r.files["精简提要"], 1)
        XCTAssertEqual(r.files["研究项目"], 1)
        XCTAssertEqual(r.files["网页存档"], 1)
        XCTAssertNil(r.files["写作记录"], "空的类别不写文件")

        let summary = try String(contentsOf: r.folder.appendingPathComponent("精简提要.md"), encoding: .utf8)
        XCTAssertTrue(summary.contains("以温情与敬意读国史"))
        XCTAssertTrue(summary.contains("要点一"), "HTML 转为纯文字")
        XCTAssertFalse(summary.contains("<b>"))
        let project = try String(contentsOf: r.folder.appendingPathComponent("研究项目.md"), encoding: .utf8)
        XCTAssertTrue(project.contains("## 1. 晚明讲学与士风"))
        XCTAssertTrue(project.contains("讲学如何改变士风"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("说明.md").path))

        // 快照是完整的数据库
        let snap = try DatabaseQueue(path: r.snapshot.path)
        XCTAssertEqual(try snap.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM book_summary") }, 1)
        XCTAssertEqual(try snap.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source") },
                       try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source") })

        // 原始记录不删
        XCTAssertNotNil(try db.writer.read { try Int64.fetchOne($0, sql: "SELECT sourceId FROM book_summary WHERE sourceId = ?", arguments: [src.id!]) })
        XCTAssertEqual(try db.researchProjects().count, 1)

        XCTAssertNil(try SlimUpgrade.run(db: db, defaults: d, directory: dir), "只做一次")
        XCTAssertTrue(r.message.contains("精简提要（1 条）"))
    }

    func testEmptyLibraryStillSnapshotsAndSaysNothingToExport() throws {
        let db = try AppDatabase(DatabaseQueue())
        let r = try XCTUnwrap(try SlimUpgrade.run(db: db, defaults: defaults(), directory: try tempDir()))
        XCTAssertTrue(r.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.snapshot.path))
        XCTAssertTrue(r.message.contains("没有您写的内容"))
    }

    func testSecondRunOnSameDayUsesNewFolder() throws {
        let db = try AppDatabase(DatabaseQueue())
        let dir = try tempDir()
        let a = try XCTUnwrap(try SlimUpgrade.run(db: db, defaults: defaults(), directory: dir))
        let b = try XCTUnwrap(try SlimUpgrade.run(db: db, defaults: defaults(), directory: dir))
        XCTAssertNotEqual(a.folder, b.folder, "已有同名文件夹时另起一个，不覆盖")
    }

    func testBookSummariesNoLongerRevisited() throws {
        let d = defaults()
        d.set(3, forKey: RevisitLimits.booksKey)
        XCTAssertEqual(RevisitLimits.saved(d).books, 0, "精简提要已舍弃：旧设置不再生效")
        XCTAssertEqual(RevisitLimits().books, 0)
    }

    func testSearchHidesWebArchive() {
        XCTAssertFalse(GlobalSearchKind.shown.contains(.article))
        XCTAssertEqual(Set(GlobalSearchKind.shown), Set(GlobalSearchKind.allCases).subtracting([.article]))
    }

    func testFocusIsOffInApp() throws {
        XCTAssertTrue(SlimSwitch.featuresOff)
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let source = try db.save(Source(title: "焦点书"))
            let h = try db.save(Highlight(sourceId: source.id, text: "焦点"))
            _ = try db.save(Card(deck: "甲", front: "焦点新卡", highlightId: h.id))
            try db.setLearningFocus(LearningFocus(kind: .source, id: source.id!, title: "焦点书"))
            let store = LibraryStore(db: db)
            XCTAssertNil(store.learningFocus, "旧的本期焦点不再生效")
            XCTAssertTrue(store.focusHighlightIDs.isEmpty)
            XCTAssertTrue(store.focusDeckCounts.isEmpty)
            XCTAssertNil(store.currentProjectID)
            XCTAssertNotNil(try db.validatedLearningFocus(), "存着的设定不动")
        }
    }
}
