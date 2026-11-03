import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.6：导入 KongFolio 的阅读材料——读 catalog.json 与导出的 Markdown、摘录与札记的对应、重复导入、更新、删去的不加回、出题
final class V606KongFolioTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 3; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: t0)! }

    /// KongFolio 的 JSONEncoder 默认把日期写成自 2001-01-01 起的秒数
    private func ref(_ date: Date) -> String { String(date.timeIntervalSinceReferenceDate) }

    private func excerpt(id: String, quote: String, modified: Date) -> String {
        """
        {"id":"\(id)","kind":"摘录","title":"","quote":"\(quote)","note":"**按**：习是温习","originalQuote":"\(quote)",
         "citations":[{"source":{"path":"/书/论语译注.pdf","fileName":"论语译注.pdf","page":0,"pageLabel":"1","rects":[[[10,20],[30,40]]]},"title":"论语译注","author":"杨伯峻"}],
         "linkedRecords":[],"tags":["论语"],"created":\(ref(d(-3))),"modified":\(ref(modified)),"wholeBook":false}
        """
    }

    private func catalog(quote: String = "学而时习之，不亦说乎", modified: Date? = nil) -> Data {
        let m = modified ?? d(-3)
        return Data("""
        {"version":1,"lastNotes":{},
         "records":[
          \(excerpt(id: "A1", quote: quote, modified: m)),
          {"id":"B2","kind":"图片摘录","title":"","quote":"","note":"","imageAsset":"b2.png","citations":[],"linkedRecords":[],"tags":[],"created":\(ref(d(-3))),"modified":\(ref(d(-3)))},
          {"id":"C3","kind":"图片摘录","title":"","quote":"仁者爱人","note":"","imageAsset":"c3.png",
           "citations":[{"source":{"path":"/书/孟子.pdf","fileName":"孟子.pdf","page":4,"rects":[]},"title":"孟子","author":""}],
           "linkedRecords":[],"tags":[],"created":\(ref(d(-3))),"modified":\(ref(d(-3)))},
          {"id":"D4","kind":"笔记","title":"","quote":"有朋自远方来","note":"朋指同门。\\n第二行",
           "citations":[{"source":{"path":"/书/论语译注.pdf","fileName":"论语译注.pdf","page":1,"pageLabel":"2","rects":[]},"title":"论语译注","author":"杨伯峻"}],
           "linkedRecords":[],"tags":[],"created":\(ref(d(-2))),"modified":\(ref(d(-2)))},
          {"id":"E5","kind":"摘录","title":"","quote":"已移到最近删除","note":"","citations":[],"linkedRecords":[],"tags":[],
           "created":\(ref(d(-2))),"modified":\(ref(d(-2))),"removed":\(ref(d(-1)))},
          {"id":"F6","kind":"笔记","title":"整本书心得","quote":"","note":"这本书讲士。","wholeBook":true,
           "citations":[{"source":{"path":"","fileName":"国史大纲.pdf","page":0,"rects":[]},"title":"国史大纲","author":"钱穆"}],
           "linkedRecords":[],"tags":[],"created":\(ref(d(-2))),"modified":\(ref(d(-2)))}
         ],
         "essays":[
          {"id":"G7","title":"学而为己","tags":[],"created":\(ref(d(-1))),"modified":\(ref(d(-1))),
           "blocks":[{"id":"b1","text":"","record":\(excerpt(id: "A1", quote: "学而时习之，不亦说乎", modified: d(-3)))},
                     {"id":"b2","text":"学习是为了**成就自己**。"}]},
          {"id":"I9","title":"# kongreview","tags":[],"created":\(ref(d(-1))),"modified":\(ref(d(-1))),"blocks":[{"id":"b4","text":"1 窗口拖动"}]},
          {"id":"H8","title":"未命名札记","tags":[],"created":\(ref(d(-1))),"modified":\(ref(d(-1))),"blocks":[{"id":"b3","text":""}]}
         ]}
        """.utf8)
    }

    func testConvertCatalog() throws {
        let r = KongFolioConverter.convert(try KongFolioCatalog.decode(catalog()))
        XCTAssertEqual(r.entries.map(\.key), ["record:A1", "record:C3", "record:D4", "record:F6", "essay:G7", "essay:I9"])
        XCTAssertEqual(r.entries.last?.title, "kongreview", "题目去掉 Markdown 标题记号")
        XCTAssertEqual(r.skippedEmpty, 2, "没有文字的图片摘录、空白札记")
        XCTAssertEqual(r.skippedRemoved, 1)
        let a = r.entries[0]
        XCTAssertEqual(a.kind, .highlight)
        XCTAssertEqual(a.text, "学而时习之，不亦说乎")
        XCTAssertEqual(a.sourceTitle, "论语译注"); XCTAssertEqual(a.sourceAuthor, "杨伯峻")
        XCTAssertEqual(a.location, "第 1 页", "有印刷页码用印刷页码")
        XCTAssertEqual(a.tags, ["论语", "KongFolio"])
        XCTAssertTrue(a.html.contains("<strong>按</strong>"), "我的笔记作按语，Markdown 转 HTML")
        XCTAssertEqual(abs(a.created.timeIntervalSince(d(-3))), 0, accuracy: 0.001)
        XCTAssertEqual(r.entries[1].location, "第 5 页", "没有印刷页码用 PDF 页序")
        let note = r.entries[2]
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.title, "朋指同门。")
        XCTAssertTrue(note.html.contains("<blockquote>") && note.html.contains("有朋自远方来") && note.html.contains("杨伯峻：《论语译注》，第 2 页"))
        XCTAssertEqual(note.quotes.map(\.key), ["record:D4#quote"])
        XCTAssertEqual(note.quotes.first?.html, "", "笔记的原文不再带按语")
        XCTAssertEqual(r.entries[3].title, "读《国史大纲》", "整本书心得以书名作题")
        let essay = r.entries[4]
        XCTAssertEqual(essay.title, "学而为己")
        XCTAssertEqual(essay.quotes.map(\.key), ["record:A1"], "札记引用的摘录与阅读记录里的同一条共用来源键")
        XCTAssertTrue(essay.html.contains("<strong>成就自己</strong>"))
    }

    func testImportReimportUpdateAndDeleted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try db.importKongFolio(KongFolioConverter.convert(try KongFolioCatalog.decode(catalog())), now: t0)
        XCTAssertEqual(first.newHighlights, 3, "A1、C3、D4 的原文")
        XCTAssertEqual(first.newNotes, 4, "D4、F6、G7、I9")
        XCTAssertEqual(first.sources, ["论语译注", "孟子"])
        XCTAssertEqual(first.skippedEmpty, 2); XCTAssertEqual(first.skippedRemoved, 1)
        XCTAssertEqual(try db.kongFolioCounts().highlights, 3)
        XCTAssertEqual(try db.kongFolioCounts().notes, 4)

        let all = try db.highlights(tag: nil)
        let a = try XCTUnwrap(all.first { $0.text == "学而时习之，不亦说乎" })
        XCTAssertEqual(a.location, "第 1 页")
        XCTAssertEqual(a.tags, ["论语", "KongFolio"])
        XCTAssertEqual(a.note?.contains("习是温习"), true)
        let src = try XCTUnwrap(try db.allSources().first { $0.id == a.sourceId })
        XCTAssertEqual(src.title, "论语译注"); XCTAssertEqual(src.author, "杨伯峻")
        let essayId = try XCTUnwrap(try db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM idea_note WHERE title = '学而为己'") })
        let linked = try db.writer.read { try Int64.fetchAll($0, sql: "SELECT highlightId FROM idea_note_highlight WHERE noteId = ?", arguments: [essayId]) }
        XCTAssertEqual(linked, [a.id!], "札记挂上引用的摘录，不另建一条")

        // 再导入一次：没有新的
        let again = try db.importKongFolio(KongFolioConverter.convert(try KongFolioCatalog.decode(catalog())), now: d(1))
        XCTAssertEqual(again.added, 0); XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(try db.highlights(tag: nil).count, 3)

        // KongFolio 里改了 A1：更新原文，不新增
        let changed = try db.importKongFolio(KongFolioConverter.convert(try KongFolioCatalog.decode(catalog(quote: "学而时习之，不亦说乎？", modified: d(1)))), now: d(2))
        XCTAssertEqual(changed.updated, 1); XCTAssertEqual(changed.added, 0)
        XCTAssertEqual(try db.highlights(ids: [a.id!]).first?.text, "学而时习之，不亦说乎？")

        // 在 KongReview 里删去 C3：不再加回来
        let c3 = try XCTUnwrap(try db.highlights(tag: nil).first { $0.text == "仁者爱人" })
        try db.moveToTrash(c3, now: d(2))
        let afterDelete = try db.importKongFolio(KongFolioConverter.convert(try KongFolioCatalog.decode(catalog(quote: "学而时习之，不亦说乎？", modified: d(1)))), now: d(3))
        XCTAssertEqual(afterDelete.skippedDeleted, 1)
        XCTAssertEqual(afterDelete.added, 0)
        XCTAssertTrue(afterDelete.summary.contains("已在 KongReview 里删去"))
    }

    func testImportedMaterialsEnterTheExam() throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.importKongFolio(KongFolioConverter.convert(try KongFolioCatalog.decode(catalog())), now: t0)
        let candidates = try db.reviewCandidates(tag: nil).highlights.map(\.text)
        XCTAssertTrue(candidates.contains("学而时习之，不亦说乎"), "摘录进入每天抽题的范围")
        let noteIDs = try db.writer.read { try Int64.fetchAll($0, sql: "SELECT targetId FROM kongfolio_item WHERE targetKind = 'note'") }
        XCTAssertTrue(try db.revisitQueue(limits: RevisitLimits(notes: 5, questions: 0, books: 0, blocks: 0), now: d(6)).notes.isEmpty, "新札记 7 天后才出论证题")
        let due = try db.revisitQueue(limits: RevisitLimits(notes: 5, questions: 0, books: 0, blocks: 0), now: d(7)).notes.map(\.id)
        XCTAssertEqual(Set(due), Set(noteIDs))
    }

    func testMarkdownExport() throws {
        let md = """
        # 读书记录

        ## 学而篇

        > 学而时习之，不亦说乎

        我的笔记：

        习是温习。

        杨伯峻：《论语译注》，第 1 页
        [返回原文](file:///书/论语译注.pdf#page=1)

        标签：论语

        ## 一点想法

        士当以天下为己任\\*。

        ## 空的

        """
        let r = KongFolioConverter.convertMarkdown(md)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.skippedEmpty, 1)
        let h = r.entries[0]
        XCTAssertEqual(h.kind, .highlight)
        XCTAssertEqual(h.text, "学而时习之，不亦说乎")
        XCTAssertEqual(h.sourceTitle, "论语译注"); XCTAssertEqual(h.sourceAuthor, "杨伯峻")
        XCTAssertEqual(h.location, "第 1 页")
        XCTAssertEqual(h.tags, ["论语", "KongFolio"])
        XCTAssertTrue(h.html.contains("习是温习"))
        XCTAssertFalse(h.html.contains("返回原文"))
        XCTAssertEqual(r.entries[1].kind, .note)
        XCTAssertEqual(r.entries[1].title, "一点想法")
        XCTAssertTrue(r.entries[1].appendOnly)

        let db = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(try db.importKongFolio(r, now: t0).added, 2)
        XCTAssertEqual(try db.importKongFolio(KongFolioConverter.convertMarkdown(md), now: d(1)).added, 0, "同一文件导入两次不重复")
    }

    func testReadFilesAndStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("catalog.json")
        try catalog().write(to: json)
        XCTAssertEqual(try KongFolioConverter.read(json).entries.count, 6)
        XCTAssertThrowsError(try KongFolioConverter.read(dir.appendingPathComponent("没有.json"))) { e in
            if case .missing = e as? KongFolioImportError {} else { XCTFail("应提示没有找到") }
        }
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{\"hello\":1}".utf8).write(to: bad)
        XCTAssertThrowsError(try KongFolioConverter.read(bad)) { XCTAssertEqual($0 as? KongFolioImportError, .notCatalog) }
        XCTAssertNotNil(KongFolioSettings.signature(json))
        XCTAssertNil(KongFolioSettings.signature(dir.appendingPathComponent("没有.json")))

        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            let r = try XCTUnwrap(store.importKongFolio(try KongFolioConverter.read(json), quiet: true))
            XCTAssertEqual(r.added, 7)
            XCTAssertEqual(store.infoMessage, r.summary, "有新内容时提示")
            XCTAssertTrue(store.kongFolioLast.contains("从 KongFolio 导入"))
            XCTAssertEqual(store.sources.count, 2, "导入后刷新出处列表")
            store.infoMessage = nil
            _ = store.importKongFolio(try KongFolioConverter.read(json), quiet: true)
            XCTAssertNil(store.infoMessage, "自动导入没有新内容时不打扰")
        }
        UserDefaults.standard.removeObject(forKey: KongFolioSettings.lastReportKey)
    }
}
