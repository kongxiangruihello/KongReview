import AppKit

/// 菜单栏图标（纯 AppKit 实现）。
/// 0.2.0 用 SwiftUI 的 MenuBarExtra，配合 @AppStorage 的 isInserted 绑定，
/// 在 macOS 27 上引发整个 App 场景图反复重建、主线程 100% 占用，界面一点就卡死。
/// 改用 NSStatusItem 后与 SwiftUI 场景图完全无关。
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()
    static let visibleKey = "menubar.visible"

    private var item: NSStatusItem?

    static var isVisibleSetting: Bool {
        UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true
    }

    /// 按设置显示或移除图标
    func apply() {
        if Self.isVisibleSetting {
            install()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "KongGlean")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "快速录入（\(HotKeyPreset.current.label)）", #selector(quickCapture))
        add(menu, "存档网页…", #selector(addArticle))
        add(menu, "今日回顾", #selector(review))
        add(menu, "打开 KongGlean", #selector(openMain))
        menu.addItem(.separator())
        add(menu, "立即备份", #selector(backup))
        add(menu, "设置…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "退出 KongGlean", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func quickCapture() { QuickCaptureController.shared.show() }

    @objc private func review() {
        QuickCaptureController.shared.store?.selection = .review
        WindowOpener.showMain()
    }

    @objc private func openMain() { WindowOpener.showMain() }

    @objc private func addArticle() {
        WindowOpener.showMain()
        QuickCaptureController.shared.store?.showAddArticle()
    }

    @objc private func backup() {
        if let store = QuickCaptureController.shared.store { ExportService.backupNow(store: store) }
    }

    @objc private func openSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
