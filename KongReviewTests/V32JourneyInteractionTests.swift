import XCTest
import SwiftUI
import AppKit
import GRDB
@testable import KongReview

@MainActor final class V32JourneyInteractionTests: XCTestCase {
    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to:selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
    private func nodes(_ root: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 24, let node = root as? NSObject else { return [] }
        return [node] + ((attribute(node,"accessibilityChildren") as? [Any]) ?? []).flatMap { nodes($0,depth:depth+1) }
    }
    private func host<V: View>(_ view: V, width: CGFloat = 900) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:view.frame(width:width,height:900,alignment:.top).environment(\.locale,Locale(identifier:"zh_CN")))
        window.title = "KongReview · 独立示例数据测试"
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
    private func pump() async throws { try await Task.sleep(for:.milliseconds(400)) }
    private func press(_ title: String, in window: NSWindow) throws {
        let all = nodes(window.contentView!)
        guard all.contains(where:{ attribute($0,"accessibilityLabel") != nil || attribute($0,"accessibilityTitle") != nil }) else {
            throw XCTSkip("当前命令行测试宿主未暴露原生辅助功能树，无法验证按钮点击。")
        }
        let button = try XCTUnwrap(all.first { (attribute($0,"accessibilityLabel") as? String) == title || (attribute($0,"accessibilityTitle") as? String) == title },"未找到按钮：\(title)，节点：\(all.compactMap { attribute($0,"accessibilityLabel") as? String }.joined(separator:" | "))")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard button.responds(to:selector) else { XCTFail("按钮没有点击动作"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(button.method(for:selector),to:Press.self)
        XCTAssertTrue(action(button,selector))
    }
    func testBatchPlanSaveViaNativeButton() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let active = LibraryStore(db:db,positionDefaults:nil)
        let plan = LearningPlan(title:"1. 核对史料\n2. 整理出处")
        var closed = false
        let window = host(LearningPlanForm(plan:plan,recovered:.init(plan:plan,splitLines:true)) { closed = true }.environment(active),width:560)
        defer { window.close() }
        try await pump()
        let draft = try db.progressValue(LearningPlanDraft.self,key:"plan-draft.\(plan.id.uuidString)")
        XCTAssertNotNil(draft)
        try press("保存这些计划",in:window); try await pump()
        let plans = try await db.planPage(status:.pending)
        XCTAssertEqual(plans.total,2); XCTAssertTrue(closed)
        XCTAssertNil(try db.progressValue(LearningPlanDraft.self,key:"plan-draft.\(plan.id.uuidString)"))
    }
    func testPlanButtonsCompleteRestoreAndCancel() async throws {
        let db = try AppDatabase(DatabaseQueue()), plan = LearningPlan(title:"测试计划")
        try db.saveLearningPlan(plan)
        let store = LibraryStore(db:db,positionDefaults:nil)
        let window = host(LearningPlansView().environment(store))
        defer { window.close() }
        try await pump()
        try press("标为完成",in:window); try await pump()
        let completionSheet = try XCTUnwrap(window.attachedSheet)
        try press("确认完成",in:completionSheet); try await pump()
        XCTAssertNotNil(try db.progressValue(LearningPlan.self,key:plan.key)?.completedAt)
        store.journeyNavigation.planStatus = .completed; try await pump()
        try press("恢复为待办",in:window); try await pump()
        store.journeyNavigation.planStatus = .pending; try await pump()
        try press("取消计划",in:window); try await pump()
        XCTAssertNotNil(try db.progressValue(LearningPlan.self,key:plan.key)?.cancelledAt)
        store.journeyNavigation.planStatus = .cancelled; try await pump()
        try press("恢复为待办",in:window); try await pump()
        XCTAssertNil(try db.progressValue(LearningPlan.self,key:plan.key)?.cancelledAt)
    }
}
