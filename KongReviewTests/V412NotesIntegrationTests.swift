import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.1.2：笔记本中的札记块、札记写到 Obsidian、[[ 候选、旧版完整备份可恢复
final class V412NotesIntegrationTests: XCTestCase {
    func testNotebookNoteBlockExportCitationsAndPurge() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注", author: "杨伯峻"))
            var h = Highlight(text: "士不可以不弘毅，任重而道远"); h.sourceId = src.id; h.location = "第 80 页"
            h = try db.save(h)
            let bare = try db.save(Highlight(text: "无出处的摘录"))
            let other = try db.createIdeaNote(title: "弘毅", body: "")
            let note = try db.createIdeaNote(title: "士之可贵在于自立", body: "<p>参见 [[弘毅|弘毅之说]]。</p><p>第二段</p>",
                                             highlightIDs: [h.id!, bare.id!])
            let n = try db.createNotebook(title: "何以为士")
            let writingBefore = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(added), 0) FROM writing_log WHERE notebookId = ?", arguments: [n.id!]) }
            let store = LibraryStore(db: db)
            store.loadNotebook(n.id!)
            store.insertNotebookIdeaNote(note.id!, after: nil)
            XCTAssertEqual(store.notebookState.blocks.map(\.kind), [.note])
            XCTAssertEqual(store.notebookState.blocks.first?.text, note.body, "加入时的正文留作底稿")
            let writingAfter = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(added), 0) FROM writing_log WHERE notebookId = ?", arguments: [n.id!]) }
            XCTAssertEqual(writingAfter, writingBefore, "札记块不重复计入写作量")
            XCTAssertEqual(store.notebookState.quotedHighlightIDs, [h.id!, bare.id!])

            guard case .essay(let body, let cites)? = store.notebookPieces().first?.kind else { return XCTFail("札记块导出为札记段落") }
            XCTAssertFalse(body.contains("[["), "链接只留文字")
            XCTAssertTrue(body.contains("弘毅之说"))
            XCTAssertEqual(cites.count, 1, "有出处的摘录作脚注")
            XCTAssertTrue(cites[0].contains("论语译注"))
            let md = NotebookExporter.markdown(title: "何以为士", pieces: store.notebookPieces())
            XCTAssertTrue(md.contains("第二段[^1]"))
            let check = try XCTUnwrap(store.notebookCitationCheck(), "札记所引摘录也做引文核对")
            XCTAssertTrue(check.issues.contains { $0.highlightId == bare.id && $0.kind == .noSource })
            XCTAssertFalse(store.notebookBibliography().isEmpty, "参考文献含札记所引摘录的出处")

            XCTAssertEqual(try db.notebooksContaining(noteId: note.id!).map(\.id), [n.id])
            store.saveIdeaNote(id: note.id!, title: note.title, body: "<p>改过的正文</p>")
            XCTAssertEqual(store.notebookState.ideaNotes[note.id!]?.body, "<p>改过的正文</p>", "笔记本里的札记块随札记更新")
            try db.purgeIdeaNote(note.id!)
            store.loadNotebook(n.id!)
            XCTAssertNil(store.notebookState.blocks.first?.noteId, "札记彻底删除后块仍在")
            guard case .essay(let kept, _)? = store.notebookPieces().first?.kind else { return XCTFail() }
            XCTAssertTrue(kept.contains("弘毅之说"), "按加入时的正文导出")
            _ = other
        }
    }

    func testObsidianSyncWritesNotesAndCleansOnlyItsOwnFiles() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "士志于道"))
        let a = try db.createIdeaNote(title: "士由身份转为德行", body: "<p>见 [[漢學與宋學之爭]]</p>", highlightIDs: [h.id!])
        let b = try db.createIdeaNote(title: "汉学与宋学之争：一个误会", body: "")
        try db.saveIdeaNote(id: b.id!, title: "汉学与宋学之争", body: "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "我自己的笔记".write(to: dir.appendingPathComponent("手写.md"), atomically: true, encoding: .utf8)
        var report = ObsidianSync.Report()
        try ObsidianSync.syncIdeaNotes(db: db, to: dir, style: .footnote, report: &report)
        XCTAssertEqual(report.written, 2)
        let text = try String(contentsOf: dir.appendingPathComponent("士由身份转为德行.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("[[汉学与宋学之争|漢學與宋學之爭]]"), "繁简不同也指向对方的文件名")
        XCTAssertTrue(text.contains("> 士志于道"))
        try db.saveIdeaNote(id: a.id!, title: "士的自我期许", body: "")
        report = .init()
        try ObsidianSync.syncIdeaNotes(db: db, to: dir, style: .footnote, report: &report)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["士的自我期许.md", "汉学与宋学之争.md", "手写.md"], "改名后旧文件清理，自己写的文件不动")
        XCTAssertEqual(report.unchanged, 1)
    }

    func testWikiSuggestions() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let me = try db.createIdeaNote(title: "宋學方法")
            _ = try db.createIdeaNote(title: "汉学与宋学之争")
            _ = try db.createIdeaNote(title: "宋学源流")
            let store = LibraryStore(db: db)
            let s = store.wikiSuggestions("宋學", excluding: me.id)
            XCTAssertEqual(s.map(\.t), ["宋学源流", "汉学与宋学之争", "宋學"], "以输入开头的在前；不含自己；末尾给出新题目")
            XCTAssertEqual(s.last?.h, "新题目，尚未建立")
            XCTAssertEqual(store.wikiSuggestions("宋学源流").map(\.t), ["宋学源流"], "已有同名时不给新题目")
            XCTAssertEqual(store.wikiSuggestions("").count, 3)
        }
    }

    func testFullBackupFromOlderVersionRestores() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let suite = UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let old = try AppDatabase(DatabaseQueue(), upTo: "v17-idea-notes")
        _ = try old.save(Highlight(text: "旧版备份里的摘录"))
        let n = try old.createNotebook(title: "旧专题")
        try old.saveProgress(TopicQuestion(notebookID: n.id!, question: "<p>旧版的专题问题</p>"), key: "topic-question.\(UUID().uuidString)")
        let backup = dir.appendingPathComponent("old.kongreviewbackup")
        try FullBackupService.create(db: old, draftURL: nil, defaults: prefs, destination: backup)
        let prepared = try FullBackupService.prepare(url: backup); defer { prepared.cleanup() }
        let current = try AppDatabase(DatabaseQueue())
        _ = try FullBackupService.restore(prepared, db: current, draftURL: nil, defaults: prefs, safetyDirectory: dir)
        XCTAssertEqual(try current.highlights(HighlightQuery(text: "")).map(\.text), ["旧版备份里的摘录"])
        XCTAssertEqual(try current.openQuestionCount(), 1, "恢复后专题问题转入问题簿")
        XCTAssertNil(try FullBackupService.backupMigrationTarget(current.migrationIdentifiers))
        XCTAssertEqual(try FullBackupService.backupMigrationTarget(["v1", "v2-soft-delete"]), "v2-soft-delete")
        XCTAssertThrowsError(try FullBackupService.backupMigrationTarget(current.migrationIdentifiers + ["v99-future"]), "更新版本的备份不支持")
        XCTAssertThrowsError(try FullBackupService.backupMigrationTarget(["v1", "v3-articles"]), "不成前缀的不支持")
    }
}
