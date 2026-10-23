import SwiftUI
import AppKit
import ApplicationServices
import KongReviewCore

enum SettingsKeys {
    static let dailyCount = "review.dailyCount"
    static let masteryLimit = "review.masteryLimit"
    static let reminderEnabled = "reminder.enabled"
    static let reminderHour = "reminder.hour"
    static let reminderMinute = "reminder.minute"
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        TabView {
            QuickCaptureSettings()
                .tabItem { Label("快速录入", systemImage: "keyboard") }
            ReviewSettings()
                .tabItem { Label("回顾", systemImage: "sun.max") }
            CardSettingsTab()
                .tabItem { Label("记忆卡", systemImage: "brain") }
            CaptureSettings()
                .tabItem { Label("摘录", systemImage: "square.and.arrow.down") }
            DataSettings()
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .frame(width: 600, height: 500)
        .disabled(store.fullBackupBusy)
    }
}

private struct QuickCaptureSettings: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("menubar.visible") private var showMenuBarIcon = true
    @AppStorage(PointerCursor.enabledKey) private var handCursor = true
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
            Section("引文速查") {
                Picker("快捷键", selection: Binding(
                    get: { HotKeyPreset.lookup },
                    set: { p in
                        HotKeyPreset.lookup = p
                        HotKeyCenter.shared.applyLookup(p)
                        store.reload()
                    })) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                if HotKeyCenter.shared.lookupRegistrationFailed {
                    Text("这个快捷键已被其他应用占用，请换一个。").font(.caption).foregroundStyle(.red)
                }
                Text("写作时在任何应用里按快捷键，搜索摘录，回车把“原文 + 出处”粘到光标处。出处按“设置 → 摘录”里的引文体例生成。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("现在试一下") { CitationLookupController.shared.show() }
                    if AXIsProcessTrusted() {
                        Label("已允许自动粘贴", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    } else {
                        Button("允许自动粘贴…") { CitationLookupController.requestAccessibility() }
                    }
                }
                Text("自动粘贴要在“系统设置 → 隐私与安全性 → 辅助功能”里允许 KongReview（用来模拟按 ⌘V）。不允许也能用：选中后自动复制，自己按 ⌘V。注意：本应用是本机签名，每次重新构建安装后可能要重新勾选一次。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Toggle("鼠标移到按钮、链接上时显示手形光标", isOn: $handCursor)
                Text("关闭主窗口后 KongReview 仍在后台运行，快捷键与菜单栏图标照常可用；要完全退出请用 ⌘Q。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewSettings: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(SettingsKeys.dailyCount) private var dailyCount = 10
    @AppStorage(RevisitLimits.notesKey) private var revisitNotes = 2
    @AppStorage(RevisitLimits.questionsKey) private var revisitQuestions = 1
    @AppStorage(ReflectionReminderPlan.enabledKey) private var reflectionReminder = false
    @AppStorage(ReflectionReminderPlan.weekdayKey) private var reflectionWeekday = 1
    @AppStorage(ReflectionReminderPlan.hourKey) private var reflectionHour = 20
    @AppStorage(ReflectionReminderPlan.minuteKey) private var reflectionMinute = 0
    @AppStorage(SettingsKeys.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKeys.reminderHour) private var hour = 8
    @AppStorage(SettingsKeys.reminderMinute) private var minute = 0

    var body: some View {
        Form {
            Stepper("每日回顾条数：\(dailyCount)", value: $dailyCount, in: 3...50)
            Text("改动从明天（或点“再抽一组”）开始生效。")
                .font(.caption).foregroundStyle(.secondary)

            Section("重温（今日功课第三步）") {
                Stepper("每天至多重温札记：\(revisitNotes) 条", value: $revisitNotes, in: 0...10)
                Stepper("每天至多重温「常念」的问题：\(revisitQuestions) 个", value: $revisitQuestions, in: 0...5)
                Text("札记按 7、21、60、180、365 天的间隔回来，改过的从头算；「常念」且未解决的问题约每周回来一次。设为 0 即不重温这一类。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


            Section("提醒") {
                Toggle("每周一显示上周小结（回顾页顶部；已允许通知时另推送一条）", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: LibraryStore.digestEnabledKey) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: LibraryStore.digestEnabledKey); store.revisionBump() }
                ))
                Toggle("每日提醒", isOn: $reminderEnabled)
                DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!reminderEnabled)
                Text("当天已经回顾过（每日回顾看过一条，或复习过一张记忆卡），就不再提醒。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("每周复盘提醒", isOn: $reflectionReminder)
                Picker("提醒日", selection: $reflectionWeekday) {
                    ForEach(1...7, id: \.self) { Text("星期" + ["日", "一", "二", "三", "四", "五", "六"][$0 - 1]).tag($0) }
                }
                .disabled(!reflectionReminder)
                DatePicker("复盘提醒时间", selection: reflectionTimeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!reflectionReminder)
                Text("提醒做一次每周复盘（看数字、看新材料、看自己的想法、过一遍常念问题、写三句话）；这一周已复盘就不再提醒。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: revisitNotes) { store.refreshRevisit() }
        .onChange(of: revisitQuestions) { store.refreshRevisit() }
        .onChange(of: reflectionReminder) { ReminderScheduler.shared.applySavedSettings() }
        .onChange(of: reflectionWeekday) { ReminderScheduler.shared.applySavedSettings() }
        .onChange(of: reflectionHour) { ReminderScheduler.shared.applySavedSettings() }
        .onChange(of: reflectionMinute) { ReminderScheduler.shared.applySavedSettings() }
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

    private var reflectionTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: reflectionHour, minute: reflectionMinute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                reflectionHour = c.hour ?? 20
                reflectionMinute = c.minute ?? 0
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
                Text("另一个书签“整页存档”：点一下就把当前网页整篇存进 KongReview 的“网页存档”，之后在应用里阅读、划线。")
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
                Text("kongreview://add?text=…&title=…&author=…&url=…&location=…&tags=…\nkongreview://quick（打开空白浮窗）\nkongreview://review（打开今日回顾）\nkongreview://save?url=…（整页存档）")
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
    @AppStorage(LiquidTextFolder.enabledKey) private var ltEnabled = false
    @AppStorage(LiquidTextFolder.folderKey) private var ltFolder = ""
    @AppStorage(LiquidTextFolder.skipShortKey) private var ltSkipShort = false

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
                    Button("从备份恢复…") { store.showBackups() }
                    Button("打开备份文件夹") {
                        if let dir = try? BackupService.directory() {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                }
            }
            Section("完整备份与换机恢复") {
                Text("将资料、已存入应用的图片与音频、草稿和可迁移设置保存为一个文件。恢复前会校验并预览，随后另存恢复前的完整资料。")
                    .font(.callout)
                HStack {
                    Button("导出完整备份…") { store.exportFullBackup() }
                    Button("恢复完整备份…") { store.chooseFullBackupRestore() }
                }
            }
            Section("存储") {
                Text("全部数据保存在一个 SQLite 文件中。删除的摘录在“最近删除”里保留 30 天。")
                    .font(.callout)
                let f = ByteCountFormatter()
                LabeledContent("数据文件", value: f.string(fromByteCount: store.db.fileSize()))
                ForEach(Array(((try? store.db.storageBreakdown()) ?? []).enumerated()), id: \.offset) { _, item in
                    LabeledContent(item.0, value: f.string(fromByteCount: item.1))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("整理数据库…") { store.compactDatabase() }
                    .disabled(store.maintenanceProgress != nil)
                Text("删除没有卡片再用到的图片，并用 SQLite 的 VACUUM 收回删除数据后留下的空间。整理前自动备份。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("在访达中显示数据文件夹") {
                    if let dir = try? FileManager.default
                        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                        .appendingPathComponent("KongReview") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
            Section("自动同步到 Obsidian") {
                Toggle("摘录有改动时自动更新 Markdown 文件", isOn: Binding(
                    get: { ObsidianSync.isEnabled },
                    set: { on in
                        if on && ObsidianSync.folder == nil { chooseObsidianFolder() }
                        ObsidianSync.isEnabled = on && ObsidianSync.folder != nil
                        store.reload()
                    }))
                HStack {
                    Text(ObsidianSync.folder?.path ?? "未选择文件夹")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择文件夹…") { chooseObsidianFolder() }
                    Button("立即同步") { store.syncObsidianNow() }
                        .disabled(ObsidianSync.folder == nil)
                }
                Text("每个出处一个 .md 文件（YAML 头 + 引用块 + 按语、出处、标签）；札记写在“札记”子文件夹里，一条一个文件，文件名即题目，[[题目]] 链接在 Obsidian 里可直接跳转。建议选 Obsidian 库里的一个子文件夹，如“KongReview”。只在内容变化时写入；这些文件由 KongReview 生成，在 Obsidian 里的改动会在下次同步时被覆盖。"
                     + ((UserDefaults.standard.object(forKey: ObsidianSync.lastSyncKey) as? Date).map { "上次同步：\($0.formatted(date: .abbreviated, time: .shortened))。" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("收件箱（其他应用投递摘录）") {
                HStack {
                    Button("在访达中打开收件箱") {
                        try? FileManager.default.createDirectory(at: InboxService.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([InboxService.folder])
                    }
                    Button("立即检查") { store.checkInbox(quiet: false) }
                }
                Text("PDF 批注等应用把摘录写成 JSON 文件放进这个文件夹，KongReview 启动、回到前台时和每分钟自动导入（出处按标题 + 作者合并，重复投递不会重复导入）。格式见项目里的 docs/INTEGRATIONS.md。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("LiquidText 自动导入") {
                Toggle("自动导入这个文件夹里的 LiquidText 笔记", isOn: Binding(
                    get: { ltEnabled && !ltFolder.isEmpty },
                    set: { on in
                        if on && ltFolder.isEmpty { chooseLiquidTextFolder() }
                        ltEnabled = on && LiquidTextFolder.folder != nil
                        if ltEnabled { store.checkLiquidTextFolder(quiet: false) }
                    }))
                HStack {
                    Text(ltFolder.isEmpty ? "未选择文件夹" : ltFolder)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择文件夹…") { chooseLiquidTextFolder() }
                    Button("在访达中打开") {
                        if let f = LiquidTextFolder.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                    .disabled(ltFolder.isEmpty)
                    Button("立即检查") { store.checkLiquidTextFolder(quiet: false, force: true) }
                        .disabled(ltFolder.isEmpty)
                }
                Toggle("跳过很短的摘录（不足 4 个字，如只摘了人名）", isOn: $ltSkipShort)
                Text("在 LiquidText 里“导出 → 笔记 → Word”，保存到这个文件夹（建议在“文稿”里新建“LiquidText 导出”）。KongReview 启动、回到前台时和每分钟检查一次，只处理新出现或改动过的文件，不会移动或修改它们。同一本书重新导出整份笔记时，只导入新摘的；在 KongReview 里改过或删掉的摘录不会被加回来。导入的摘录带“LiquidText”标签。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("导入") {
                HStack {
                    Button("从 LiquidText 导入笔记…") { ExportService.importLiquidText(store: store) }
                    Button("从剪贴板导入") { ExportService.importLiquidTextFromClipboard(store: store) }
                }
                Text("在 LiquidText 里导出笔记为 Word（.docx），这里选中即可（可多选）；图片摘录一并导入。也可以在 LiquidText 里选中笔记 ⌘C，再点“从剪贴板导入”。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("从 Readwise 导入 CSV…") { ExportService.importReadwiseCSV(store: store) }
                Text("在 readwise.io/export 选择 CSV 下载。可重复导入同一文件，已存在的摘录会自动跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("导出") {
                Button("导出全部为 Markdown（每个出处一个文件）…") {
                    ExportService.exportAll(store: store)
                }
            }
            Section("问题排查") {
                HStack {
                    Button("导出诊断信息…") { ExportService.exportDiagnostics(store: store) }
                    Button("打开日志文件夹") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.file.deletingLastPathComponent()])
                    }
                }
                Text("诊断信息包括版本、系统、数据规模、主要设置和最近的日志，不含任何摘录正文，可以放心发给别人帮忙排查。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(item: Bindable(store).backupList) { _ in
            RestoreBackupView()
        }
    }
}

@MainActor
private func chooseLiquidTextFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = "选择存放 LiquidText 导出笔记的文件夹（可新建“LiquidText 导出”）"
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        panel.directoryURL = docs
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    LiquidTextFolder.folder = url
}

@MainActor
private func chooseObsidianFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "同步到这里"
    panel.message = "选择 Obsidian 库里的一个文件夹（建议新建“KongReview”子文件夹）"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    ObsidianSync.folder = url
}

private struct CardSettingsTab: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(CardSettings.newPerDayKey) private var newPerDay = 20
    @AppStorage(CardSettings.reviewsPerDayKey) private var reviewsPerDay = 200
    @AppStorage(CardSettings.adjustDarkColorsKey) private var adjustDarkColors = true
    @AppStorage(CardSettings.syncFromHighlightKey) private var syncMode = "ask"
    @AppStorage(CardSettings.menuBarCountsKey) private var menuBarCounts = true

    var body: some View {
        let _ = store.revision
        Form {
            Section("每日学习量") {
                LabeledContent("牌组默认：每天新卡") {
                    DailyLimitNumberField(value: limitBinding($newPerDay), step: 5)
                }
                LabeledContent("牌组默认：每天复习上限") {
                    DailyLimitNumberField(value: limitBinding($reviewsPerDay), step: 10)
                }
                totalRow("全库合计：每天新卡", .new, step: 5)
                totalRow("全库合计：每天复习", .review, step: 10)
                HStack {
                    Text("未单独设置的牌组各用“牌组默认”；全库合计限制所有牌组加起来的张数，设了就以较小者为准。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("按牌组调整…") {
                        store.openDailyLimits()
                        WindowOpener.showMain()
                    }
                }
            }
            Section("FSRS 参数") {
                Text(CardSettings.fsrsIsDefault ? "当前：FSRS-6 默认参数" : "当前：已优化（\(CardSettings.fsrsInfo ?? "")）")
                    .font(.callout)
                HStack {
                    Button("用我的复习记录优化") { store.optimizeFSRS() }
                        .disabled(store.maintenanceProgress != nil)
                    Button("恢复默认") { store.resetFSRS() }
                        .disabled(CardSettings.fsrsIsDefault)
                }
                Text("按你过去的复习记录（含从 Anki 导入的）拟合遗忘曲线，至少需要 \(FSRSOptimizer.minimumReviews) 次跨日复习。只有在留出的检验记录上也更准时才采用新参数。参数对所有使用 FSRS 的牌组生效；在牌组选项里选择算法与期望保留率。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("显示") {
                Toggle("深色模式下自动调亮卡片自带的深色文字", isOn: $adjustDarkColors)
                Text("从网页复制来的卡片常带深灰色文字（如 rgb(51,51,51)），深色背景下看不清。打开后：灰色文字改用系统文字色，彩色文字调亮，浅色底色去掉。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("菜单栏图标旁显示今日待看数（摘录·记忆卡）", isOn: $menuBarCounts)
                    .onChange(of: menuBarCounts) { StatusItemController.shared.updateCounts() }
            }
            Section("摘录与记忆卡") {
                Picker("改了已做成卡片的摘录后", selection: $syncMode) {
                    Text("询问是否同步").tag("ask")
                    Text("总是同步更新卡片").tag("always")
                    Text("不同步").tag("never")
                }
                Text("同步只替换卡片的正反面内容（原文、译文、按语、出处），复习进度不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 改了默认值后立即刷新牌组页、学习队列与菜单栏
    private func limitBinding(_ value: Binding<Int>) -> Binding<Int> {
        Binding(get: { value.wrappedValue },
                set: { value.wrappedValue = DailyLimitSettings.clamp($0); store.dailyLimitsChanged() })
    }

    private func totalRow(_ title: String, _ kind: DailyLimitKind, step: Int) -> some View {
        let current = kind == .new ? CardSettings.totalNewPerDay : CardSettings.totalReviewsPerDay
        func set(_ v: Int?) {
            if kind == .new { CardSettings.totalNewPerDay = v } else { CardSettings.totalReviewsPerDay = v }
            store.dailyLimitsChanged()
            store.revisionBump()
        }
        return HStack {
            Toggle(title, isOn: Binding(get: { current != nil },
                                        set: { set($0 ? CardSettings.lastTotal(kind) : nil) }))
            Spacer()
            if let current {
                DailyLimitNumberField(value: Binding(get: { current }, set: { set($0) }), step: step)
            } else {
                Text("不限").foregroundStyle(.secondary)
            }
        }
    }
}

/// 从备份恢复：列出备份（日期、摘录与卡片数、大小），确认后恢复
struct RestoreBackupView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let items = store.backupList?.items
        return VStack(alignment: .leading, spacing: 12) {
            Text("从备份恢复").font(.title2.bold())
            Text("选一份备份恢复。恢复前会先把当前数据另存一份“恢复前”备份，随时可以再恢复回来。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let items {
                if items.isEmpty {
                    Text("还没有备份。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(items) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                Text("\(b.highlights) 条摘录 · \(b.cards) 张卡 · \(ByteCountFormatter().string(fromByteCount: b.bytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(b.url.deletingLastPathComponent().lastPathComponent + "/" + b.url.lastPathComponent)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("恢复…") { store.pendingRestore = b }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(minHeight: 260)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("正在读取备份…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Spacer()
                Button("关闭", role: .cancel) { store.backupList = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
        .confirmationDialog(
            "恢复到 \(store.pendingRestore?.date.formatted(date: .abbreviated, time: .shortened) ?? "") 的备份？",
            isPresented: Binding(get: { store.pendingRestore != nil }, set: { if !$0 { store.pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) { if let b = store.pendingRestore { store.restoreBackup(b) } }
            Button("取消", role: .cancel) { store.pendingRestore = nil }
        } message: {
            Text("数据库里的全部内容（摘录、出处、记忆卡、回顾记录、网页存档）会换成这份备份；应用设置不变。当前数据会先另存一份。")
        }
    }
}
