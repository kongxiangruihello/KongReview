import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.4.0：问题簿、专题笔记本并入札记
final class V640NotesMergeTests: XCTestCase {
    private let t0 = Calendar.current.date(byAdding: .hour, value: 9, to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!
    private func d(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: t0)! }

    override func setUp() { super.setUp(); NotesMergeSwitch.onOpen = true }
    override func tearDown() { NotesMergeSwitch.onOpen = false; super.tearDown() }

    private func notes(_ db: AppDatabase) throws -> [IdeaNote] {
        try db.writer.read { try IdeaNote.fetchAll($0, sql: "SELECT * FROM idea_note ORDER BY id") }
    }
    private func note(_ db: AppDatabase, titled title: String) throws -> IdeaNote {
        try XCTUnwrap(try notes(db).first { $0.title == title }, "应有札记“\(title)”")
    }
    private func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
    private func highlightIDs(_ db: AppDatabase, _ noteId: Int64) throws -> [Int64] {
        try db.writer.read { try Int64.fetchAll($0, sql: "SELECT highlightId FROM idea_note_highlight WHERE noteId = ? ORDER BY position", arguments: [noteId]) }
    }
    private func dueDay(_ db: AppDatabase, _ noteId: Int64) throws -> String? {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT dueDay FROM idea_note_review WHERE noteId = ?", arguments: [noteId]) }
    }

