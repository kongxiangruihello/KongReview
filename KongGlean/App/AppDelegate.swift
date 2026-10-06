import AppKit
import ServiceManagement
import KongGleanCore

/// 负责 SwiftUI 不方便处理的系统级事务：kongglean:// 链接、全局快捷键、启动维护。
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
        QuickCaptureController.shared.store?.runStartupMaintenance()
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
        }
    }
}

/// 从 AppKit 代码里打开 / 唤回主窗口
@MainActor
enum WindowOpener {
    /// 由 SwiftUI 视图在出现时登记（包装 openWindow(id: "main")）
    static var openMain: (() -> Void)?

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
