import AppKit
import ServiceManagement
import KongReviewCore

/// 负责 SwiftUI 不方便处理的系统级事务：kongreview:// 链接、全局快捷键、启动维护。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 自己接管 URL 事件：链接直接打开快速录入浮窗，不把主窗口拉到前台
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.action = { QuickCaptureController.shared.show() }
        HotKeyCenter.shared.apply(HotKeyPreset.current)
        StatusItemController.shared.apply()
        QuickCaptureController.shared.store?.runStartupMaintenance()

        // 提醒与“今天是否已回顾”挂钩：首次回顾后、跨日时重排通知
        QuickCaptureController.shared.store?.onReviewedToday = {
            ReminderScheduler.shared.applySavedSettings()
        }
        ReminderScheduler.shared.applySavedSettings()

        // 跨日（含睡眠唤醒后跨了日）与回到前台时检查日期：回顾换新、统计与提醒刷新
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        // 兜底：每 10 分钟查一次（有些情况下系统不发跨日通知）
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        BrowserWatcher.shared.start()
    }

    /// 关掉主窗口后应用继续在后台运行（快捷键、菜单栏图标仍可用）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string),
              let route = CaptureRequest.route(for: url)
        else { return }

        switch route {
        case .add(let capture):
            QuickCaptureController.shared.show(prefill: capture)
        case .quick(let capture):
            QuickCaptureController.shared.show(prefill: capture)
        case .review:
            QuickCaptureController.shared.store?.selection = .review
            WindowOpener.showMain()
        case .save(let url):
            WindowOpener.showMain()
            QuickCaptureController.shared.store?.saveArticle(from: url.absoluteString)
        }
    }
}

/// 从 AppKit 代码里打开 / 唤回主窗口
@MainActor
enum WindowOpener {
    /// 由 SwiftUI 视图在出现时登记（包装 openWindow(id: "main")）
    static var openMain: (() -> Void)?
    /// 由 SwiftUI 视图登记（包装 @Environment(\.openSettings)）
    static var openSettingsAction: (() -> Void)?

    /// 打开设置窗口。
    /// macOS 14 起，旧办法 NSApp.sendAction("showSettingsWindow:") 已失效（系统只在日志里提示改用 SettingsLink / openSettings），
    /// 所以 0.6 菜单栏里的“设置…”点了没反应。现在优先调用 SwiftUI 的 openSettings；
    /// 主窗口从没打开过时，退而求其次去点应用菜单里的“设置…”菜单项。
    static func openSettings() {
        NSApp.activate()
        if let action = openSettingsAction {
            action()
        } else if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
        }
        // 设置窗口有时开在其他窗口后面：稍后把它提到最前
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.activate()
            let settings = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("设置")
            })
            settings?.makeKeyAndOrderFront(nil)
        }
    }

    static func showMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }
}

/// 登录时自动启动（SMAppService，macOS 13+）
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
