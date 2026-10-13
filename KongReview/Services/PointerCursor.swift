import AppKit
import WebKit

// MARK: - 1.2：可点击的地方显示手形光标

/// 鼠标移到按钮、链接、复选框、弹出菜单上时显示手形光标（👆），离开时恢复。
///
/// SwiftUI 的按钮不是 NSButton，没有统一的光标设置；这里在应用层监听鼠标移动，用“辅助功能命中测试”
/// 判断鼠标下是不是可点击的控件（SwiftUI 会为每个按钮提供辅助功能信息，角色为“按钮”“链接”等）。
/// 节流：鼠标移动超过 2 点且距上次判断超过 40 毫秒才判断一次。网页视图（回顾正文、编辑器）自己管光标，不受影响。
@MainActor
enum PointerCursor {
    static let enabledKey = "ui.handCursor"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var monitor: Any?
    private static var lastPoint = NSPoint(x: -1000, y: -1000)
    private static var lastTime: TimeInterval = 0
    private static var showingHand = false

    private static let clickableRoles: Set<NSAccessibility.Role> = [
        .button, .link, .checkBox, .radioButton, .popUpButton, .menuButton, .disclosureTriangle,
    ]

    static func install() {
        guard monitor == nil else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { (note.object as? NSWindow)?.acceptsMouseMovedEvents = true }
            }
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .leftMouseUp]) { event in
            MainActor.assumeIsolated { update(for: event) }
            return event
        }
    }

    private static func update(for event: NSEvent) {
        guard isEnabled, let window = event.window, let content = window.contentView else {
            resetIfNeeded()
            return
        }
        let p = event.locationInWindow
        let now = event.timestamp
        let small = abs(p.x - lastPoint.x) < 2 && abs(p.y - lastPoint.y) < 2
        if event.type == .mouseMoved && (small || now - lastTime < 0.04) {
            if showingHand { NSCursor.pointingHand.set() }
            return
        }
        lastPoint = p
        lastTime = now

        // 网页视图自己设置光标
        if let hit = content.hitTest(content.superview?.convert(p, from: nil) ?? p), hit.isInsideWebView {
            showingHand = false
            return
        }
        let screen = window.convertPoint(toScreen: p)
        if isClickable(content.accessibilityHitTest(screen)) {
            NSCursor.pointingHand.set()
            showingHand = true
        } else {
            resetIfNeeded()
        }
    }

    private static func resetIfNeeded() {
        guard showingHand else { return }
        showingHand = false
        NSCursor.arrow.set()
    }

    /// 用传统的辅助功能属性接口读角色（对 SwiftUI 的元素同样有效）
    private static func isClickable(_ element: Any?) -> Bool {
        var cur = element as? NSObject
        // 命中的常是按钮里的文字或图标：最多往上看两层
        for _ in 0..<3 {
            guard let el = cur else { return false }
            if let role = el.accessibilityAttributeValue(.role) as? String {
                if clickableRoles.contains(NSAccessibility.Role(rawValue: role)) {
                    return (el.accessibilityAttributeValue(.enabled) as? Bool) ?? true
                }
                // 碰到文本框、列表、窗口等容器就停
                if role != NSAccessibility.Role.staticText.rawValue && role != NSAccessibility.Role.image.rawValue
                    && role != NSAccessibility.Role.group.rawValue {
                    return false
                }
            }
            cur = el.accessibilityAttributeValue(.parent) as? NSObject
        }
        return false
    }
}

private extension NSView {
    var isInsideWebView: Bool {
        var v: NSView? = self
        while let cur = v {
            if cur is WKWebView { return true }
            v = cur.superview
        }
        return false
    }
}
