import AppKit
import SwiftUI

/// 6.2：随手札记浮窗——在任何应用里（包括做题时）随手写一条札记。
/// 浮在最前、不占主窗口：今日试卷上的题、展开与否、“我的回答”都留着，写完接着答。
/// 内容与“记札记”面板相同（新写一条，或把摘录加入已有札记），保存后浮窗收起。
@MainActor
final class QuickNoteController {
    static let shared = QuickNoteController()

    private var panel: QuickCapturePanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ composer: IdeaNoteComposer = IdeaNoteComposer()) {
        guard let store = QuickCaptureController.shared.store, !store.fullBackupBusy else { NSSound.beep(); return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // 每次打开都换一份新内容（上一次没保存的不带过来）
        panel.contentView = NSHostingView(rootView:
            IdeaNoteComposerSheet(composer: composer, onClose: { [weak self] in self?.close() })
                .environment(store)
        )
        if !panel.isVisible { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "随手札记"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }
}
