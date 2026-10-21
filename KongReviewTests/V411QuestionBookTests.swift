import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.1.1：问题簿——专题问题迁移、状态流转、材料、归属、写成札记、删除联动、搜索、界面状态
final class V411QuestionBookTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from: .init(year: 2026, month: 10, day: day, hour: hour))! }

    func testLegacyTopicQuestionsMigrateWithoutLoss() async throws {
        let queue = try DatabaseQueue()
        let old = try AppDatabase(queue, upTo: "v17-idea-notes")
        let n = try old.createNotebook(title: "何以为士")
        let gone = try old.createNotebook(title: "已删专题")
        let h = try old.save(Highlight(text: "士不可以不弘毅"))
        let card = try old.save(Card(deck: "论语", front: "<p>弘毅</p>", back: "<p>弘言其量</p>"))
        let open = TopicQuestion(notebookID: n.id!, question: "<p>学与习之别？</p>", createdAt: date(1), updatedAt: date(2))
        let lead = TopicQuestion(notebookID: n.id!, question: "<p>弘毅<b>二字</b>如何分训？</p>",
                                 evidence: PlanEvidence(kind: .highlight, recordID: h.id!, title: "士不可以不弘毅"), createdAt: date(3), updatedAt: date(4))
        let solved = TopicQuestion(notebookID: n.id!, question: "<p>已解决的问题</p>", answer: "<p>答案</p>",
                                   evidence: PlanEvidence(kind: .card, recordID: card.id!, title: "弘毅"), createdAt: date(5), updatedAt: date(18), solvedAt: date(18))
        let orphan = TopicQuestion(notebookID: gone.id!, question: "<p>专题已删的问题</p>",
                                   evidence: PlanEvidence(kind: .block, recordID: 9_999, title: "已删文字"))
        let long = TopicQuestion(notebookID: n.id!, question: "<p>" + String(repeating: "长", count: 150) + "</p><p>第二段</p>")
        for q in [open, lead, solved, orphan, long] { try old.saveProgress(q, key: q.key) }
        let newDraft = TopicQuestionDraft(value: TopicQuestion(notebookID: n.id!, question: "<p>未保存的新问题</p>", answer: "<p>草稿解释</p>"))
        var edit = TopicQuestionDraft(value: open, original: open); edit.value.answer = "<p>改了一半的解释</p>"
        for d in [newDraft, edit] { try old.saveProgress(d, key: d.key) }
        try old.saveProgress(Data("坏数据".utf8), key: "topic-question.broken")
        try await queue.write { db in try db.execute(sql: "DELETE FROM notebook WHERE id = ?", arguments: [gone.id!]) }

        let db = try AppDatabase(queue)
        let all = try await db.questionPage(QuestionFilter(state: .all))
        XCTAssertEqual(all.total, 5, "五个专题问题一个不少")
        let byTitle = Dictionary(uniqueKeysWithValues: all.items.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["学与习之别？"]?.status, .open)
        XCTAssertEqual(byTitle["弘毅二字如何分训？"]?.status, .lead, "有关联材料的未解问题为“有线索”")
        XCTAssertEqual(byTitle["弘毅二字如何分训？"]?.materialCount, 1)
        XCTAssertEqual(byTitle["已解决的问题"]?.status, .solved)
        XCTAssertEqual(byTitle["已解决的问题"]?.solvedAt, date(18), "保留原解决日期")
        XCTAssertEqual(byTitle["专题已删的问题"]?.status, .open, "关联材料已不存在：待研究")
        XCTAssertEqual(byTitle["专题已删的问题"]?.scopes, "", "专题已删：不归入")
        let formatted = try XCTUnwrap(try db.question(id: byTitle["弘毅二字如何分训？"]!.id))
        XCTAssertEqual(formatted.detail, lead.question, "原文有格式时整段留作补充说明")
        let longQ = try XCTUnwrap(all.items.first { $0.title.hasPrefix("长长") })
        XCTAssertTrue(longQ.title.hasSuffix("…"))
        XCTAssertEqual(try db.question(id: longQ.id)?.detail, long.question)
        let solvedQ = try XCTUnwrap(try db.question(id: byTitle["已解决的问题"]!.id))
        XCTAssertEqual(solvedQ.answer, "<p>答案</p>"); XCTAssertEqual(solvedQ.legacyKey, solved.key)
        let facts = try await db.periodReviewFacts(window: GrowthPeriod.month.window(containing: date(18), now: date(19), calendar: calendar))
        XCTAssertEqual(facts.solvedQuestions, 1, "迁移前后“已解决问题”计数一致")

        let left = try await db.writer.read { try String.fetchAll($0, sql: "SELECT key FROM app_progress WHERE key LIKE 'topic-question.%' OR key LIKE 'question-draft.%'") }
        XCTAssertEqual(left, ["topic-question.broken"], "解不开的记录原样保留，其余旧键删去")
        let drafts = try db.questionDrafts()
        XCTAssertEqual(drafts.count, 2)
        let editDraft = try XCTUnwrap(drafts.first { $0.questionId != nil })
        XCTAssertEqual(editDraft.questionId, byTitle["学与习之别？"]?.id, "修改中的草稿接到迁来的问题上")
        XCTAssertEqual(editDraft.answer, "<p>改了一半的解释</p>")
        let fresh = try XCTUnwrap(drafts.first { $0.questionId == nil })
        XCTAssertEqual(fresh.title, "未保存的新问题"); XCTAssertEqual(fresh.notebookID, n.id)
        XCTAssertEqual(try db.convertLegacyTopicQuestions(), 0, "再次打开不重复转")
    }

    func testStatusMaterialsScopesAndOrdering() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let n = try db.createNotebook(title: "论语专题")
        let p = try db.saveResearchProject(ResearchProject(title: "论语译注修订", kind: .book))
        try db.linkToResearchProject(p.id!, kind: .notebook, recordId: n.id!)
        let h1 = try db.save(Highlight(text: "学而时习之"))
        let h2 = try db.save(Highlight(text: "温故而知新"))
        let a = try db.createQuestion(title: "  学与习之别？ ", scopes: [(.notebook, n.id!)], now: date(1))
        XCTAssertEqual(a.title, "学与习之别？"); XCTAssertEqual(a.status, .open)
        try db.addQuestionMaterial(questionId: a.id!, kind: .highlight, recordId: h1.id!, reason: "  “习”字的本义 ", now: date(2))
        try db.addQuestionMaterial(questionId: a.id!, kind: .highlight, recordId: h1.id!, now: date(2))
        try db.addQuestionMaterial(questionId: a.id!, kind: .highlight, recordId: h2.id!, now: date(3))
        var d = try await db.questionDetail(id: a.id!)
        XCTAssertEqual(d.question.status, .lead, "挂上第一条材料：待研究 → 有线索")
        XCTAssertEqual(d.materials.map(\.recordId), [h1.id!, h2.id!], "按挂上的顺序，不重复")
        XCTAssertEqual(d.materials.first?.reason, "“习”字的本义", "再挂一次不带说明时，原说明保留")
        XCTAssertEqual(d.scopes.map(\.title), ["论语专题"])

        let b = try db.createQuestion(title: "温故何以知新？", scopes: [(.project, p.id!)], now: date(4))
        let c = try db.createQuestion(title: "无关的问题", now: date(5))
        try db.setQuestionPinned(id: a.id!, true)
        let page = try await db.questionPage(QuestionFilter(), preferProjectID: p.id)
        XCTAssertEqual(page.items.map(\.id), [a.id!, b.id!, c.id!], "「常念」在前，其次当前项目，再按最近修改")
        let inProject = try await db.questionPage(QuestionFilter(projectID: p.id))
        XCTAssertEqual(Set(inProject.items.map(\.id)), [a.id!, b.id!], "项目筛选含其专题中的问题")
        let o = try await db.researchProjectOverview(id: p.id!)
        XCTAssertEqual(o.openQuestions.map(\.id), [a.id!, b.id!], "项目页与问题簿读到同一批问题")

        try db.setQuestionStatus(id: c.id!, .shelved)
        let unsolved = try await db.questionPage(QuestionFilter())
        XCTAssertFalse(unsolved.items.contains { $0.id == c.id }, "搁置的不在未解列表")
        XCTAssertEqual(try db.openQuestionCount(), 2)
        let shelved = try await db.questionPage(QuestionFilter(state: .shelved))
        XCTAssertEqual(shelved.items.map(\.id), [c.id!])

        XCTAssertEqual(try db.questionsHolding(kind: .highlight, recordIDs: [h1.id!, h2.id!]).mapValues { $0.map(\.id) }, [h1.id!: [a.id!], h2.id!: [a.id!]])
        try db.moveToTrash(h2)
        d = try await db.questionDetail(id: a.id!)
        XCTAssertEqual(d.materials.map(\.recordId), [h1.id!], "回收站里的摘录不显示")
        _ = try db.emptyTrash()
        let rows = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_material WHERE recordId = ?", arguments: [h2.id!]) }
        XCTAssertEqual(rows, 0, "摘录彻底删除时随之去掉")
        try db.deleteNotebook(n.id!)
        d = try await db.questionDetail(id: a.id!)
        XCTAssertTrue(d.scopes.isEmpty, "专题删除时去掉归属")

        try db.setQuestionScope(questionId: a.id!, kind: .project, recordId: p.id!, included: true)
        try db.removeQuestionMaterial(questionId: a.id!, kind: .highlight, recordId: h1.id!)
        d = try await db.questionDetail(id: a.id!)
        XCTAssertTrue(d.materials.isEmpty); XCTAssertEqual(d.scopes.map(\.kind), [.project])
        let found = try await db.questionPage(QuestionFilter(query: "學與習"))
        XCTAssertEqual(found.items.map(\.id), [a.id!], "繁简通搜")
        let hits = try await db.globalSearch(query: "温故", kind: .question)
        XCTAssertEqual(hits.first?.items.map(\.title), ["温故何以知新？"])
        try db.deleteQuestion(id: c.id!)
        XCTAssertNil(try db.question(id: c.id!))
    }

    func testAnswerNoteWriteAsNoteAndSolvedCounts() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let p = try db.saveResearchProject(ResearchProject(title: "何以为士"))
        let h = try db.save(Highlight(text: "士志于道"))
        let q = try db.createQuestion(title: "士何以志于道？", scopes: [(.project, p.id!)], now: date(10))
        try db.addQuestionMaterial(questionId: q.id!, kind: .highlight, recordId: h.id!, now: date(10))
        XCTAssertThrowsError(try db.writeQuestionAsNote(id: q.id!), "没有解答不能写成札记")
        try db.saveQuestion(id: q.id!, title: q.title, detail: "", answer: "<p>道为士之所以为士</p>", now: date(11))
        try db.setQuestionStatus(id: q.id!, .solved, now: date(12))
        let noteId = try db.writeQuestionAsNote(id: q.id!, now: date(13))
        let note = try XCTUnwrap(try db.ideaNote(id: noteId))
        XCTAssertEqual(note.title, "士何以志于道？"); XCTAssertEqual(note.body, "<p>道为士之所以为士</p>")
        let nd = try await db.ideaNoteDetail(id: noteId)
        XCTAssertEqual(nd.highlights.compactMap(\.id), [h.id!], "带过问题下的摘录")
        XCTAssertEqual(try db.researchProjectLinks(projectId: p.id!).map(\.kind), [.note], "札记归入问题所属的项目")
        var d = try await db.questionDetail(id: q.id!)
        XCTAssertEqual(d.answerNote?.id, noteId, "解答改为指向这条札记")
        XCTAssertEqual(d.question.answer, "")
        XCTAssertEqual(d.question.status, .solved)
        let related = try await db.questionsForNote(noteId)
        XCTAssertEqual(related.answered.map(\.id), [q.id!])
        XCTAssertThrowsError(try db.setQuestionAnswerNote(id: q.id!, noteId: nil), "已解决的问题不能把唯一的解答拿掉")

        try db.purgeIdeaNote(noteId)
        d = try await db.questionDetail(id: q.id!)
        XCTAssertNil(d.answerNote)
        XCTAssertEqual(d.question.answer, "<p>道为士之所以为士</p>", "札记彻底删除时正文留作解答")

        let window = GrowthPeriod.month.window(containing: date(12), now: date(20), calendar: calendar)
        let solved = try await db.questionsSolved(start: window.start, end: window.end)
        XCTAssertEqual(solved, 1)
        try db.setQuestionStatus(id: q.id!, .lead)
        let afterReopen = try await db.questionsSolved(start: window.start, end: window.end)
        XCTAssertEqual(afterReopen, 0, "重新打开的不再计入")
    }

    func testStoreAttachCreateAndDrafts() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let h = try db.save(Highlight(text: "学而时习之，不亦说乎"))
            let store = LibraryStore(db: db)
            store.attachToQuestion(kind: .highlight, recordId: h.id, preview: "<p>学而时习之，不亦说乎</p>")
            let request = try XCTUnwrap(store.questionAttach)
            XCTAssertEqual(request.recordId, h.id); XCTAssertTrue(request.preview.hasPrefix("学而时习之"))
            let id = try XCTUnwrap(store.createQuestion(title: "“说”与“乐”何别？", material: request, reason: "首章"))
            XCTAssertEqual(store.openQuestionCount, 1)
            XCTAssertEqual(store.questionsHolding(.highlight, [h.id!], unsolvedOnly: true)[h.id!]?.map(\.id), [id])
            XCTAssertEqual(try db.question(id: id)?.status, .lead)

            store.setQuestionStatus(id, .shelved)
            XCTAssertEqual(store.openQuestionCount, 0)
            XCTAssertTrue(store.questionsHolding(.highlight, [h.id!], unsolvedOnly: true).isEmpty, "回顾卡片只提示未解决的")

            let draft = QuestionDraft(id: UUID().uuidString, title: "", answer: "<p>只写了解答</p>")
            store.saveQuestionDraft(draft)
            XCTAssertEqual(try db.questionDrafts().count, 1)
            store.resumeQuestionDraft(draft)
            guard case .question(let restored) = store.selection else { return XCTFail("应打开新问题") }
            XCTAssertEqual(try db.question(id: restored)?.title, "未命名问题")
            XCTAssertTrue(try db.questionDrafts().isEmpty)

            store.openQuestionBook(QuestionFilter(state: .solved))
            XCTAssertEqual(store.selection, .questionBook)
            XCTAssertEqual(store.questionBookFilter.state, .solved)
            store.deleteQuestion(id)
            XCTAssertNil(try db.question(id: id))
        }
    }
}
