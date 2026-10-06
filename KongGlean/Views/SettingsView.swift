import SwiftUI
import AppKit
import KongGleanCore

enum SettingsKeys {
    static let dailyCount = "review.dailyCount"
    static let masteryLimit = "review.masteryLimit"
    static let reminderEnabled = "reminder.enabled"
    static let reminderHour = "reminder.hour"
    static let reminderMinute = "reminder.minute"
}

struct SettingsView: View {
    var body: some View {
        TabView {
            QuickCaptureSettings()
                .tabItem { Label("快速录入", systemImage: "keyboard") }
            ReviewSettings()
                .tabItem { Label("回顾", systemImage: "sun.max") }
            CaptureSettings()
                .tabItem { Label("摘录", systemImage: "square.and.arrow.down") }
            DataSettings()
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct QuickCaptureSettings: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("menubar.visible") private var showMenuBarIcon = true
    @AppStorage(HotKeyPreset.defaultsKey) private var presetRaw = HotKeyPreset.ctrlOptK.rawValue

    var body: some View {
        // 读取 revision，使登录项状态等非观察值在操作后刷新
        let _ = store.revision
        Form {
            Section {
                Picker("全局快捷键", selection: $presetRaw) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: presetRaw) {
                    HotKeyCenter.shared.apply(HotKeyPreset.current)
                    store.reload()
                }
                if HotKeyCenter.shared.lastRegistrationFailed {
                    Text("这个快捷键已被其他应用占用，请换一个。")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("在任何应用里按下快捷键，弹出快速录入浮窗。剪贴板里有新复制的文字时会自动填入。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("现在试一下") { QuickCaptureController.shared.show() }
            }
            Section {
                Toggle("在菜单栏显示图标", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { StatusItemController.shared.apply() }
                Toggle("登录时自动启动", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { on in
                        do { try LoginItem.setEnabled(on) } catch { store.report(error) }
                        store.reload()
                    }
                ))
                Text("关闭主窗口后 KongGlean 仍在后台运行，快捷键与菜单栏图标照常可用；要完全退出请用 ⌘Q。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewSettings: View {
    @AppStorage(SettingsKeys.dailyCount) private var dailyCount = 10
    @AppStorage(SettingsKeys.masteryLimit) private var masteryLimit = 5
    @AppStorage(SettingsKeys.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKeys.reminderHour) private var hour = 8
    @AppStorage(SettingsKeys.reminderMinute) private var minute = 0

    var body: some View {
        Form {
            Stepper("每日回顾条数：\(dailyCount)", value: $dailyCount, in: 3...50)
            Stepper("每日记忆卡上限：\(masteryLimit)", value: $masteryLimit, in: 0...50)
            Text("改动从明天（或点“再抽一组”）开始生效。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("每日提醒", isOn: $reminderEnabled)
            DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                .disabled(!reminderEnabled)
        }
        .formStyle(.grouped)
        .onChange(of: reminderEnabled) { ReminderScheduler.shared.applySavedSettings() }
        .onChange(of: hour) { ReminderScheduler.shared.applySavedSettings() }
        .onChange(of: minute) { ReminderScheduler.shared.applySavedSettings() }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                hour = c.hour ?? 8
                minute = c.minute ?? 0
            }
        )
    }
}

private struct CaptureSettings: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let _ = store.revision
        Form {
            Section("浏览器书签小程序") {
                Text("在浏览器中新建一个书签，把下面的代码粘贴到“网址”栏。阅读网页时选中文字、点这个书签，就会弹出快速录入浮窗，正文、标题与网址已自动填好。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("复制“摘录选中文字”书签") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CaptureRequest.bookmarklet, forType: .string)
                    }
                    Spacer()
                }
                Text("另一个书签“整页存档”：点一下就把当前网页整篇存进 KongGlean 的“网页存档”，之后在应用里阅读、划线。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("复制“整页存档”书签") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CaptureRequest.saveBookmarklet, forType: .string)
                    }
                    Spacer()
                }
            }
            Section("引文体例") {
                Picker("复制、导出时使用", selection: Binding(
                    get: { CitationSettings.style },
                    set: { CitationSettings.style = $0; store.reload() }
                )) {
                    ForEach(CitationStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("GB/T 7714 需要出版地、出版者、年份；论文还需要期刊名和卷期。可在“编辑出处”里补全。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("链接格式（供快捷指令、kongfetch 调用）") {
                Text("kongglean://add?text=…&title=…&author=…&url=…&location=…&tags=…\nkongglean://quick（打开空白浮窗）\nkongglean://review（打开今日回顾）\nkongglean://save?url=…（整页存档）")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("链接会打开快速录入浮窗并预先填好内容，确认后按 ⌘↩ 保存。Drafts、kongfetch 的配置方法见仓库中的 docs/INTEGRATIONS.md。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let _ = store.revision
        Form {
            Section("自动备份") {
                Picker("备份位置", selection: Binding(
                    get: { BackupService.location },
                    set: { BackupService.location = $0; store.reload() }
                )) {
                    ForEach(BackupService.Location.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if BackupService.location == .icloud && !BackupService.isICloudAvailable {
                    Text("未检测到 iCloud 云盘，暂时备份到本机。").font(.caption).foregroundStyle(.orange)
                }
                Text("每天第一次启动时自动备份一次，保留最近 \(BackupService.keepCount) 份。"
                     + (BackupService.lastBackupDate.map { "上次备份：\($0.formatted(date: .abbreviated, time: .shortened))。" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("立即备份") { ExportService.backupNow(store: store) }
                    Button("打开备份文件夹") {
                        if let dir = try? BackupService.directory() {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                }
            }
            Section("存储") {
                Text("全部数据保存在一个 SQLite 文件中。删除的摘录在“最近删除”里保留 30 天。")
                    .font(.callout)
                Button("在访达中显示数据文件夹") {
                    if let dir = try? FileManager.default
                        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                        .appendingPathComponent("KongGlean") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
            Section("导入") {
                Button("从 Readwise 导入 CSV…") { ExportService.importReadwiseCSV(store: store) }
                Text("在 readwise.io/export 选择 CSV 下载。可重复导入同一文件，已存在的摘录会自动跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("导出") {
                Button("导出全部为 Markdown（每个出处一个文件）…") {
                    ExportService.exportAll(store: store)
                }
            }
        }
        .formStyle(.grouped)
    }
}
