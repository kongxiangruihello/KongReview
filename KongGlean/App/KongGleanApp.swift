import SwiftUI
import KongGleanCore

@main
struct KongGleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("menubar.visible") private var showMenuBarIcon = true

    // 不用 @State：命令行工具链缺少 SwiftUIMacros 插件（macOS 27 SDK 起 @State 是宏）。
    // App 结构体只创建一次，直接持有即可。
    private let store: LibraryStore

    init() {
        let db: AppDatabase
        do {
            db = try AppDatabase.makeShared()
        } catch {
            // 数据库打不开时不要静默丢数据：直接终止并给出原因
            fatalError("无法打开 KongGlean 数据库：\(error)")
        }
        let store = LibraryStore(db: db)
        self.store = store
        QuickCaptureController.shared.store = store
    }

    var body: some Scene {
        Window("KongGlean", id: "main") {
            ContentView()
                .environment(store)
                .task { ReminderScheduler.shared.applySavedSettings() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建摘录") { store.newHighlight() }
                    .keyboardShortcut("n")
                Button("快速录入浮窗") { QuickCaptureController.shared.show() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("新建出处") {
                    store.editingSource = Source(title: "")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("回顾") {
                Button("今日回顾") { store.selection = .review }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("导出全部为 Markdown…") { ExportService.exportAll(store: store) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("立即备份") { ExportService.backupNow(store: store) }
            }
        }

        MenuBarExtra("KongGlean", systemImage: "text.quote", isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environment(store)
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// 菜单栏图标的菜单
struct MenuBarContent: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("快速录入（\(HotKeyPreset.current.label)）") {
            QuickCaptureController.shared.show()
        }
        Button("今日回顾") {
            store.selection = .review
            show()
        }
        Button("打开 KongGlean") { show() }
        Divider()
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 KongGlean") { NSApp.terminate(nil) }
    }

    private func show() {
        WindowOpener.openMain = { openWindow(id: "main") }
        WindowOpener.showMain()
    }
}