    func testEmptyLibraryMergesNothing() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(try db.mergeIntoIdeaNotes(now: t0), NotesMergeResult())
        XCTAssertEqual(try notes(db).count, 0)
        XCTAssertEqual(try db.notesMergeTotals().questions, 0)
    }

    func testNotebookWithoutHeadingsBecomesOneNote() throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "论语译注", author: "杨伯峻"))
        let h = try db.save(Highlight(sourceId: source.id, text: "士不可以不弘毅", location: "第 80 页"))
        let nb = try db.createNotebook(title: "何以为士", now: t0)
        _ = try db.insertBlocks([
            NotebookBlock(notebookId: nb.id!, position: 1, kind: .text, text: "士之为士，先在其志。"),
            NotebookBlock(notebookId: nb.id!, position: 2, kind: .highlight, highlightId: h.id, text: h.text, note: "弘言其量。"),
        ], into: nb.id!, after: nil, now: t0)

        let result = try db.mergeIntoIdeaNotes(now: d(1))
        XCTAssertEqual(result, NotesMergeResult(questions: 0, notebooks: 1, notes: 1))
        let n = try note(db, titled: "何以为士")
        XCTAssertTrue(n.body.contains("士之为士，先在其志。"))
        XCTAssertTrue(n.body.contains("<blockquote>"), "摘录块写成引文")
        XCTAssertTrue(n.body.contains("士不可以不弘毅"))
        XCTAssertTrue(n.body.contains("——杨伯峻 《论语译注》 第 80 页"))
        XCTAssertTrue(n.body.contains("弘言其量。"), "本文批注跟在引文后面")
        XCTAssertLessThan(try XCTUnwrap(n.body.range(of: "先在其志")).lowerBound, try XCTUnwrap(n.body.range(of: "<blockquote>")).lowerBound, "顺序照原来的")
        XCTAssertEqual(try highlightIDs(db, n.id!), [h.id!], "摘录成为札记引用的摘录")
        // 原表清空，归档表里有原来的行
        XCTAssertEqual(try count(db, "notebook"), 0)
        XCTAssertEqual(try count(db, "notebook_block"), 0)
        XCTAssertEqual(try count(db, "merged_notebook"), 1)
        XCTAssertEqual(try count(db, "merged_notebook_block"), 2)
        XCTAssertEqual(try db.notesMergeTotals().notebooks, 1)
        XCTAssertEqual(try db.ideaNoteOriginKind(noteId: n.id!), "notebook")
        // 再合并一次什么也不做
        XCTAssertEqual(try db.mergeIntoIdeaNotes(now: d(2)), NotesMergeResult())
        XCTAssertEqual(try notes(db).count, 1)
    }

    func testNotebookWithHeadingsSplitsIntoSectionsAndIndex() throws {
        let db = try AppDatabase(DatabaseQueue())
        let nb = try db.createNotebook(title: "清学札记", now: t0)
        _ = try db.insertBlocks([
            NotebookBlock(notebookId: nb.id!, position: 1, kind: .text, text: "这一本的前言。"),
            NotebookBlock(notebookId: nb.id!, position: 2, kind: .heading, text: "一、考据"),
            NotebookBlock(notebookId: nb.id!, position: 3, kind: .text, text: "考据之学，起于明末。"),
            NotebookBlock(notebookId: nb.id!, position: 4, kind: .text, text: "## 二、义理"),
            NotebookBlock(notebookId: nb.id!, position: 5, kind: .text, text: "义理不离考据。"),
            NotebookBlock(notebookId: nb.id!, position: 6, kind: .heading, text: "三、空的一节"),
        ], into: nb.id!, after: nil, now: t0)

        let result = try db.mergeIntoIdeaNotes(now: d(1))
        XCTAssertEqual(result, NotesMergeResult(questions: 0, notebooks: 1, notes: 3), "两节各一条，加目次")
        let first = try note(db, titled: "清学札记·一、考据")
        XCTAssertTrue(first.body.contains("考据之学，起于明末。"))
        let second = try note(db, titled: "清学札记·二、义理")
        XCTAssertTrue(second.body.contains("义理不离考据。"), "只写了一个标题的文字块也当小标题")
        let index = try note(db, titled: "清学札记")
        XCTAssertTrue(index.body.contains("这一本的前言。"))
        XCTAssertTrue(index.body.contains("[[清学札记·一、考据]]"))
        XCTAssertTrue(index.body.contains("[[清学札记·二、义理]]"))
        XCTAssertTrue(index.body.contains("三、空的一节"), "没有内容的小标题只列在目次里")
        XCTAssertLessThan(try XCTUnwrap(index.body.range(of: "一、考据")).lowerBound, try XCTUnwrap(index.body.range(of: "二、义理")).lowerBound)
        // 目次链接到各节；目次不出论证题
        let links = try db.writer.read { try Int64.fetchAll($0, sql: "SELECT toId FROM idea_note_link WHERE fromId = ? ORDER BY toId", arguments: [index.id!]) }
        XCTAssertEqual(Set(links), [first.id!, second.id!])
        XCTAssertEqual(try dueDay(db, index.id!), "9999-12-31")
        let queue = try db.revisitQueue(limits: RevisitLimits(notes: 10, questions: 5, books: 0, blocks: 5, answers: 5), now: d(400))
        XCTAssertFalse(queue.notes.map(\.id).contains(index.id!))
        XCTAssertTrue(queue.notes.map(\.id).contains(first.id!))
        XCTAssertTrue(queue.blocks.isEmpty, "不再出复述题")
    }

    func testQuestionBecomesNoteWithAnswerMaterialsAndSchedule() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h1 = try db.save(Highlight(text: "任重而道远"))
        let h2 = try db.save(Highlight(text: "士志于道"))
        let existing = try db.createIdeaNote(title: "士由身份转为德行", body: "<p>旧札记。</p>", now: t0)
        let nb = try db.createNotebook(title: "何以为士", now: t0)

        let open = try db.createQuestion(title: "“士志于道”与“弘毅”能否互证？", detail: "<p>先看朱注。</p>", scopes: [(.notebook, nb.id!)], now: t0)
        try db.setQuestionPinned(id: open.id!, true)
        try db.addQuestionMaterial(questionId: open.id!, kind: .highlight, recordId: h1.id!, reason: "担当之义", now: t0)
        try db.addQuestionMaterial(questionId: open.id!, kind: .highlight, recordId: h2.id!, now: t0)
        try db.addQuestionMaterial(questionId: open.id!, kind: .note, recordId: existing.id!, now: t0)
        let solved = try db.createQuestion(title: "孔门之士是否已脱离等级含义？", now: t0)
        try db.saveQuestion(id: solved.id!, title: solved.title, detail: "", answer: "<p>已成自我期许。</p>", now: t0)
        try db.setQuestionStatus(id: solved.id!, .solved, now: t0)
        let shelved = try db.createQuestion(title: "士与君子如何分用？", now: t0)
        try db.setQuestionStatus(id: shelved.id!, .shelved, now: t0)
        // 与已有札记同名的问题
        let clash = try db.createQuestion(title: "士由身份转为德行", now: t0)
        try db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO question_review(questionId, dueDay) VALUES (?, ?)", arguments: [open.id!, AppDatabase.revisitDay(self.d(3))])
            try d.execute(sql: "INSERT OR REPLACE INTO question_answer_review(questionId, dueDay, intervalDays, reviewCount) VALUES (?, ?, 21, 2)",
                          arguments: [solved.id!, AppDatabase.revisitDay(self.d(5))])
        }

        let result = try db.mergeIntoIdeaNotes(now: d(1))
        XCTAssertEqual(result.questions, 4)
        XCTAssertEqual(result.notebooks, 1)
        XCTAssertEqual(try count(db, "question"), 0)
        XCTAssertEqual(try count(db, "question_material"), 0)
        XCTAssertEqual(try count(db, "merged_question"), 4)
        XCTAssertEqual(try count(db, "merged_question_material"), 3)

        let a = try note(db, titled: "“士志于道”与“弘毅”能否互证？")
        XCTAssertTrue(a.body.contains("状态：待研究；常念") || a.body.contains("状态：有线索；常念"))
        XCTAssertTrue(a.body.contains("先看朱注。"))
        XCTAssertTrue(a.body.contains("担当之义"), "写了缘由的材料列在正文里")
        XCTAssertTrue(a.body.contains("[[士由身份转为德行]]"), "挂着的札记写成链接")
        XCTAssertTrue(a.body.contains("原归入：[[何以为士]]"))
        XCTAssertEqual(try highlightIDs(db, a.id!), [h1.id!, h2.id!])
        XCTAssertEqual(try dueDay(db, a.id!), AppDatabase.revisitDay(d(3)), "沿用进展题的到期日")
        XCTAssertEqual(try db.ideaNoteOriginKind(noteId: a.id!), "question")
        XCTAssertEqual(a.createdAt.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1)

        let b = try note(db, titled: "孔门之士是否已脱离等级含义？")
        XCTAssertTrue(b.body.contains("<h2>解答</h2>"))
        XCTAssertTrue(b.body.contains("已成自我期许。"))
        XCTAssertEqual(try dueDay(db, b.id!), AppDatabase.revisitDay(d(5)), "沿用解答题的到期日")
        let interval = try db.writer.read { try Int.fetchOne($0, sql: "SELECT intervalDays FROM idea_note_review WHERE noteId = ?", arguments: [b.id!]) }
        XCTAssertEqual(interval, 21)

        let c = try note(db, titled: "士与君子如何分用？")
        XCTAssertEqual(try dueDay(db, c.id!), AppDatabase.revisitDay(d(366)), "搁置的一年后再说")

        XCTAssertNoThrow(try note(db, titled: "士由身份转为德行（2）"), "与已有札记同名的加序号")
        XCTAssertEqual(try db.ideaNote(id: existing.id!)?.body, "<p>旧札记。</p>", "原有札记不动")
        _ = clash

        // 日课上只出论证题
        let queue = try db.revisitQueue(limits: RevisitLimits(notes: 10, questions: 5, books: 0, blocks: 5, answers: 5), now: d(6))
        XCTAssertTrue(queue.questions.isEmpty)
        XCTAssertTrue(queue.answers.isEmpty)
        XCTAssertTrue(queue.notes.map(\.id).contains(a.id!))
        XCTAssertTrue(queue.notes.map(\.id).contains(b.id!))
        XCTAssertFalse(queue.notes.map(\.id).contains(c.id!))
    }

    func testReopeningALibraryWithLeftoversMergesThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kr-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("library.sqlite").path
        do {
            let db = try AppDatabase(DatabaseQueue(path: path))
            _ = try db.createQuestion(title: "后来又写进来的问题", now: t0)
            XCTAssertEqual(try count(db, "question"), 1)
        }
        let reopened = try AppDatabase(DatabaseQueue(path: path))
        XCTAssertEqual(try count(reopened, "question"), 0, "打开库时并入")
        XCTAssertNoThrow(try note(reopened, titled: "后来又写进来的问题"))
    }

    func testMergedNotesPerDayIsTheSumOfTheFourOldLimits() throws {
        let suite = "kr-merge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LibraryStore.mergedNotesPerDay(defaults), 8, "默认各 2 道")
        defaults.set(10, forKey: RevisitLimits.notesKey)
        defaults.set(10, forKey: RevisitLimits.questionsKey)
        defaults.set(0, forKey: RevisitLimits.answersKey)
        defaults.set(5, forKey: RevisitLimits.blocksKey)
        XCTAssertEqual(LibraryStore.mergedNotesPerDay(defaults), 20, "至多 20")
        defaults.set(3, forKey: RevisitLimits.notesKey)
        defaults.set(0, forKey: RevisitLimits.questionsKey)
        XCTAssertEqual(LibraryStore.mergedNotesPerDay(defaults), 8)
        defaults.set(15, forKey: RevisitLimits.notesKey)
        XCTAssertEqual(RevisitLimits.saved(defaults).notes, 15, "札记每天至多 20 道")
    }
}
