import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 4.0-c：侧栏六组的折叠状态记住；首页当前项目卡依赖的数据
final class V40SidebarTests: XCTestCase {
    // 6.0.1：这里测的是已舍弃、代码暂留到成绩册（6.0.4）的旧功能——测试时临时打开
    override func setUp() { super.setUp(); SlimSwitch.featuresOff = false }
    override func tearDown() { SlimSwitch.featuresOff = true; super.tearDown() }

    func testSidebarGroupExpansionIsRemembered() throws {
        try MainActor.assumeIsolated {
            let key = "sidebar.collapsedGroups"
            let saved = UserDefaults.standard.object(forKey: key)
            defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            UserDefaults.standard.removeObject(forKey: key)
            let store = LibraryStore(db: try AppDatabase(DatabaseQueue()))
            let research = store.sidebarGroupBinding("research")
            XCTAssertTrue(research.wrappedValue, "默认展开")
            research.wrappedValue = false
            XCTAssertFalse(store.sidebarGroupBinding("research").wrappedValue)
            XCTAssertTrue(store.sidebarGroupBinding("today").wrappedValue, "其他组不受影响")
            XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), ["research"])
            let reopened = LibraryStore(db: try AppDatabase(DatabaseQueue()))
            XCTAssertFalse(reopened.sidebarGroupBinding("research").wrappedValue, "重启后仍折叠")
            reopened.sidebarGroupBinding("research").wrappedValue = true
            XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), [])
        }
    }

    func testCurrentProjectFollowsArchiveAndHomeCardData() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let p = try db.saveResearchProject(ResearchProject(title: "讲稿", kind: .lecture))
        let notebook = try db.createNotebook(title: "讲稿底本")
        try db.linkToResearchProject(p.id!, kind: .notebook, recordId: notebook.id!)
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 0, kind: .text, text: "第一讲：何以为士")], into: notebook.id!, after: nil)
        try await MainActor.run {
            let store = LibraryStore(db: db)
            store.setCurrentProject(store.researchProjects.first)
            XCTAssertEqual(store.currentProject?.title, "讲稿")
            store.setResearchProjectArchived(try XCTUnwrap(store.currentProject), true)
            XCTAssertNil(store.currentProject, "归档后首页不再显示为当前项目")
            XCTAssertTrue(store.researchProjects.isEmpty)
        }
        let week = GrowthPeriod.week.window(containing: Date())
        let w = try await db.projectWritingSummary(projectId: p.id!, start: week.start, end: week.end)
        XCTAssertEqual(w.added, 7, "本周写作：第一讲何以为士")
    }
}
