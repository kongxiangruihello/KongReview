import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.7：卷尾再考、每天的时长、常错的题一键处理、录入预设的起始内容（HTML）
final class V607RelearnTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [LibraryStore.examRelearnKey, ExamSettings.minutesKey, ReviewSessionRecord.key(theme: nil), SettingsKeys.dailyCount]

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testRelearnStateRounds() {
        var s = ExamRelearnState(day: "2026-11-03")
        s.add(.highlight, 1); s.add(.highlight, 1); s.add(.note, 2)
        XCTAssertEqual(s.items.count, 2, "同一道只排一次")
        s.answer(ExamRelearnItem(kind: .highlight, id: 1), passed: false)
        XCTAssertEqual(s.items.map(\.id), [2, 1], "没过的排到队尾")
        XCTAssertEqual(s.items.last?.rounds, 1)
        s.answer(ExamRelearnItem(kind: .note, id: 2), passed: true)
        XCTAssertEqual(s.passed, 1)
        s.answer(ExamRelearnItem(kind: .highlight, id: 1), passed: false)
        XCTAssertTrue(s.items.isEmpty, "至多再考两轮")
        XCTAssertEqual(s.failed, 1)
    }

    func testBudgetPlanPriority() {
        let totals: [ExamKind: Int] = [.highlight: 10, .card: 20, .note: 2, .block: 2, .question: 1]
        let b = ExamBudget.plan(minutes: 10, totals: totals, retests: 2, day: "d")
        // 600 秒：补考 2×30 → 记忆卡 20×20 → 札记 2×60 → 剩 20 秒
        XCTAssertEqual(b.cap(.highlight), 2, "补考的摘录排最前，其余摘录排最后")
        XCTAssertEqual(b.cap(.card), 20)
        XCTAssertEqual(b.cap(.note), 2)
        XCTAssertEqual(b.cap(.block), 0)
        XCTAssertEqual(b.cap(.question), 0)
        let all = ExamBudget.plan(minutes: 120, totals: totals, retests: 2, day: "d")
        XCTAssertEqual(ExamKind.allCases.map { all.cap($0) ?? -1 }, [20, 10, 2, 2, 1], "够长就全出")
        XCTAssertEqual(ExamBudget.plan(minutes: 0, totals: totals, retests: 0, day: "d").caps.values.reduce(0, +), 0)
        XCTAssertEqual(ExamSettings.minutes(), 0, "默认不限时长")
    }

    func testRelearnInStore() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注"))
            for i in 0..<4 { _ = try db.save(Highlight(sourceId: src.id, text: "第 \(i) 条：温故而知新", location: "第\(i)页")) }
            let note = try db.createIdeaNote(title: "士以道自任", body: "<p>依据</p>")
            let store = LibraryStore(db: db)
            let paper = store.examPaper()
            let h = try XCTUnwrap(paper.highlights.first)
            store.examAnswerHighlight(h, mode: .gist, result: .forgot)
            XCTAssertEqual(store.examRelearn.items, [ExamRelearnItem(kind: .highlight, id: h.id!)], "忘了的进卷尾再考")
            store.examAnswerHighlight(paper.highlights[1], mode: .gist, result: .remembered)
            XCTAssertEqual(store.examRelearn.items.count, 1, "记得的不进")
            store.examAnswerNote(RevisitNoteItem(id: note.id!, title: note.title, body: note.body, highlights: [], intervalDays: 0, reviewCount: 0,
                                                 lastReviewedAt: nil, createdAt: Date(), updatedAt: Date()), result: .forgot, outcome: .later)
            XCTAssertEqual(store.examRelearn.items.last, ExamRelearnItem(kind: .note, id: note.id!))
            let tallyBefore = try db.examTally()

            let next = try XCTUnwrap(store.examRelearnNext())
            XCTAssertEqual(next.0.id, h.id, "按放进去的先后出")
            if case .highlight(let again, _) = next.1 { XCTAssertEqual(again.id, h.id) } else { XCTFail("应是摘录题") }
            store.examRelearnAnswer(next.0, passed: true)
            XCTAssertEqual(store.examRelearn.passed, 1)
            XCTAssertEqual(try db.examTally(), tallyBefore, "卷尾再考不记入掌握度")
            let n = try XCTUnwrap(store.examRelearnNext())
            if case .note(let item) = n.1 { XCTAssertEqual(item.title, "士以道自任") } else { XCTFail("应是论证题") }

            // 删去的摘录跳过
            store.examRelearnAdd(.highlight, paper.highlights[2].id!)
            store.examRelearnAnswer(n.0, passed: true)
            try db.moveToTrash(paper.highlights[2])
            XCTAssertNil(store.examRelearnNext())
            XCTAssertTrue(store.examRelearn.items.isEmpty)
        }
    }

    func testBudgetTrimsPaper() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注"))
            for i in 0..<12 { _ = try db.save(Highlight(sourceId: src.id, text: "第 \(i) 条：学而时习之", location: "第\(i)页")) }
            UserDefaults.standard.set(10, forKey: SettingsKeys.dailyCount)
            let store = LibraryStore(db: db)
            XCTAssertNil(store.examBudget(), "没设时长")
            XCTAssertEqual(store.examPaper().highlights.count, 10)
            UserDefaults.standard.set(1, forKey: ExamSettings.minutesKey)   // 60 秒：两道摘录
            store.examResetBudget()
            let paper = store.examPaper()
            XCTAssertEqual(paper.highlights.count, 2)
            XCTAssertEqual(paper.deferred, 8, "其余顺延到明天")
            XCTAssertEqual(store.dailyCheckCounts()[.review]?.left, 2, "应做按分到的题数")
            store.examExtendBudget(by: 1)
            XCTAssertEqual(store.examPaper().highlights.count, 4, "再考一会儿")
            try? db.deleteProgress(key: LibraryStore.examBudgetKey(AppDatabase.revisitDay(Date())))
        }
    }

    func testPresetStartHTML() throws {
        let preset = CardEntryPreset(name: "名词解释",
                                     frontRule: .init(hint: "写概念", required: true),
                                     backRule: .init(hint: "先概括", required: true, html: "<p><b>定义：</b></p><ul><li></li></ul>"))
        var draft = try preset.blankDraft(templates: [:])
        XCTAssertEqual(draft.card.front, "", "没设起始内容的栏目照旧空着")
        XCTAssertEqual(draft.card.back, "<p><b>定义：</b></p><ul><li></li></ul>", "起始内容先填进去")
        let g = try XCTUnwrap(draft.entryGuidance)
        XCTAssertFalse(g.hasInput(draft.card), "原样的起始内容不算填写")
        draft.card.front = "仁"
        XCTAssertEqual(draft.entryValidationIssues(templates: [:]).map(\.key), ["back"], "必填的背面还是原样，仍要填")
        draft.card.back = "<p><strong>定义：</strong></p><ul><li>爱人</li></ul>"
        XCTAssertTrue(draft.entryValidationIssues(templates: [:]).isEmpty)
        XCTAssertTrue(g.hasInput(draft.card))
        // 编辑器改了标签写法、文字没变，仍算原样
        XCTAssertTrue(preset.backRule!.isUntouchedStart("<p><strong>定义：</strong></p><ul><li><br></li></ul>"))
        XCTAssertFalse(preset.backRule!.isUntouchedStart("<p><b>定义：</b></p><img src='a.png'>"), "加了图片就不是原样")

        // 导出导入带着起始内容
        let back = try CardEntryPresetTransfer.decode(CardEntryPresetTransfer.encode([preset]))
        XCTAssertEqual(back.first?.backRule?.html, preset.backRule?.html)

        // 保存并新增：下一张也先填上
        let saved = draft.card
        var next = Card(deck: saved.deck, front: "")
        next.sections = nil
        XCTAssertEqual(g.prefilled(next).back, "<p><b>定义：</b></p><ul><li></li></ul>")
        var typed = next; typed.back = "已有内容"
        XCTAssertEqual(g.prefilled(typed).back, "已有内容", "有内容的不覆盖")
    }
}
