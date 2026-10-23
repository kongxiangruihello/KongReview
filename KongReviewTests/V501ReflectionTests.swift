import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.0.1：复盘——步骤与进度、数字、想法、问题、观点的变化、提醒时间、首页指向哪一周
final class V501ReflectionTests: XCTestCase {
    /// 2026 年 10 月某周三上午 9 点（以本地日历计）
    private let wed: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func days(_ n: Int, from d: Date) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d)! }

    func testStepsAndProgressRoundTrip() throws {
        XCTAssertEqual(ReflectionStep.steps(for: .week), [.numbers, .materials, .thoughts, .questions, .sentences])
        XCTAssertEqual(ReflectionStep.steps(for: .month).count, 5)
        XCTAssertEqual(ReflectionStep.steps(for: .year), [.numbers, .materials, .thoughts, .questions, .views, .sentences], "年度加“观点的变化”")
        let db = try AppDatabase(DatabaseQueue())
        let w = GrowthPeriod.week.window(containing: wed, now: wed)
        XCTAssertNil(try db.reflectionProgress(w).completedAt)
        try db.saveReflectionProgress(ReflectionProgress(step: 2, visited: [0, 2]), window: w)
        XCTAssertEqual(try db.reflectionProgress(w).step, 2)
        XCTAssertFalse(db.reflectionCompleted(w))
        try db.completeReflection(w, now: wed)
        XCTAssertEqual(try db.reflectionProgress(w).completedAt, wed)
        XCTAssertEqual(try db.reflectionProgress(w).visited, [0, 1, 2, 3, 4])
        XCTAssertEqual(try db.lastReflection(period: .week), wed)
        XCTAssertNil(try db.lastReflection(period: .month))
        XCTAssertTrue(ReflectionProgress.key(w).hasPrefix("reflection.growth.week."))
    }

    func testNumbersThoughtsAndViewChanges() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let w = GrowthPeriod.week.window(containing: wed, now: days(1, from: wed))
        let old = try db.createIdeaNote(title: "旧看法", body: "<p>甲</p>", now: days(-200, from: wed))
        let fresh = try db.createIdeaNote(title: "本周新写", body: "<p>乙</p>", now: wed)
        try db.saveIdeaNote(id: old.id!, title: "新看法", body: "<p>甲乙</p>", now: wed)
        try db.saveIdeaNote(id: old.id!, title: "新看法", body: "<p>甲乙丙</p>", now: wed.addingTimeInterval(7200))
        let pending = try db.createIdeaNote(title: "待修订的", now: days(-40, from: wed))
        try db.recordNoteRevisit(noteId: pending.id!, outcome: .revise, now: wed)
        let rows = try await db.reflectionNumbers(w)
        XCTAssertEqual(rows.first { $0.title == "新写札记（条）" }?.now, 1)
        XCTAssertEqual(rows.first { $0.title == "重温札记（条）" }?.now, 1)
        let t = try db.reflectionThoughts(start: w.start, end: w.end)
        XCTAssertEqual(t.created.map(\.id), [fresh.id!])
        XCTAssertEqual(t.revised.map(\.ref.id), [old.id!])
        XCTAssertEqual(t.revised.first?.times, 1, "同一天只记一次")
        XCTAssertEqual(t.pendingRevision.map(\.id), [pending.id!], "说要修订而还没改的")
        try db.saveIdeaNote(id: pending.id!, title: "待修订的", body: "<p>改了</p>", now: days(1, from: wed))
        XCTAssertTrue(try db.reflectionThoughts(start: w.start, end: w.end).pendingRevision.isEmpty, "改过就不再列")

        let year = GrowthPeriod.year.window(containing: wed, now: days(1, from: wed))
        let changes = try db.viewChanges(start: year.start, end: year.end)
        let c = try XCTUnwrap(changes.first { $0.id == old.id })
        XCTAssertEqual(c.beforeTitle, "旧看法", "年初的样子")
        XCTAssertEqual(c.nowTitle, "新看法")
        XCTAssertEqual(c.nowBody, "<p>甲乙丙</p>")
    }

    func testQuestionsStepAndYearMarkdown() throws {
        let db = try AppDatabase(DatabaseQueue())
        let w = GrowthPeriod.week.window(containing: wed, now: days(1, from: wed))
        let h = try db.save(Highlight(text: "士不可以不弘毅"))
        let pinned = try db.createQuestion(title: "常念的问题", now: days(-30, from: wed))
        try db.setQuestionPinned(id: pinned.id!, true)
        try db.addQuestionMaterial(questionId: pinned.id!, kind: .highlight, recordId: h.id!, now: wed)
        let other = try db.createQuestion(title: "另一个疑问", now: wed)
        let solved = try db.createQuestion(title: "已解决的", now: days(-10, from: wed))
        _ = try db.saveQuestion(id: solved.id!, title: "已解决的", detail: "", answer: "<p>答案在此</p>")
        try db.setQuestionStatus(id: solved.id!, .solved, now: wed)
        let q = try db.reflectionQuestions(start: w.start, end: w.end)
        XCTAssertEqual(q.pinned.map(\.id), [pinned.id!])
        XCTAssertEqual(q.pinned.first?.newMaterials, 1, "本期新挂的材料")
        XCTAssertEqual(q.solved.map(\.id), [solved.id!])
        XCTAssertEqual(q.candidates.map(\.id), [other.id!], "可标为常念的：未常念、未解决")
        XCTAssertEqual(q.created, 1)
        XCTAssertEqual(q.solvedCount, 1)
        XCTAssertEqual(q.stillOpen, 1)
        let year = GrowthPeriod.year.window(containing: wed, now: days(1, from: wed))
        let md = try db.questionsYearMarkdown(year)
        XCTAssertTrue(md.contains("## 解决的问题（1）"))
        XCTAssertTrue(md.contains("答案在此"))
        XCTAssertTrue(md.contains("常念的问题（"), "仍在心上的列出状态")
        XCTAssertTrue(md.contains("## 今年新记的问题（3）"))
    }

    func testReminderFiresSkipCompletedWeek() throws {
        let cal = Calendar.current
        let fires = ReflectionReminderPlan.fires(now: wed, weekday: 1, hour: 20, minute: 0, count: 3) { _ in false }
        XCTAssertEqual(fires.count, 3)
        XCTAssertTrue(fires.allSatisfy { cal.component(.weekday, from: $0) == 1 && cal.component(.hour, from: $0) == 20 })
        XCTAssertTrue(fires[0] > wed)
        let firstWeek = ReflectionReminderPlan.targetWeek(for: fires[0])
        XCTAssertTrue(firstWeek.start <= days(-1, from: fires[0]) && days(-1, from: fires[0]) < firstWeek.fullEnd, "对应提醒前一天所在的周")
        let skipped = ReflectionReminderPlan.fires(now: wed, weekday: 1, hour: 20, minute: 0, count: 3) { $0.key == firstWeek.key }
        XCTAssertEqual(skipped.first, fires[1], "那一周已复盘就跳过")
    }

    func testTargetWeekEarlyInWeekPointsToUnreviewedPrevious() throws {
        let db = try AppDatabase(DatabaseQueue())
        let cal = Calendar.current
        let thisWeek = GrowthPeriod.week.window(containing: wed, now: wed)
        let firstDay = cal.date(byAdding: .hour, value: 9, to: thisWeek.start)!
        let lastWeek = GrowthPeriod.week.window(containing: thisWeek.previousStart, now: firstDay)
        XCTAssertEqual(db.reflectionTargetWeek(now: firstDay).key, lastWeek.key, "周初、上周未复盘：指向上周")
        try db.completeReflection(lastWeek, now: firstDay)
        XCTAssertEqual(db.reflectionTargetWeek(now: firstDay).key, thisWeek.key)
        let late = cal.date(byAdding: .day, value: 5, to: firstDay)!
        let db2 = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(db2.reflectionTargetWeek(now: late).key, GrowthPeriod.week.window(containing: late, now: late).key, "周后半指向本周")
    }

    func testStoreOpenAndCompleteReflection() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            var calls = 0
            store.onReflectionChanged = { calls += 1 }
            store.openReflection(period: .month)
            XCTAssertEqual(store.selection, .reflection)
            XCTAssertEqual(store.reflectionPeriod, .month)
            let w = store.reflectionPeriod.window(containing: store.reflectionDate)
            let before = store.reflectionRevision
            store.completeReflection(w)
            XCTAssertTrue(db.reflectionCompleted(w))
            XCTAssertEqual(store.reflectionRevision, before + 1)
            XCTAssertEqual(calls, 1, "完成后重排提醒")
            store.openReflection(period: .day)
            XCTAssertEqual(store.reflectionPeriod, .month, "没有“每日复盘”")
        }
    }
}
