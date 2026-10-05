import SwiftUI
import KongGleanCore

@main
struct KongGleanApp: App {
    @State private var store: LibraryStore

    init() {
        let db: AppDatabase
        do {
            db = try AppDatabase.makeShared()
        } catch {
            // 数据库打不开时不要静默丢数据：直接终止并给出原因
            fatalError("无法打开 KongGlean 数据库：\(error)")
        }
        _store = State(initialValue: LibraryStore(db: db))
    }

    var body: some Scene {
        // 用单窗口 Window，kongglean:// 链接不会额外打开新窗口
        Window("KongGlean", id: "main") {
            ContentView()
                .environment(store)
                .onOpenURL { url in store.handle(url: url) }
                .task { ReminderScheduler.shared.applySavedSettings() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建摘录") { store.newHighlight() }
                    .keyboardShortcut("n")
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
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
