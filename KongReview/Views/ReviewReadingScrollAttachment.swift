import AppKit
import SwiftUI

/// 挂在正文内部，定位它自己的 ScrollView，避开侧栏和网页编辑器的滚动视图。
/// 按语滚动期间不覆盖阅读位置；正文异步量高时反复恢复，直到用户主动接管。
struct ReviewReadingScrollAttachment: NSViewRepresentable {
    var owner: String
    var positions: ReviewReadingPositions
    var review: ReviewState
    var isEditing: Bool
    var restoreToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.setAccessibilityElement(false)
        view.onAttachment = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.attach(in: view) }
        }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.update(owner: owner, positions: positions, review: review, editing: isEditing,
                                   token: restoreToken, in: view)
    }
    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.detach() }

    final class AttachmentView: NSView {
        var onAttachment: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttachment?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onAttachment?() }
        override func layout() { super.layout(); onAttachment?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private var owner: String?
        private var positions: ReviewReadingPositions?
        private weak var review: ReviewState?
        private var editing = false
        private var token = -1
        private var restoring = true
        private var restoreOffset: Double = 0
        private var observers: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var scheduled = false

        func update(owner newOwner: String, positions: ReviewReadingPositions, review: ReviewState, editing newEditing: Bool,
                    token newToken: Int, in view: NSView) {
            let changed = owner != newOwner
            if changed { saveCurrentPosition() }
            let shouldRestore = changed || token != newToken || (editing && !newEditing)
            self.owner = newOwner
            self.positions = positions
            self.review = review
            editing = newEditing
            token = newToken
            if shouldRestore {
                restoreOffset = positions.offset(for: newOwner)
                restoring = !newEditing
            }
            if newEditing { restoring = false }
            attach(in: view)
        }

        func attach(in view: NSView) {
            guard let found = view.enclosingScrollView else { return }
            if scrollView !== found {
                removeObservers()
                scrollView = found
                found.contentView.postsBoundsChangedNotifications = true
                found.documentView?.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: found.contentView, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.saveCurrentPosition() }
                    })
                if let document = found.documentView {
                    observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                        object: document, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.restoreWhenReady() }
                        })
                }
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                    [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let scroll = self.scrollView, event.window === scroll.window else { return event }
                        let point = scroll.convert(event.locationInWindow, from: nil)
                        if scroll.bounds.contains(point) || event.type == .keyDown {
                            self.restoring = false
                        }
                        return event
                    }
                }
            }
            restoreWhenReady()
        }

        private func restoreWhenReady() {
            guard restoring, !editing, scrollView?.window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.restoring, !self.editing, let scroll = self.scrollView,
                      let document = scroll.documentView else { return }
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                let offset = min(CGFloat(self.restoreOffset), maximum)
                // 短暂的网页初始高度不能把已存位置覆盖为零。
                let y = document.isFlipped ? offset : maximum - offset
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func saveCurrentPosition() {
            guard !restoring, !editing, let owner, let scroll = scrollView,
                  let document = scroll.documentView else { return }
            // Observable 状态先变，AppKit 可能先夹缩旧布局，再调用 updateNSView。
            // 直接核对当前编辑/条目状态，避免这一小段时序把原阅读位置改成编辑器位置。
            if let review {
                guard review.noteDraft == nil, review.inlineDraft == nil,
                      review.cards.indices.contains(review.position),
                      ReviewReadingPositions.owner(day: review.day, scope: review.theme,
                        highlightID: review.cards[review.position].id) == owner else { return }
            }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = document.isFlipped ? scroll.contentView.bounds.minY : maximum - scroll.contentView.bounds.minY
            positions?.save(Double(max(0, offset)), for: owner)
        }

        func detach() {
            saveCurrentPosition()
            removeObservers()
            scrollView = nil
        }
        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }
}
