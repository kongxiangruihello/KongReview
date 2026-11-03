import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.0-a：研究项目——迁移、材料并集、阶段记录、归档、项目页汇总、当前项目
final class V40ResearchProjectTests: XCTestCase {
    // 6.0.1：这里测的是已舍弃、代码暂留到成绩册（6.0.4）的旧功能——测试时临时打开
    override func setUp() { super.setUp(); SlimSwitch.featuresOff = false }
    override func tearDown() { SlimSwitch.featuresOff = true; super.tearDown() }

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



    // MARK: 项目页汇总


    // MARK: 界面状态

}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("应当抛出错误", file: file, line: line) } catch {}
}
