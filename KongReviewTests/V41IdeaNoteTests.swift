import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.1.0：札记——链接与反向链接、引用摘录、删除与恢复、写作量、项目、搜索、界面状态
final class V41IdeaNoteTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 21, hour: 12))! }
    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    func testLinksBacklinksUnresolvedAndRename() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.createIdeaNote(title: "  乾嘉考据并非一味反理学 ", body: "<p>参见 [[汉学与宋学之争]] 与 [[乾嘉考据并非一味反理学]]。</p>", now: day(-2))
        XCTAssertEqual(a.title, "乾嘉考据并非一味反理学", "题目去掉多余空白")
        var detail = try await db.ideaNoteDetail(id: a.id!)
        XCTAssertEqual(detail.unresolved, ["汉学与宋学之争"], "尚未建立的题目；指向自己的链接不算")
        XCTAssertTrue(detail.outgoing.isEmpty)

        let b = try db.createIdeaNote(title: "漢學與宋學之爭", now: day(-1))
        detail = try await db.ideaNoteDetail(id: a.id!)
        XCTAssertEqual(detail.outgoing.map(\.id), [b.id!], "新建后原先“未建”的链接自动接上，繁简归一")
        XCTAssertTrue(detail.unresolved.isEmpty)
        let backs = try await db.ideaNoteDetail(id: b.id!).backlinks
        XCTAssertEqual(backs.map(\.id), [a.id!])

        try db.saveIdeaNote(id: b.id!, title: "汉宋之争", body: "", now: now)
        let renamed = try XCTUnwrap(try db.ideaNote(id: a.id!))
        XCTAssertTrue(renamed.body.contains("[[汉宋之争]]"), "改题目时，指向它的链接一并改写")
        let afterRename = try await db.ideaNoteDetail(id: a.id!)
        XCTAssertEqual(afterRename.outgoing.map(\.title), ["汉宋之争"])
        XCTAssertThrowsError(try db.createIdeaNote(title: "   "))
        XCTAssertThrowsError(try db.saveIdeaNote(id: a.id!, title: "", body: ""))
    }

    func testCitationsDeletionAndRestore() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let h1 = try db.save(Highlight(text: "不知宋学，则亦不能知汉学"))
        let h2 = try db.save(Highlight(text: "理者，存乎欲者也"))
        let h3 = try db.save(Highlight(text: "已删除的摘录"))
        let note = try db.createIdeaNote(title: "观点", highlightIDs: [h1.id!], now: now)
        try db.addHighlights([h2.id!, h1.id!, h3.id!], toIdeaNote: note.id!)
        var d = try await db.ideaNoteDetail(id: note.id!)
        XCTAssertEqual(d.highlights.compactMap(\.id), [h1.id!, h2.id!, h3.id!], "按加入顺序，不重复")
        try db.reorderHighlights([h2.id!, h1.id!, h3.id!], inIdeaNote: note.id!)
        try db.moveToTrash(h3)
        d = try await db.ideaNoteDetail(id: note.id!)
        XCTAssertEqual(d.highlights.compactMap(\.id), [h2.id!, h1.id!], "调整顺序；已删除的摘录不显示")
        try db.removeHighlight(h2.id!, fromIdeaNote: note.id!)
        XCTAssertEqual(try db.ideaNotesCiting(highlightIDs: [h1.id!, h2.id!]).mapValues { $0.map(\.id) }, [h1.id!: [note.id!]])

        let linker = try db.createIdeaNote(title: "引用者", body: "[[观点]]")
        try db.setIdeaNoteDeleted(note.id!, deleted: true)
        let active = try await db.ideaNoteSummaries()
        XCTAssertEqual(active.map(\.id), [linker.id!])
        let deleted = try await db.ideaNoteSummaries(deleted: true)
        XCTAssertEqual(deleted.map(\.id), [note.id!])
        XCTAssertTrue(try db.ideaNotesCiting(highlightIDs: [h1.id!]).isEmpty, "已删除的札记不再提示")
        XCTAssertEqual(try db.ideaNoteCount(), 1)
        try db.setIdeaNoteDeleted(note.id!, deleted: false)
        let restored = try await db.ideaNoteDetail(id: note.id!)
        XCTAssertEqual(restored.backlinks.map(\.id), [linker.id!], "恢复后反向链接仍在")
        try db.purgeIdeaNote(note.id!)
        XCTAssertTrue(try db.ideaNotesCiting(highlightIDs: [h1.id!]).isEmpty)
        await XCTAssertThrowsErrorAsync(try await db.ideaNoteDetail(id: note.id!))
    }


    func testStoreComposerLinksAndNavigation() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let h = try db.save(Highlight(text: "学而时习之，不亦说乎", note: "<p>按：习，温习也。</p>"))
            let store = LibraryStore(db: db)
            store.developAnnotation(h)
            let composer = try XCTUnwrap(store.ideaNoteComposer)
            XCTAssertEqual(composer.highlightID, h.id)
            XCTAssertEqual(composer.body, "<p>按：习，温习也。</p>")
            XCTAssertTrue(composer.fromAnnotation)
            XCTAssertTrue(composer.highlightPreview.hasPrefix("学而时习之"))
            let id = try XCTUnwrap(store.createIdeaNote(title: "学与习之别", body: composer.body, highlightIDs: [h.id!]))
            XCTAssertEqual(store.ideaNoteCount, 1)
            XCTAssertEqual(store.ideaNotesCiting([h.id!])[h.id!]?.map(\.id), [id])
            XCTAssertEqual(h.note, try db.highlights(ids: [h.id!]).first?.note, "按语本身不变")

            XCTAssertTrue(store.openIdeaNoteLink(URL(string: "kongreview://note/\(id)")!))
            XCTAssertEqual(store.selection, .ideaNote(id))
            XCTAssertTrue(store.openIdeaNoteLink(URL(string: "kongreview://note-new?title=%E6%96%B0%E9%A2%98")!))
            XCTAssertEqual(store.ideaNoteCount, 2, "点“未建”的链接新建同名札记")
            if case .ideaNote(let created) = store.selection { XCTAssertNotEqual(created, id) } else { XCTFail("应打开新札记") }
            XCTAssertTrue(store.openIdeaNoteLink(URL(string: "kongreview://note-new?title=%E6%96%B0%E9%A2%98")!))
            XCTAssertEqual(store.ideaNoteCount, 2, "已有同名札记时直接打开，不重复新建")
            XCTAssertFalse(store.openIdeaNoteLink(URL(string: "https://example.com")!))
            store.setIdeaNoteDeleted(id, true)
            XCTAssertEqual(store.ideaNoteCount, 1)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("应当抛出错误", file: file, line: line) } catch {}
}
