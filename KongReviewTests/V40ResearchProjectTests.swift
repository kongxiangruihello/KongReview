import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.0-a：研究项目——迁移、材料并集、阶段记录、归档、项目页汇总、当前项目
final class V40ResearchProjectTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 21, hour: 12))! }
    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    // MARK: 迁移：3.15 的本期焦点 → 当前项目

    func testFocusOnNotebookBecomesCurrentProject() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "士不可以不弘毅"))
        let notebook = try db.createNotebook(title: "何以为士")
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight, highlightId: h.id)], into: notebook.id!, after: nil)
        try db.setLearningFocus(LearningFocus(kind: .notebook, id: notebook.id!, title: "何以为士", startedAt: day(-3)))
        try db.writer.write { try AppDatabase.convertLearningFocusToProject(in: $0, now: now) }

        let projects = try db.researchProjects()
        XCTAssertEqual(projects.count, 1)
        let p = try XCTUnwrap(projects.first)
        XCTAssertEqual(p.title, "何以为士")
        XCTAssertEqual(p.kind, .other)
        XCTAssertEqual(p.stage, .material)
        XCTAssertEqual(try db.researchProjectLinks(projectId: p.id!).map(\.recordId), [notebook.id!])
        let focus = try XCTUnwrap(try db.validatedLearningFocus())
        XCTAssertEqual(focus.kind, .project)
        XCTAssertEqual(focus.id, p.id)
        XCTAssertEqual(focus.startedAt, day(-3), "焦点的起始日期保留")
        XCTAssertEqual(try db.reviewBias(now: now, focus: focus).multipliers[h.id!], ReviewBias.focusBoost, "回顾加权照旧")
        // 已经是项目的焦点不再转换
        try db.writer.write { try AppDatabase.convertLearningFocusToProject(in: $0, now: now) }
        XCTAssertEqual(try db.researchProjects().count, 1)
    }

    func testFocusOnDeletedSourceIsDroppedAndFreshLibraryHasNoProject() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertTrue(try db.researchProjects().isEmpty, "新库没有项目")
        try db.setLearningFocus(LearningFocus(kind: .source, id: 999, title: "已删除"))
        try db.writer.write { try AppDatabase.convertLearningFocusToProject(in: $0, now: now) }
        XCTAssertTrue(try db.researchProjects().isEmpty)
        XCTAssertNil(try db.learningFocus())
    }

    // MARK: 材料与关联

    func testProjectMaterialsAreUnionAndFollowDeletions() throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "国史大纲"))
        let a = try db.save(Highlight(sourceId: source.id, text: "温情与敬意"))
        let b = try db.save(Highlight(sourceId: source.id, text: "对本国历史应略有所知"))
        let c = try db.save(Highlight(text: "未归类"))
        let notebook = try db.createNotebook(title: "史学")
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight, highlightId: a.id),
                                 NotebookBlock(notebookId: notebook.id!, position: 2, kind: .highlight, highlightId: c.id)], into: notebook.id!, after: nil)
        let p = try db.saveResearchProject(ResearchProject(title: "钱穆史学"), now: now)
        try db.linkToResearchProject(p.id!, kind: .notebook, recordId: notebook.id!)
        try db.linkToResearchProject(p.id!, kind: .source, recordId: source.id!)
        try db.linkToResearchProject(p.id!, kind: .source, recordId: source.id!) // 重复归入无效
        let focus = LearningFocus(kind: .project, id: p.id!, title: p.title)
        XCTAssertEqual(try db.focusHighlightIDs(focus), [a.id!, b.id!, c.id!])
        let links = try db.researchProjectLinks(projectId: p.id!)
        XCTAssertEqual(links.map(\.kind), [.notebook, .source], "笔记本在前")
        XCTAssertEqual(links.map(\.highlightCount), [2, 2])
        XCTAssertEqual(try db.researchProjects(containing: .source, recordId: source.id!).map(\.id), [p.id])

        try db.deleteNotebook(notebook.id!)
        XCTAssertEqual(try db.researchProjectLinks(projectId: p.id!).map(\.kind), [.source], "笔记本删除后关联随之去掉")
        XCTAssertEqual(try db.focusHighlightIDs(focus), [a.id!, b.id!])
        try db.deleteSources([source.id!])
        XCTAssertTrue(try db.researchProjectLinks(projectId: p.id!).isEmpty)
        XCTAssertNotNil(try db.researchProject(id: p.id!), "材料删除不删项目")
    }

    // MARK: 阶段、归档、排序

    func testStageHistoryArchiveAndOrdering() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var p = try db.saveResearchProject(ResearchProject(title: "  晚明讲学  ", kind: .paper, targetWords: 0), now: day(-10))
        XCTAssertEqual(p.title, "晚明讲学", "题目去掉首尾空白")
        XCTAssertNil(p.targetWords, "0 视为不设目标字数")
        p.stage = .material
        p = try db.saveResearchProject(p, now: day(-5))
        try db.setResearchProjectStage(id: p.id!, stage: .material, now: day(-4)) // 未变化，不记录
        try db.setResearchProjectStage(id: p.id!, stage: .draft, now: day(-1))
        var o = try await db.researchProjectOverview(id: p.id!)
        XCTAssertEqual(o.stages.map(\.stage), [.draft, .material, .idea], "新的在前")
        XCTAssertEqual(o.project.stage, .draft)
        XCTAssertThrowsError(try db.saveResearchProject(ResearchProject(title: "  ")))

        let due = try db.saveResearchProject(ResearchProject(title: "有截止", dueDate: day(30)), now: now)
        let later = try db.saveResearchProject(ResearchProject(title: "更晚截止", dueDate: day(60)), now: now)
        XCTAssertEqual(try db.researchProjects().map(\.title), ["有截止", "更晚截止", "晚明讲学"], "按截止日期，无截止的在后")

        try db.setLearningFocus(LearningFocus(kind: .project, id: due.id!, title: due.title))
        try db.setResearchProjectArchived(id: due.id!, archived: true, now: now)
        XCTAssertNil(try db.learningFocus(), "归档当前项目时取消当前项目")
        XCTAssertEqual(try db.researchProjects().map(\.id), [later.id, p.id])
        XCTAssertEqual(try db.researchProjects(includeArchived: true).last?.id, due.id, "归档的排最后")
        try db.setResearchProjectArchived(id: due.id!, archived: false, now: now)
        XCTAssertEqual(try db.researchProjects().first?.id, due.id)

        try db.deleteResearchProject(id: p.id!)
        await XCTAssertThrowsErrorAsync(try await db.researchProjectOverview(id: p.id!))
        o = try await db.researchProjectOverview(id: later.id!)
        XCTAssertTrue(o.stages.count == 1)
    }

    func testDaysLeft() {
        let p = ResearchProject(title: "x", dueDate: calendar.date(from: .init(year: 2026, month: 12, day: 31, hour: 0)))
        XCTAssertEqual(p.daysLeft(now: now, calendar: calendar), 71)
        XCTAssertNil(ResearchProject(title: "y").daysLeft(now: now, calendar: calendar))
    }

    // MARK: 项目页汇总

    func testOverviewCollectsPlansQuestionsAndDedupedMaterials() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "论语译注"))
        let h = try db.save(Highlight(sourceId: source.id, text: "学而时习之"))
        _ = try db.save(Card(front: "学而", highlightId: h.id))
        let notebook = try db.createNotebook(title: "论语专题")
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight, highlightId: h.id)], into: notebook.id!, after: nil)
        let other = try db.createNotebook(title: "无关")
        let p = try db.saveResearchProject(ResearchProject(title: "论语译注修订", kind: .book), now: now)
        try db.linkToResearchProject(p.id!, kind: .notebook, recordId: notebook.id!)
        try db.linkToResearchProject(p.id!, kind: .source, recordId: source.id!)

        let link = LearningPlanLink(kind: .project, recordID: p.id!, title: p.title)
        XCTAssertEqual(link.kind.rawValue, "research_project", "原始值即表名")
        var later = LearningPlan(title: "改第二章", link: link); later.dueDate = day(5)
        var sooner = LearningPlan(title: "核引文", link: link); sooner.dueDate = day(1)
        var done = LearningPlan(title: "已完成", link: link); done.completedAt = now
        var cancelled = LearningPlan(title: "已取消", link: link); cancelled.cancelledAt = now
        for plan in [later, sooner, done, cancelled, LearningPlan(title: "无关计划")] { try db.saveLearningPlan(plan) }
        let open = TopicQuestion(notebookID: notebook.id!, question: "学与习之别？")
        var solved = TopicQuestion(notebookID: notebook.id!, question: "已解决"); solved.solvedAt = now
        let elsewhere = TopicQuestion(notebookID: other.id!, question: "别处的问题")
        for q in [open, solved, elsewhere] { try db.saveProgress(q, key: q.key) }

        let o = try await db.researchProjectOverview(id: p.id!)
        XCTAssertEqual(o.highlightCount, 1, "笔记本与出处中的同一条摘录只计一次")
        XCTAssertEqual(o.cardCount, 1)
        XCTAssertEqual(o.pendingPlans.map(\.title), ["核引文", "改第二章"], "只列未完成、未取消的，按日期")
        XCTAssertEqual(o.openQuestions.map(\.question), ["学与习之别？"])
        XCTAssertTrue(try await db.planLinkExists(link))
        let choices = try await db.planLinkChoices(kind: .project, query: "论语")
        XCTAssertEqual(choices.items.map(\.recordID), [p.id!])
    }

    // MARK: 界面状态

    func testStoreCreatesLinksAndSetsCurrentProject() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let source = try db.save(Source(title: "中国近三百年学术史"))
            _ = try db.save(Highlight(sourceId: source.id, text: "经世致用"))
            let store = LibraryStore(db: db)
            store.newResearchProject(linking: ResearchProjectPendingLink(kind: .source, recordId: source.id!))
            XCTAssertNotNil(store.researchProjectEditor)
            var draft = try XCTUnwrap(store.researchProjectEditor)
            draft.title = "清代学术史讲稿"; draft.kind = .lecture
            let first = try XCTUnwrap(store.saveResearchProject(draft))
            XCTAssertEqual(store.selection, .project(first.id!), "新建后打开项目页")
            XCTAssertEqual(store.currentProjectID, first.id, "没有当前项目时自动设为当前")
            XCTAssertEqual(store.learningFocus?.label, "项目《清代学术史讲稿》")
            XCTAssertEqual(store.researchProjects(containing: .source, recordId: source.id!).map(\.id), [first.id])
            XCTAssertEqual(store.focusHighlightIDs.count, 1)

            store.newResearchProject()
            var second = try XCTUnwrap(store.researchProjectEditor)
            second.title = "第二个项目"
            let saved = try XCTUnwrap(store.saveResearchProject(second))
            XCTAssertEqual(store.currentProjectID, first.id, "已有当前项目时不替换")
            store.setCurrentProject(saved)
            XCTAssertEqual(store.currentProjectID, saved.id)
            XCTAssertTrue(store.focusHighlightIDs.isEmpty, "第二个项目还没有材料")

            var renamed = saved; renamed.title = "改名后的项目"
            store.saveResearchProject(renamed)
            XCTAssertEqual(store.learningFocus?.title, "改名后的项目", "改名同步到当前项目")

            store.deleteResearchProject(renamed)
            XCTAssertEqual(store.selection, .projects)
            XCTAssertNil(store.currentProjectID)
            XCTAssertEqual(store.researchProjects.map(\.id), [first.id])
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("应当抛出错误", file: file, line: line) } catch {}
}
