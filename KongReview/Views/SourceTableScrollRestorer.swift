import AppKit
import SwiftUI

/// SwiftUI Table 的行不能添加可供 ScrollViewReader 使用的 ID，
/// 因而只在出处表格的 AppKit 滚动视图中恢复位置，不改变行选择。
struct SourceTableScrollRestorer: NSViewRepresentable {
    var rowIDs: [Int64]
    var anchorID: Int64?
    var loadID: UUID
    var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.setAccessibilityElement(false)
        let coordinator = context.coordinator
        view.onAttachment = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.restoreWhenReady(in: view)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        let target: Target?
        if !isLoading, let anchorID, rowIDs.contains(anchorID) {
            target = Target(loadID: loadID, anchorID: anchorID, rowIDs: rowIDs)
        } else {
            target = nil
        }
        context.coordinator.update(target, in: view)
    }

    struct Target: Equatable {
        var loadID: UUID
        var anchorID: Int64
        var rowIDs: [Int64]
    }

    final class AttachmentView: NSView {
        var onAttachment: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttachment?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onAttachment?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private var target: Target?
        private var applied: Target?
        private var generation = 0
        private var attempts = 0
        private var isScheduled = false

        func update(_ newTarget: Target?, in view: NSView) {
            if target != newTarget {
                target = newTarget
                generation += 1
                attempts = 0
                isScheduled = false
            }
            restoreWhenReady(in: view)
        }

        func restoreWhenReady(in view: NSView) {
            guard let target, applied != target, view.window != nil,
                  !isScheduled, attempts < 8 else { return }
            let requestedGeneration = generation
            isScheduled = true
            // 等待 SwiftUI 完成表格行更新；首次建立表格最多短暂重试八次。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view, self.generation == requestedGeneration else { return }
                self.isScheduled = false
                guard self.target == target, view.window != nil,
                      let index = target.rowIDs.firstIndex(of: target.anchorID) else { return }
                self.attempts += 1
                if let table = Self.nearestSourceTable(to: view, rowCount: target.rowIDs.count),
                   index < table.numberOfRows {
                    table.enclosingScrollView?.layoutSubtreeIfNeeded()
                    table.layoutSubtreeIfNeeded()
                    table.scrollRowToVisible(index)
                    if table.visibleRect.intersects(table.rect(ofRow: index)) {
                        self.applied = target
                        return
                    }
                }
                self.restoreWhenReady(in: view)
            }
        }

        /// 选择包含挂载点的最近祖先下唯一的五列表格；侧栏 List 不符合列数。
        static func nearestSourceTable(to view: NSView, rowCount: Int) -> NSTableView? {
            var ancestor = view.superview
            while let container = ancestor {
                let tables = sourceTables(in: container, rowCount: rowCount)
                if tables.count == 1 { return tables[0] }
                if tables.count > 1 { return nil }
                ancestor = container.superview
            }
            return nil
        }

        private static func sourceTables(in view: NSView, rowCount: Int) -> [NSTableView] {
            guard !view.isHidden else { return [] }
            if let table = view as? NSTableView {
                return table.numberOfColumns == 5 && table.numberOfRows == rowCount ? [table] : []
            }
            return view.subviews.flatMap { sourceTables(in: $0, rowCount: rowCount) }
        }
    }
}
