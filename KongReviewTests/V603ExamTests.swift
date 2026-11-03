import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.0.3：今日试卷——交错出题、摘录题的出法、作答记录与掌握度、补考、组卷与作答
final class V603ExamTests: XCTestCase {
    private let sessionKey = ReviewSessionRecord.key(theme: nil)
    private var savedSession: Data?

    override func setUp() {
        super.setUp()
        savedSession = UserDefaults.standard.data(forKey: sessionKey)
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    override func tearDown() {
        if let savedSession { UserDefaults.standard.set(savedSession, forKey: sessionKey) } else { UserDefaults.standard.removeObject(forKey: sessionKey) }
        super.tearDown()
    }

    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 3; c.hour = 10
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour - 10, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }

    func testRotationInterleaves() {
        var turn = 0
        var seen: [ExamKind] = []
        let all = Set(ExamKind.allCases)
        for _ in 0..<7 {
            let p = ExamRotation.next(turn: turn, available: all)!
            seen.append(p.kind); turn = p.turn
        }
        XCTAssertEqual(seen, [.card, .highlight, .note, .card, .highlight, .block, .question], "各类交错，记忆卡与摘录各占两位")
        let onlyNotes = ExamRotation.next(turn: 0, available: [.note])
        XCTAssertEqual(onlyNotes?.kind, .note)
        XCTAssertEqual(ExamRotation.next(turn: 5, available: [.card, .question])?.kind, .question, "从上次之后找第一类有题的")
        XCTAssertNil(ExamRotation.next(turn: 3, available: []))
    }

    func testHighlightModePick() {
        var h = Highlight(sourceId: 1, text: "学而时习之", location: "学而第一")
        h.id = 10
        let a = ExamHighlightMode.pick(for: h, day: t0)
        let b = ExamHighlightMode.pick(for: h, day: d(1))
        XCTAssertNotEqual(a, b, "有出处与位置的，逐日在要点题、出处题之间轮换")
        XCTAssertTrue([.gist, .source].contains(a))
        var bare = Highlight(sourceId: 1, text: "只有出处")
        bare.id = 11
        XCTAssertEqual(ExamHighlightMode.pick(for: bare, day: t0), .source, "没有位置与按语只考出处")
        XCTAssertEqual(ExamHighlightMode.pick(for: Highlight(text: "没有出处"), day: t0), .opening)
    }

    func testRecordResultTallyMasteryAndRetest() throws {
        let db = try AppDatabase(DatabaseQueue())
        let src = try db.save(Source(title: "论语译注"))
        let h = try db.save(Highlight(sourceId: src.id, text: "温故而知新", location: "为政第二"))
        let other = try db.save(Highlight(sourceId: src.id, text: "学而不思则罔"))
        try db.recordExamResult(kind: .gist, recordId: h.id!, result: .forgot, now: t0)
        try db.recordExamResult(kind: .source, recordId: other.id!, result: .partly, now: t0)
        try db.recordExamResult(kind: .source, recordId: other.id!, result: .remembered, now: d(0, hour: 11))
        XCTAssertEqual(try db.examTally(now: t0), MasteryTally(good: 1, mid: 0, bad: 1), "同一天同一条再答以最后一次为准")
        let (s, e) = AppDatabase.dayBounds(t0)
        let m = try db.writer.read { try AppDatabase.mastery($0, start: s, end: e) }
        XCTAssertEqual(m.good, 1); XCTAssertEqual(m.bad, 1)

        XCTAssertTrue(try db.examRetestHighlightIDs(now: d(1)).isEmpty, "第二天还不补考")
        XCTAssertEqual(try db.examRetestHighlightIDs(now: d(2)), [h.id!], "两天后起补考忘了的")
        XCTAssertTrue(try db.examRetestHighlightIDs(now: d(40)).isEmpty, "30 天外不再补")
        try db.recordExamResult(kind: .gist, recordId: h.id!, result: .remembered, now: d(2))
        XCTAssertTrue(try db.examRetestHighlightIDs(now: d(4)).isEmpty, "补考记得了就不再补")
        let wins = try db.progressEvents(start: d(-1), end: d(5)).filter { $0.kind == .selfTestRecovered }
        XCTAssertEqual(wins.count, 1, "从忘了到记得，记一件小胜")
    }

