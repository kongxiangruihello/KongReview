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

    /// 图标旁显示“今日待看摘录 · 待学卡片”（如 8·23）；都为 0 或在设置里关掉时只显示图标
    func updateCounts() {
        guard let button = item?.button else { return }
        guard CardSettings.menuBarCounts, let store = QuickCaptureController.shared.store else {
            button.title = ""
            item?.length = NSStatusItem.squareLength
            return
        }
        let c = store.todayCounts()
        if c.highlights == 0 && c.cards == 0 {
            button.title = ""
            item?.length = NSStatusItem.squareLength
        } else {
            button.title = " \(c.highlights)·\(c.cards)"
            button.imagePosition = .imageLeading
            item?.length = NSStatusItem.variableLength
        }
        button.toolTip = "今日试卷：摘录题还剩 \(c.highlights) 道，记忆卡 \(c.cards) 道"
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 与 App 图标同款（单色模板图）；万一解码失败退回系统符号
            button.image = MenuBarIcon.image() ?? NSImage(systemSymbolName: "text.quote", accessibilityDescription: "KongReview")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        updateCounts()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "快速录入（\(HotKeyPreset.current.label)）", #selector(quickCapture))
        // 6.2：随手札记
        add(menu, "随手札记" + (HotKeyPreset.note == .off ? "" : "（\(HotKeyPreset.note.label)）"), #selector(quickNote))
        if let left = QuickCaptureController.shared.store?.dailyCheck.left, left > 0 {
            add(menu, "今日试卷（还有 \(left) 题）", #selector(review))
        } else {
            add(menu, "今日试卷", #selector(review))
        }
        add(menu, "记忆卡（牌组）", #selector(cards))
        add(menu, "打开 KongReview", #selector(openMain))
        menu.addItem(.separator())
        add(menu, "立即备份", #selector(backup))
        add(menu, "设置…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "退出 KongReview", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func quickCapture() { QuickCaptureController.shared.show() }
    @objc private func quickNote() { QuickNoteController.shared.show() }

    @objc private func review() {
        QuickCaptureController.shared.store?.openExam()
        WindowOpener.showMain()
    }

    @objc private func openMain() { WindowOpener.showMain() }

    @objc private func cards() {
        QuickCaptureController.shared.store?.openCardsHome()
        WindowOpener.showMain()
    }

    @objc private func backup() {
        if let store = QuickCaptureController.shared.store { ExportService.backupNow(store: store) }
    }

    @objc private func openSettings() {
        WindowOpener.openSettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
