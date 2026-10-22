import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.0.0：重温——札记排程与修订历史、常念问题轮流、迁移、学习小结
final class V500RevisitTests: XCTestCase {
    /// 某日上午 9 点：加几个小时仍在同一天
    private let t0 = Calendar.current.date(byAdding: .hour, value: 9, to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private let two = RevisitLimits(notes: 2, questions: 1)

    func testNoteScheduleIntervalsReviseLaterAndDeleted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.createIdeaNote(title: "士由身份转为德行", body: "<p>甲</p>", now: t0)
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(6)).notes.isEmpty, "新写的札记 7 天后才来")
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(7)).notes.map(\.id), [a.id!])
        // 仍然这么看：7 → 21 → 60 → 180 → 365 → 365
        var day = 7
        for expected in [21, 60, 180, 365, 365] {
            try db.recordNoteRevisit(noteId: a.id!, outcome: .agree, now: d(day))
            XCTAssertTrue(try db.revisitQueue(limits: two, now: d(day + expected - 1)).notes.isEmpty)
            let item = try XCTUnwrap(try db.revisitQueue(limits: two, now: d(day + expected)).notes.first)
            XCTAssertEqual(item.intervalDays, expected)
            day += expected
        }
        // 以后再说：一周后再来，间隔不变
        try db.recordNoteRevisit(noteId: a.id!, outcome: .later, now: d(day))
        var item = try XCTUnwrap(try db.revisitQueue(limits: two, now: d(day + 7)).notes.first)
        XCTAssertEqual(item.intervalDays, 365)
        XCTAssertEqual(item.reviewCount, 6)
        XCTAssertEqual(item.lastReviewedAt, d(day))
        // 要修订：从头算
        day += 7
        try db.recordNoteRevisit(noteId: a.id!, outcome: .revise, now: d(day))
        item = try XCTUnwrap(try db.revisitQueue(limits: two, now: d(day + 7)).notes.first)
        XCTAssertEqual(item.intervalDays, 7)
        // 保存时正文变了也从头算；只改格式不算
        try db.recordNoteRevisit(noteId: a.id!, outcome: .agree, now: d(day + 7))
        day += 7
        try db.saveIdeaNote(id: a.id!, title: a.title, body: "<p><b>甲</b></p>", now: d(day + 1))
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(day + 8)).notes.isEmpty, "只改格式，间隔仍是 21 天")
        try db.saveIdeaNote(id: a.id!, title: a.title, body: "<p>甲乙</p>", now: d(day + 2))
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(day + 9)).notes.first?.intervalDays, 7, "改过的札记从头算")
        // 已删除的不来；恢复后照常
        try db.setIdeaNoteDeleted(a.id!, deleted: true)
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(day + 9)).notes.isEmpty)
        try db.setIdeaNoteDeleted(a.id!, deleted: false)
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(day + 9)).notes.count, 1)
        try db.purgeIdeaNote(a.id!)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM idea_note_review") }, 0, "彻底删除连排程一起去掉")
    }

    func testDailyLimitCountsHandledItems() throws {
        let db = try AppDatabase(DatabaseQueue())
        let ids = try (0..<3).map { try db.createIdeaNote(title: "札记\($0)", now: d(-30 + $0)).id! }
        var q = try db.revisitQueue(limits: two, now: t0)
        XCTAssertEqual(q.notes.map(\.id), [ids[0], ids[1]], "到期早的在前，至多 2 条")
        try db.recordNoteRevisit(noteId: ids[0], outcome: .later, now: t0)
        q = try db.revisitQueue(limits: two, now: d(0, hour: 2))
        XCTAssertEqual(q.notes.map(\.id), [ids[1]], "以后再说也占当天名额")
        XCTAssertEqual(q.notesDone, 1)
        try db.recordNoteRevisit(noteId: ids[1], outcome: .agree, now: d(0, hour: 3))
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(0, hour: 4)).notes.isEmpty)
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(1)).notes.map(\.id), [ids[2]], "第二天接着来")
        XCTAssertTrue(try db.revisitQueue(limits: .init(notes: 0, questions: 0), now: d(1)).isEmpty, "设为 0 即不重温")
        let counts = try db.revisitCounts(limits: two, now: d(0, hour: 5))
        XCTAssertEqual(counts.left, 0)
        XCTAssertEqual(counts.done, 2)
    }

    func testPinnedQuestionsRotateWeekly() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "士不可以不弘毅"))
        let p = try db.createQuestion(title: "“士志于道”与“士不可以不弘毅”能否互证？", now: t0)
        try db.setQuestionPinned(id: p.id!, true)
        _ = try db.createQuestion(title: "没有标常念的问题", now: t0)
        let shelved = try db.createQuestion(title: "搁置的常念问题", now: t0)
        try db.setQuestionPinned(id: shelved.id!, true)
        try db.setQuestionStatus(id: shelved.id!, .shelved, now: t0)
        XCTAssertTrue(try db.revisitQueue(limits: two, now: t0).questions.isEmpty, "标常念当天不来")
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(7)).questions.map(\.id), [p.id!], "只有常念且未解决的来")
        try db.recordQuestionRevisit(questionId: p.id!, outcome: .lead, highlightIDs: [h.id!], remark: "曾子一章可作旁证", now: d(7))
        let q = try XCTUnwrap(try db.question(id: p.id!))
        XCTAssertEqual(q.status, .lead, "待研究的改为有线索")
        XCTAssertTrue(q.detail.contains("：曾子一章可作旁证</p>"))
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(14)).questions.first?.materialCount, 1)
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(13)).questions.isEmpty, "一周后再来")
        // 两个常念问题同时到期，每天至多一个
        let p2 = try db.createQuestion(title: "孔门之“士”是否已脱离封建等级的含义？", now: d(8))
        try db.setQuestionPinned(id: p2.id!, true)
        _ = try db.revisitQueue(limits: two, now: d(9))
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(20)).questions.map(\.id), [p2.id!], "到期早的先来")
        try db.setQuestionPinned(id: p2.id!, false)
        XCTAssertEqual(try db.revisitQueue(limits: two, now: d(20)).questions.map(\.id), [p.id!], "取消常念后不再来")
        try db.recordQuestionRevisit(questionId: p.id!, outcome: .notyet, now: d(20))
        XCTAssertTrue(try db.revisitQueue(limits: two, now: d(20)).questions.isEmpty)
    }

    func testMigrationSpreadsFirstRevisitAndKeepsReviewEvents() throws {
        let now = Date()
        let old = try AppDatabase(DatabaseQueue(), upTo: "v19-notebook-note-blocks")
        for i in 0..<40 { _ = try old.createIdeaNote(title: "旧札记\(i)", now: now.addingTimeInterval(-Double(100 + i) * 86_400)) }
        let young = try old.createIdeaNote(title: "新札记", now: now.addingTimeInterval(-2 * 86_400))
        for i in 0..<3 {
            let q = try old.createQuestion(title: "常念\(i)", now: now.addingTimeInterval(-30 * 86_400))
            try old.setQuestionPinned(id: q.id!, true)
        }
        let h = try old.save(Highlight(text: "旧摘录"))
        old.log(ReviewEvent(kind: .keep, highlightId: h.id))
        let events = try old.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_event") }
        try old.migrateIfNeeded()
        let today = AppDatabase.revisitDay(now)
        let noteDays = try old.writer.read { db -> [Int64: String] in
            var out: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT noteId, dueDay FROM idea_note_review") { out[row["noteId"]] = row["dueDay"] }
            return out
        }
        XCTAssertEqual(noteDays.count, 41)
        XCTAssertEqual(noteDays[young.id!], AppDatabase.revisitDay(now.addingTimeInterval(-2 * 86_400), plus: 7), "不满 7 天的在写成后第 7 天")
        let oldDays = noteDays.filter { $0.key != young.id! }.map(\.value)
        XCTAssertTrue(oldDays.allSatisfy { $0 > today && $0 <= AppDatabase.revisitDay(now, plus: 30) }, "升级当天不来，30 天内来完")
        XCTAssertGreaterThanOrEqual(Set(oldDays).count, 25, "分散在 30 天内")
        let questionDays = try old.writer.read { try String.fetchAll($0, sql: "SELECT dueDay FROM question_review") }
        XCTAssertEqual(questionDays.count, 3)
        XCTAssertTrue(questionDays.allSatisfy { $0 > today && $0 <= AppDatabase.revisitDay(now, plus: 7) })
        // 重温另记，不改回顾统计
        let first = try XCTUnwrap(noteDays.keys.first)
        try old.recordNoteRevisit(noteId: first, outcome: .agree)
        XCTAssertEqual(try old.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_event") }, events)
        XCTAssertTrue(old.migrationIdentifiers.contains("v20-revisit"))
    }

    func testRevisionHistoryOnePerDayAndVersionAt() throws {
        let db = try AppDatabase(DatabaseQueue())
        let n = try db.createIdeaNote(title: "初稿", body: "<p>一</p>", now: t0)
        try db.saveIdeaNote(id: n.id!, title: "初稿", body: "<p>一二</p>", now: d(0, hour: 3))
        XCTAssertTrue(try db.ideaNoteRevisions(noteId: n.id!).isEmpty, "写成当天的修改不记")
        try db.saveIdeaNote(id: n.id!, title: "二稿", body: "<p>二</p>", now: d(3, hour: 9))
        try db.saveIdeaNote(id: n.id!, title: "二稿", body: "<p>二又改</p>", now: d(3, hour: 10))
        try db.saveIdeaNote(id: n.id!, title: "三稿", body: "<p>三</p>", now: d(5, hour: 9))
        let revisions = try db.ideaNoteRevisions(noteId: n.id!)
        XCTAssertEqual(revisions.map(\.title), ["初稿", "二稿"], "同一天只留改动前的第一版")
        XCTAssertEqual(revisions.first?.body, "<p>一二</p>")
        XCTAssertEqual(revisions.last?.body, "<p>二又改</p>")
        XCTAssertEqual(try db.ideaNoteVersion(noteId: n.id!, at: d(1))?.title, "初稿")
        XCTAssertEqual(try db.ideaNoteVersion(noteId: n.id!, at: d(4))?.body, "<p>二又改</p>")
        XCTAssertEqual(try db.ideaNoteVersion(noteId: n.id!, at: d(6))?.title, "三稿", "之后没改过就是现在的样子")
    }

    func testNotesRevisitedAndTodayWorkMinutes() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.createIdeaNote(title: "甲", now: d(-20))
        let b = try db.createIdeaNote(title: "乙", now: d(-20))
        try db.recordNoteRevisit(noteId: a.id!, outcome: .later, now: t0)
        try db.recordNoteRevisit(noteId: a.id!, outcome: .agree, now: d(7))
        try db.recordNoteRevisit(noteId: b.id!, outcome: .agree, now: d(7))
        let count = try await db.notesRevisited(start: d(-1), end: d(10))
        XCTAssertEqual(count, 2, "同一条只计一次")
        let none = try await db.notesRevisited(start: d(-10), end: d(-1))
        XCTAssertEqual(none, 0)
        XCTAssertEqual(LibraryStore.todayWorkMinutes(reviewPending: 0, cards: .init(), revisit: 3), 3)
        XCTAssertEqual(LibraryStore.todayWorkMinutes(reviewPending: 2, cards: .init()), 1)
    }

    func testStoreTodayWorkReachesRevisitAndFreshHighlights() throws {
        try MainActor.assumeIsolated {
            // 回顾与记忆卡都没有待办时，“开始今日功课”直接进入重温
            let plain = try AppDatabase(DatabaseQueue())
            let only = try plain.createIdeaNote(title: "士以道自任", now: Date().addingTimeInterval(-30 * 86_400))
            let first = LibraryStore(db: plain)
            XCTAssertEqual(first.revisitCounts.notesLeft, 1)
            first.startTodayWork()
            XCTAssertEqual(first.selection, .revisit)
            first.revisitNote(only.id!, .revise)
            XCTAssertEqual(first.selection, .ideaNote(only.id!), "要修订随即打开札记")
            XCTAssertEqual(first.revisitCounts.left, 0)
            XCTAssertEqual(first.revisitCounts.done, 1)

            let db = try AppDatabase(DatabaseQueue())
            var older = Highlight(text: "士志于道，而耻恶衣恶食者，未足与议也"); older.createdAt = Date().addingTimeInterval(-60 * 86_400)
            older = try db.save(older)
            _ = try db.save(Highlight(text: "学而时习之，不亦说乎"))
            _ = try db.save(Highlight(text: "温故而知新，可以为师矣"))
            let fresh = try db.save(Highlight(text: "士志于道，任重而道远"))
            let note = try db.createIdeaNote(title: "士志于道", body: "<p>士以道自任</p>", now: Date().addingTimeInterval(-30 * 86_400))
            let store = LibraryStore(db: db)
            store.relatedIndex = RelatedIndex(try db.relatedDocs())
            let hits = store.revisitNewHighlights(text: "士志于道 士以道自任", since: note.createdAt, excluding: [])
            XCTAssertEqual(hits.map(\.id), [fresh.id], "只取上次重温以来新录的")
            XCTAssertTrue(store.revisitNewHighlights(text: "士志于道", since: note.createdAt, excluding: [fresh.id!]).isEmpty, "已引用的不列")
            _ = older
        }
    }
}