    func testDailyCheckExamGroupsLeaveOutSelfTest() throws {
        let db = try AppDatabase(DatabaseQueue())
        let c = { (done: Int, left: Int) in DailyCheckCount(done: done, left: left) }
        let s = try db.dailyCheck(current: [.review: c(1, 4), .cards: c(0, 3), .revisit: c(0, 0), .selfTest: c(0, 2)],
                                  groups: DailyCheckGroup.exam, now: t0)
        XCTAssertEqual(s.rows.map(\.group), [.review, .cards, .revisit])
        XCTAssertEqual(s.due, 8)
        XCTAssertEqual(s.done, 1)
    }

    func testStorePaperAnswersAndSession() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let src = try db.save(Source(title: "论语译注", author: "杨伯峻"))
            var forgotten: Highlight?
            for i in 0..<6 {
                let h = try db.save(Highlight(sourceId: src.id, text: "第 \(i) 条摘录：温故而知新，可以为师矣", location: "第\(i)页"))
                if i == 3 { forgotten = h }
            }
            // 三天前忘了的那条，今天应排在最前补考
            try db.recordExamResult(kind: .gist, recordId: forgotten!.id!, result: .forgot, now: Date().addingTimeInterval(-3 * 86_400))
            let note = try db.createIdeaNote(title: "士以道自任", body: "<p>依据</p>", now: Date().addingTimeInterval(-30 * 86_400))
            _ = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎"))
            let store = LibraryStore(db: db)

            let record = try store.todayReviewSession()
            XCTAssertEqual(record.regularIds.first, forgotten!.id, "补考的排在最前")
            XCTAssertEqual(try store.todayReviewSession().regularIds, record.regularIds, "同一天沿用同一组")

            let paper = store.examPaper()
            XCTAssertEqual(paper.available, [.card, .highlight, .note])
            XCTAssertEqual(paper.highlights.first?.id, forgotten!.id)
            XCTAssertEqual(paper.revisit.notes.first?.id, note.id)

            // 摘录题：记下作答，摘录记为看过，今天这一组往后推一条
            let first = paper.highlights[0]
            store.examAnswerHighlight(first, mode: .gist, result: .remembered, action: .favorite)
            XCTAssertEqual(ReviewSessionRecord.load(key: sessionKey)?.position, 1)
            XCTAssertEqual(try db.examTally(), MasteryTally(good: 1))
            XCTAssertEqual(try db.highlights(ids: [first.id!]).first?.isFavorite, true, "记得，并收藏")
            XCTAssertNotEqual(store.examPaper().highlights.first?.id, first.id)

            // 记忆卡：作答题与牌组学习同一套评分
            let card = try XCTUnwrap(store.examNextCard())
            store.examAnswerCard(card, .good)
            let ratings = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_event WHERE kind = 'card' AND cardId = ?", arguments: [card.id!]) }
            XCTAssertEqual(ratings, 1)

            // 论证题：先记得 / 大致 / 忘了，再“还这么看吗”
            store.examAnswerNote(paper.revisit.notes[0], result: .partly, outcome: .agree)
            XCTAssertEqual(try db.examTally(), MasteryTally(good: 1, mid: 1))
            XCTAssertTrue(store.examPaper().revisit.notes.isEmpty)
            XCTAssertEqual(store.revisitCounts.done, 1)

            store.openExam()
            XCTAssertEqual(store.selection, .dailyCheck)
            XCTAssertFalse(store.examHandedIn)
            store.examHandedIn = true
            XCTAssertTrue(store.examHandedIn)
            store.examHandedIn = false
        }
    }
}
