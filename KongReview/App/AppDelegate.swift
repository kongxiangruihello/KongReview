import AppKit
import ServiceManagement
import KongReviewCore

/// 负责 SwiftUI 不方便处理的系统级事务：kongreview:// 链接、全局快捷键、启动维护。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !EditorValidation.isEnabled, !PreviewLibrary.isEnabled else { return }
        // 自己接管 URL 事件：链接直接打开快速录入浮窗，不把主窗口拉到前台
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 6.1.0：预览应用可用启动参数 -previewAppearance dark 以深色模式打开，便于逐页核对
        if PreviewLibrary.isEnabled, UserDefaults.standard.string(forKey: "previewAppearance") == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        guard !EditorValidation.isEnabled, !PreviewLibrary.isEnabled else { return }
        HotKeyCenter.shared.action = { QuickCaptureController.shared.show() }
        HotKeyCenter.shared.apply(HotKeyPreset.current)
        // 6.2：随手札记（任何应用里按快捷键）
        HotKeyCenter.shared.noteAction = { QuickNoteController.shared.show() }
        HotKeyCenter.shared.applyNote(HotKeyPreset.note)
        StatusItemController.shared.apply()
        ServiceProvider.install()
        QuickCaptureController.shared.store?.runStartupMaintenance()
        // 6.0.1：第一次打开时导出舍弃功能里的内容，并留一份数据库快照
        QuickCaptureController.shared.store?.runSlimUpgradeIfNeeded()

        // 提醒与“今天是否已回顾”挂钩：首次回顾后、跨日时重排通知
        QuickCaptureController.shared.store?.onReviewedToday = {
            ReminderScheduler.shared.applySavedSettings()
        }
        // 5.2.2：今天打卡后撤掉晚间打卡提醒
        QuickCaptureController.shared.store?.onCheckinChanged = {
            ReminderScheduler.shared.applyCheckinReminder()
        }
        // 5.0.1：完成复盘后重排每周复盘提醒（本周已复盘就不再提醒）
        QuickCaptureController.shared.store?.onReflectionChanged = {
            ReminderScheduler.shared.applySavedSettings()
        }
        // 每次数据变化后更新菜单栏上的数字
        QuickCaptureController.shared.store?.onReload = {
            StatusItemController.shared.updateCounts()
        }
        ReminderScheduler.shared.applySavedSettings()

        // 跨日（含睡眠唤醒后跨了日）与回到前台时检查日期：回顾换新、统计与提醒刷新
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                QuickCaptureController.shared.store?.checkDayChange()
                QuickCaptureController.shared.store?.checkInbox()
            }
        }
        // 收件箱：启动时与每分钟检查一次
        QuickCaptureController.shared.store?.checkInbox()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkInbox() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.store?.checkDayChange() }
        }
        // 兜底：每 10 分钟查一次（有些情况下系统不发跨日通知）
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated {
                QuickCaptureController.shared.store?.checkDayChange()
            }
        }
        // 6.0.1：引文速查、每周小结推送已舍弃。记下最近用的浏览器，供“服务”录入摘录时取网址
        BrowserWatcher.shared.start()

        // 6.0.2：点一下就更新——安装前先备份学习库；刚更新过就显示改动；启动 30 秒后与每 6 小时自动检查
        AppUpdater.shared.beforeInstall = {
            guard let s = QuickCaptureController.shared.store else { return }
            _ = try BackupService.backupNow(db: s.db)
        }
        AppUpdater.shared.launched()
    }

    /// 关掉主窗口后应用继续在后台运行（快捷键、菜单栏图标仍可用）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 1.5.1：关掉主窗口后应用仍在后台运行；点程序坞图标时把主窗口重新打开
    /// （单窗口的 SwiftUI Window 场景不会自动重开，以前点图标没有反应）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !WindowOpener.mainWindowVisible { WindowOpener.showMain() }
        return false
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
            QuickCaptureController.shared.store?.openExam()
            WindowOpener.showMain()
        case .save(let url):
            // 6.0.1：网页存档已舍弃；旧的“整页存档”书签改为把网址带进快速录入
            QuickCaptureController.shared.show(prefill: CaptureRequest(text: "", url: url.absoluteString))
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

    /// 主窗口（不含设置窗口、浮窗）
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { w in
            w.canBecomeMain && !(w is NSPanel)
                && w.identifier?.rawValue.contains("Settings") != true && !w.title.contains("设置")
        }
    }

    static var mainWindowVisible: Bool {
        mainWindows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    static func showMain() {
        NSApp.activate()
        if let window = mainWindows.first(where: { $0.isVisible || $0.isMiniaturized }) {
            bringToFront(window)
            return
        }
        if let open = openMain {
            open()
        } else if let windowMenu = NSApp.windowsMenu,
                  let index = windowMenu.items.firstIndex(where: { $0.title == "KongReview" }) {
            // 主窗口从未出现过（openMain 还没登记）：用“窗口”菜单里的同名项打开
            windowMenu.performActionForItem(at: index)
        } else if let window = mainWindows.first {
            bringToFront(window)
            return
        }
        // 新开的窗口有时在其他窗口后面：稍后提到最前
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if let w = mainWindows.first(where: { $0.isVisible || $0.isMiniaturized }) { bringToFront(w) }
        }
    }

    private static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        // 窗口落在已断开的显示器上时挪回主屏幕
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
