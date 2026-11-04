import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.2：做题时随手记——当前这道题的出处与要挂上的摘录、随手札记的快捷键与备份
final class V620JotTests: XCTestCase {
    func testCaptureContextFollowsCurrentQuestion() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "国史大纲", author: "钱穆"))
            let h = try db.save(Highlight(sourceId: src.id, text: "对本国历史应略有所知", location: "引论"))
            let card = try db.save(Card(deck: "史学", front: "钱穆论国史", back: "温情与敬意", highlightId: h.id))
            let loose = try db.save(Card(deck: "史学", front: "没有摘录的卡", back: "答"))
            let store = LibraryStore(db: db)
            store.reload()

            let a = store.examCaptureContext(.highlight(h, .gist))
            XCTAssertEqual(a.highlight?.id, h.id)
            XCTAssertEqual(a.source?.title, "国史大纲")
            XCTAssertTrue(a.label.contains("对本国历史"))
            let b = store.examCaptureContext(.card(card))
            XCTAssertEqual(b.highlight?.id, h.id, "由摘录做的卡挂上原摘录")
            XCTAssertEqual(b.source?.author, "钱穆")
            let c = store.examCaptureContext(.card(loose))
            XCTAssertNil(c.highlight); XCTAssertNil(c.source)
            XCTAssertEqual(store.examCaptureContext(nil).label, "今日试卷")

            let composer = LibraryStore.examNoteComposer(a)
            XCTAssertEqual(composer.highlightID, h.id)
            XCTAssertEqual(composer.context, a.label)
            XCTAssertTrue(composer.highlightPreview.hasPrefix("对本国历史"))
            // 随手札记照常存进札记，挂上摘录
            let id = try XCTUnwrap(store.createIdeaNote(title: "钱穆的温情与敬意", highlightIDs: [composer.highlightID!]))
            XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM idea_note_highlight WHERE noteId = ?", arguments: [id]) }, 1)
        }
    }

    func testNoteHotKeyDefaultAndBackup() throws {
        let saved = UserDefaults.standard.object(forKey: HotKeyPreset.noteKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: HotKeyPreset.noteKey) } else { UserDefaults.standard.removeObject(forKey: HotKeyPreset.noteKey) } }
        UserDefaults.standard.removeObject(forKey: HotKeyPreset.noteKey)
        XCTAssertEqual(HotKeyPreset.note, .ctrlOptJ, "默认 ⌃⌥J")
        let suite = "kongreview.jot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HotKeyPreset.optCmdL.rawValue, forKey: HotKeyPreset.noteKey)
        XCTAssertEqual(try FullBackupService.settingsSnapshot(defaults)[HotKeyPreset.noteKey] as? String, "optCmdL", "完整备份带上")
        defaults.set("乱写", forKey: HotKeyPreset.noteKey)
        XCTAssertThrowsError(try FullBackupService.settingsSnapshot(defaults))
    }
}
