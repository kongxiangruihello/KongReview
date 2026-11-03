import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.9：问题簿全部进考场——未解决的都出进展题、已解决的出解答题、搁置的不出
final class V609QuestionExamTests: XCTestCase {
    private let t0 = Calendar.current.date(byAdding: .hour, value: 9, to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private let lim = RevisitLimits(notes: 0, questions: 5, books: 0, blocks: 0, answers: 5)

    func testUnpinnedUnsolvedQuestionsComeWithGrowingIntervals() throws {
        let db = try AppDatabase(DatabaseQueue())
        let plain = try db.createQuestion(title: "没标常念的问题", now: t0)
        let pinned = try db.createQuestion(title: "常念的问题", now: t0)
        try db.setQuestionPinned(id: pinned.id!, true)
        let shelved = try db.createQuestion(title: "搁置的问题", now: t0)
        try db.setQuestionStatus(id: shelved.id!, .shelved, now: t0)

        _ = try db.revisitQueue(limits: lim, now: t0)
        let due = try db.writer.read { try String.fetchOne($0, sql: "SELECT dueDay FROM question_review WHERE questionId = ?", arguments: [plain.id!]) }
        let first = try XCTUnwrap(due)
        XCTAssertTrue(first > AppDatabase.revisitDay(t0) && first <= AppDatabase.revisitDay(t0, plus: 14), "没标常念的分散在两周内")
        let all = try db.revisitQueue(limits: lim, now: d(14)).questions.map(\.id)
        XCTAssertEqual(all, [pinned.id!, plain.id!], "常念的在前；搁置的不出")
        XCTAssertEqual(try db.revisitQueue(limits: RevisitLimits(notes: 0, questions: 1), now: d(14)).questions.map(\.id), [pinned.id!])

        // 没标常念的“还没有”：间隔加长（7 → 21 天）；常念的仍一周
        try db.recordQuestionRevisit(questionId: plain.id!, outcome: .notyet, now: d(14))
        try db.recordQuestionRevisit(questionId: pinned.id!, outcome: .notyet, now: d(14))
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(21)).questions.map(\.id), [pinned.id!])
        XCTAssertFalse(try db.revisitQueue(limits: lim, now: d(34)).questions.map(\.id).contains(plain.id!))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(35)).questions.map(\.id).contains(plain.id!), "间隔加长到 21 天")
        // 有新线索：一周后再来
        try db.recordQuestionRevisit(questionId: plain.id!, outcome: .lead, now: d(35))
        XCTAssertFalse(try db.revisitQueue(limits: lim, now: d(41)).questions.map(\.id).contains(plain.id!))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(42)).questions.map(\.id).contains(plain.id!))
    }

    func testSolvedQuestionsBecomeAnswerQuestions() throws {
        let db = try AppDatabase(DatabaseQueue())
        let q = try db.createQuestion(title: "“士志于道”何解？", now: t0)
        try db.saveQuestion(id: q.id!, title: q.title, detail: "", answer: "<p>以道为志，不以身份为限。</p>", now: t0)
        try db.setQuestionStatus(id: q.id!, .solved, now: t0)
        let noAnswer = try db.createQuestion(title: "只是问一问", now: t0)
        try db.setQuestionStatus(id: noAnswer.id!, .shelved, now: t0)

        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(6)).answers.isEmpty, "解决后 7 天才考")
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(7)).questions.isEmpty, "已解决的不出进展题")
        let item = try XCTUnwrap(try db.revisitQueue(limits: lim, now: d(7)).answers.first)
        XCTAssertEqual(item.id, q.id)
        XCTAssertTrue(item.answer.contains("以道为志"))
        XCTAssertEqual(try db.revisitCounts(limits: lim, now: d(7)).questionsLeft, 1)

        // 记得：7 → 21；同一天再答以最后一次为准
        try db.recordAnswerReview(questionId: q.id!, result: .forgot, now: d(7))
        try db.recordAnswerReview(questionId: q.id!, result: .remembered, now: d(7, hour: 1))
        let logs = try db.writer.read { try Int.fetchAll($0, sql: "SELECT result FROM self_test_log WHERE kind = 'question' AND recordId = ?", arguments: [q.id!]) }
        XCTAssertEqual(logs, [SelfTestResult.remembered.rawValue])
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(7, hour: 2)).answersDone, 2)
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(27)).answers.isEmpty)
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(28)).answers.first?.intervalDays, 21)
        // 忘了：两天后再来，间隔从 7 天算起
        try db.recordAnswerReview(questionId: q.id!, result: .forgot, now: d(28))
        XCTAssertEqual(try db.revisitQueue(limits: lim, now: d(30)).answers.first?.intervalDays, 7)
        XCTAssertEqual(try db.examTally(now: d(28)), MasteryTally(bad: 1), "计入卷面成绩")
        // 掌握度与常错的题
        try db.recordAnswerReview(questionId: q.id!, result: .forgot, now: d(30))
        XCTAssertEqual(try db.weakItems(now: d(31))[.question]?.first?.recordId, q.id)
        // 重新打开就不再出解答题，回到进展题
        try db.setQuestionStatus(id: q.id!, .lead, now: d(31))
        XCTAssertTrue(try db.revisitQueue(limits: lim, now: d(40)).answers.isEmpty)
    }

    func testAnswerPointsToNote() throws {
        let db = try AppDatabase(DatabaseQueue())
        let note = try db.createIdeaNote(title: "士由身份转为德行", body: "<p>春秋以后，士渐以德行自许。</p>", now: t0)
        let q = try db.createQuestion(title: "士的含义如何变化？", now: t0)
        try db.setQuestionAnswerNote(id: q.id!, noteId: note.id, now: t0)
        try db.setQuestionStatus(id: q.id!, .solved, now: t0)
        let item = try XCTUnwrap(try db.answerItem(id: q.id!))
        XCTAssertEqual(item.noteTitle, "士由身份转为德行")
        XCTAssertTrue(item.noteBody?.contains("德行自许") ?? false)
    }

    func testStorePaperShowsAnswerQuestion() throws {
        try MainActor.assumeIsolated {
            let keys = [RevisitLimits.questionsKey, RevisitLimits.answersKey, RevisitLimits.notesKey, RevisitLimits.blocksKey,
                        LibraryStore.examRelearnKey, ReviewSessionRecord.key(theme: nil), ExamSettings.minutesKey]
            let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer { for (k, v) in zip(keys, saved) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }
            for k in keys { UserDefaults.standard.removeObject(forKey: k) }
            XCTAssertEqual(RevisitLimits.saved(), RevisitLimits(notes: 2, questions: 2, books: RevisitLimits.saved().books, blocks: 2, answers: 2), "默认进展题、解答题各 2 道")

            let db = try AppDatabase(DatabaseQueue())
            let week = Date().addingTimeInterval(-10 * 86_400)
            let q = try db.createQuestion(title: "何为“为己之学”？", now: week)
            try db.saveQuestion(id: q.id!, title: q.title, detail: "", answer: "<p>学以成己。</p>", now: week)
            try db.setQuestionStatus(id: q.id!, .solved, now: week)
            // 升级时早已解决的分散在之后 30 天内；这里直接排到今天
            _ = try db.revisitQueue()
            try db.writer.write { try $0.execute(sql: "UPDATE question_answer_review SET dueDay = ?", arguments: [AppDatabase.revisitDay(Date())]) }
            let store = LibraryStore(db: db)
            store.refreshRevisit()
            let paper = store.examPaper()
            XCTAssertTrue(paper.available.contains(.question))
            guard case .answer(let a)? = paper.question(.question, day: Date()) else { return XCTFail("出解答题") }
            XCTAssertEqual(a.id, q.id)
            store.examAnswerQuestionAnswer(a, result: .forgot)
            XCTAssertTrue(store.examRelearn.items.contains { $0.kind == .answer && $0.id == q.id! }, "忘了的卷尾再考")
            guard case .answer? = store.examRelearnNext()?.1 else { return XCTFail("卷尾再考出解答题") }
            XCTAssertNil(store.examPaper().question(.question, day: Date()), "忘了的两天后再来")
        }
    }
}
