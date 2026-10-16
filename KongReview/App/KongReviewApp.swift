import SwiftUI
import KongReviewCore

@main
struct KongReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 注意：App 结构体里不要放 @AppStorage、可变绑定，也不要用 MenuBarExtra。
    // 0.2.0 的 MenuBarExtra(isInserted: $appStorage) 让整个 App 场景图反复重建，
    // 主线程 100% 占用、点哪里都卡死。菜单栏图标改由 AppKit 实现（StatusItem.swift）。

    // 不用 @State：命令行工具链缺少 SwiftUIMacros 插件（macOS 27 SDK 起 @State 是宏）。
    // App 结构体只创建一次，直接持有即可。
    private let store: LibraryStore

    init() {
        LegacyMigration.migrateSettings()
        let db: AppDatabase
        do {
            db = try AppDatabase.makeShared()
        } catch {
            // 数据库打不开时不要静默丢数据：直接终止并给出原因
            fatalError("无法打开 KongReview 数据库：\(error)")
        }
        var draftStorage: EditorDraftPersistence?
        var draftError: String?
        do { draftStorage = try EditorDraftPersistence(directory: EditorDraftPersistence.defaultDirectory()) }
        catch { draftError = "编辑草稿恢复暂不可用：" + error.localizedDescription }
        let store = LibraryStore(db: db, draftPersistence: draftStorage, positionDefaults: .standard)
        store.draftSaveError = draftError
        self.store = store
        QuickCaptureController.shared.store = store
    }

    var body: some Scene {
        Window("KongReview", id: "main") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建摘录") { store.newHighlight() }
                    .keyboardShortcut("n")
                Button("快速录入浮窗") { QuickCaptureController.shared.show() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("引文速查…") { CitationLookupController.shared.show() }
                Button("新建专题笔记本…") { store.newNotebookRequest = NewNotebookRequest() }
                Button("存档网页…") { store.showAddArticle() }
                    .keyboardShortcut("l")
                Button("新建出处") {
                    store.editingSource = Source(title: "")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("回顾") {
                Button("今日回顾") { store.openTodayReview(); WindowOpener.showMain() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("记忆卡") { store.openCardsHome(); WindowOpener.showMain() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("回顾统计") { store.selection = .stats }
            }
            CommandGroup(replacing: .help) {
                Button("KongReview 使用说明") {
                    store.selection = .help
                    WindowOpener.showMain()
                }
                Button("导出诊断信息…") { ExportService.exportDiagnostics(store: store) }
            }
            CommandGroup(after: .importExport) {
                Button("查找重复摘录…") { WindowOpener.showMain(); store.findDuplicates() }
                Divider()
                Button("导出全部为 Markdown…") { ExportService.exportAll(store: store) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("立即备份") { ExportService.backupNow(store: store) }
                Divider()
                Button("从 Readwise 导入 CSV…") { ExportService.importReadwiseCSV(store: store) }
                Button("从 LiquidText 导入笔记…") { ExportService.importLiquidText(store: store) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("从剪贴板导入 LiquidText 笔记") { ExportService.importLiquidTextFromClipboard(store: store) }
                Button("导入 Anki 牌组…") { ExportService.importAnki(store: store) }
                Button("导出记忆卡到 Anki…") {
                    let decks = (try? store.db.deckNames()) ?? []
                    store.selection = .cards
                    store.apkgExport = ApkgExportRequest(allDecks: decks, decks: Set(decks))
                }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
