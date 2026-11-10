import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers
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
                .tabItem { Label("日课", systemImage: "list.clipboard") }
            CardSettingsTab()
                .tabItem { Label("记忆卡", systemImage: "brain") }
            CaptureSettings()
                .tabItem { Label("摘录", systemImage: "square.and.arrow.down") }
            DataSettings()
                .tabItem { Label("数据", systemImage: "externaldrive") }
            UpdateSettings()
                .tabItem { Label("更新", systemImage: "arrow.down.circle") }
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
    @AppStorage(HotKeyPreset.noteKey) private var notePresetRaw = HotKeyPreset.ctrlOptJ.rawValue

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
            // 6.2：随手札记——任何应用里（包括做题时）随手写一条札记，不离开当前页面
            Section {
                Picker("随手札记快捷键", selection: $notePresetRaw) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: notePresetRaw) { HotKeyCenter.shared.applyNote(HotKeyPreset.note) }
                .onChange(of: presetRaw) { HotKeyCenter.shared.applyNote(HotKeyPreset.note) }
                if HotKeyCenter.shared.noteRegistrationFailed {
                    Text("这个快捷键已被快速录入或其他应用占用，请换一个。")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("在任何应用里按下快捷键，弹出随手札记浮窗：写题目与正文，⌘↩ 保存，Esc 取消；浮窗浮在最前，写完不离开当前页面。菜单“文件 → 随手札记浮窗”（⌥⌘J）同此。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("现在试一下") { QuickNoteController.shared.show() }
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
    @AppStorage(RevisitLimits.questionsKey) private var revisitQuestions = 2
    @AppStorage(RevisitLimits.answersKey) private var revisitAnswers = 2
    @AppStorage(RevisitLimits.blocksKey) private var revisitBlocks = 2
    @AppStorage(CheckinReminderPlan.enabledKey) private var checkinReminder = true
    @AppStorage(CheckinReminderPlan.hourKey) private var checkinHour = CheckinReminderPlan.defaultHour
    @AppStorage(CheckinReminderPlan.minuteKey) private var checkinMinute = 0
    @AppStorage(ReflectionReminderPlan.enabledKey) private var reflectionReminder = false
    @AppStorage(ReflectionReminderPlan.weekdayKey) private var reflectionWeekday = 1
    @AppStorage(ReflectionReminderPlan.hourKey) private var reflectionHour = 20
    @AppStorage(ReflectionReminderPlan.minuteKey) private var reflectionMinute = 0
    @AppStorage(SettingsKeys.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKeys.reminderHour) private var hour = 8
    @AppStorage(SettingsKeys.reminderMinute) private var minute = 0
    @AppStorage(AnnotateSettings.perDayKey) private var annotatePerDay = AnnotateSettings.defaultPerDay
    @AppStorage(ExamSettings.minutesKey) private var examMinutes = 0
    @AppStorage(ExamFresh.perDayKey) private var freshPerDay = ExamFresh.defaultPerDay

    var body: some View {
        Form {
            Section("今日日课：每天至多出几道") {
                Stepper("摘录题：\(dailyCount) 道", value: $dailyCount, in: 3...50)
                Text("从全库按加权抽样（收藏、写过按语、被札记引用的更常出），忘了的两天后补练（至多 3 道，占名额）。改动从明天开始生效。记忆卡的题数在记忆卡的“每日学习量”里设。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 6.0.8：新录的摘录及早上卷
                Stepper(freshPerDay == 0 ? "其中新录的：不留名额" : "其中新录的：至多 \(freshPerDay) 道", value: $freshPerDay, in: 0...10)
                Text("新录的摘录（含今日标注划出的、从 KongFolio 导入的）录进来的第二天起练第 1 次，隔两天练第 2 次，之后回到平常的抽样；排在补练之后，占摘录题的名额；先出到了第 2 次的，再出先录的（6.3.4 起），一次进来很多时其余往后顺延。30 天内录的才算；整篇存进来的文章归“今日标注”。改动从明天开始生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("论证题（札记）：\(revisitNotes) 道", value: $revisitNotes, in: 0...10)
                Stepper("进展题（未解决的问题）：\(revisitQuestions) 道", value: $revisitQuestions, in: 0...10)
                Stepper("解答题（已解决的问题）：\(revisitAnswers) 道", value: $revisitAnswers, in: 0...10)
                Stepper("复述题（笔记）：\(revisitBlocks) 道", value: $revisitBlocks, in: 0...10)
                Text("札记与笔记按 7、21、60、180、365 天的间隔回来，改过的札记、需重读的笔记从头算；笔记指专题笔记本里自己写的、至少 20 字的文字段落。问题簿里未解决的问题（待研究、有线索）出进展题：「常念」的约每周一次，其余按 7、21、60…… 天回来；已解决、写了解答（或指向一条札记）的出解答题：给问题、想答案，按 7、21、60、180、365 天回来，忘了的两天后再来；搁置的不出。设为 0 即不出这一类。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("每天做多久") {
                Stepper(examMinutes == 0 ? "不限时长（各类按上面的题数出）" : "每天约 \(examMinutes) 分钟", value: $examMinutes, in: 0...240, step: 5)
                Text("设了时长，当天第一次排日课时按这个次序分配：补练的摘录 → 到期的记忆卡 → 札记 → 笔记 → 问题 → 其余摘录（每道约 20 秒到 2 分钟估算）；超出的题顺延到明天，日课做完时可以“再做 10 分钟”。标注文章另算。日课上忘了的题会在课末再练一次（不另占时长）。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("今日标注：每天标几篇文章") {
                Stepper(annotatePerDay == 0 ? "不出" : "每天 \(annotatePerDay) 篇", value: $annotatePerDay, in: 0...20)
                Text("从全部摘录里整篇存进来（至少 1000 字）、还没划过要点的文章中每天随机抽，在今日日课上打开标注：选中一段按 H 即存为同一出处下的一条摘录，原文不动。以前在 Readwise 等处划过的（同一出处已有出现在正文里的短摘录）不再抽。调多了当天即补足；设为 0 不出这一项，不计入打卡。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("打卡") {
                // 5.2.2：晚间打卡提醒
                Toggle("还没打卡时提醒", isOn: $checkinReminder)
                DatePicker("打卡提醒时间", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: checkinHour, minute: checkinMinute, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); checkinHour = c.hour ?? 21; checkinMinute = c.minute ?? 0 }
                ), displayedComponents: .hourAndMinute)
                .disabled(!checkinReminder)
                Text("日课上答完一类并写下日评即打卡；到点还没打卡就提醒一次，打了就不提醒。休息日与补签在今日日课的今日小结里设置。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("提醒") {
                Toggle("每天提醒做日课", isOn: $reminderEnabled)
                DatePicker("提醒时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!reminderEnabled)
                Text("当天已经在今日日课上答过题，就不再提醒。")
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
        .onChange(of: annotatePerDay) { store.refreshDailyCheck() }
        .onChange(of: examMinutes) { store.examResetBudget() }
        .onChange(of: revisitQuestions) { store.refreshRevisit() }
        .onChange(of: revisitBlocks) { store.refreshRevisit() }
        .onChange(of: checkinReminder) { ReminderScheduler.shared.applyCheckinReminder() }
        .onChange(of: checkinHour) { ReminderScheduler.shared.applyCheckinReminder() }
        .onChange(of: checkinMinute) { ReminderScheduler.shared.applyCheckinReminder() }
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
    @AppStorage(EditorPasteStyle.askKey) private var askPasteStyle = false

    var body: some View {
        let _ = store.revision
        Form {
            // 5.2.2：粘贴不再弹出选择界面
            Section("粘贴") {
                Toggle("粘贴带格式的内容时先选择方式（保留格式、清理格式、纯文字）", isOn: $askPasteStyle)
                Text("关闭时（默认）从网页、Word 等复制的内容直接按原格式粘贴，标题、粗体、列表、链接、图片都保留，粘贴后可撤销。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text("kongreview://add?text=…&title=…&author=…&url=…&location=…&tags=…\nkongreview://quick（打开空白浮窗）\nkongreview://review（打开今日回顾）")
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
    @AppStorage(KongFolioSettings.enabledKey) private var kfEnabled = true
    @AppStorage(KongFolioSettings.pathKey) private var kfPath = ""
    @AppStorage(KongFolioSettings.lastReportKey) private var kfLast = ""

    var body: some View {
        let _ = store.revision
        Form {
            // 6.0.6：KongFolio 的阅读材料
            Section("KongFolio 的阅读材料") {
                Toggle("自动导入 KongFolio 的摘录、笔记与札记", isOn: $kfEnabled)
                    .onChange(of: kfEnabled) { if kfEnabled { store.checkKongFolio(quiet: false) } }
                HStack {
                    Text(KongFolioSettings.catalog.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("其他位置…") { chooseKongFolioCatalog() }
                    if !kfPath.isEmpty { Button("用默认位置") { kfPath = "" } }
                }
                HStack {
                    Button("立即导入") { store.checkKongFolio(quiet: false, force: true) }
                    Button("从文件导入…") { store.chooseKongFolioFile() }
                    Spacer()
                    let c: (highlights: Int, notes: Int) = (try? store.db.kongFolioCounts()) ?? (highlights: 0, notes: 0)
                    Text("已导入摘录 \(c.highlights) 条、札记 \(c.notes) 条").font(.caption).foregroundStyle(.secondary)
                }
                if !kfLast.isEmpty {
                    Text("上次：" + kfLast).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("读取 KongFolio 的阅读记录（默认在“~/Library/Application Support/KongFolio/ReadingJournal/catalog.json”），启动、回到前台时和每分钟看一次，改过才导入。摘录与有文字的图片摘录导入为摘录（出处取书名与作者，位置取页码，“我的笔记”作按语，带“KongFolio”标签）；笔记、整本书心得与札记导入为札记，引用的原文一并挂上。导入后照常在今日日课上出题：摘录出要点题、出处题，札记 7 天后出论证题。重复导入不会重复；KongFolio 里改过的会更新；在 KongReview 里删去的不再加回来。“从文件导入”也可以选 KongFolio 导出的 Markdown（只增不改）。只读 KongFolio 的文件，不改动它们。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
private func chooseKongFolioCatalog() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.json]
    panel.prompt = "选择"
    panel.message = "选择 KongFolio 的阅读记录 catalog.json（在 KongFolio 资料文件夹的 ReadingJournal 里）"
    panel.directoryURL = KongFolioSettings.defaultCatalog.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    KongFolioSettings.catalog = url
}

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

/// 6.0.2：点一下就更新（仿 KongSeek）
private struct UpdateSettings: View {
    @AppStorage(AppUpdater.autoCheckKey) private var autoCheck = true
    @AppStorage(AppUpdater.proxyKey) private var proxy = ""
    @State private var confirmsLocal = false
    @State private var confirmsRollback = false
    private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("版本") {
                LabeledContent("当前", value: updater.currentVersionText)
                LabeledContent("签名", value: AppUpdater.signingDescription())
                LabeledContent("上次检查", value: updater.lastChecked.map(Self.time) ?? "还没有检查过")
                if let v = updater.remoteVersion { LabeledContent("GitHub 上", value: v) }
                HStack {
                    Button("检查更新") { updater.check(manual: true) }.disabled(updater.isBusy)
                    Button("立即更新") { updater.update() }.disabled(updater.isBusy || !updater.hasUpdate)
                }
            }
            Section("更新方式") {
                Text("仿 KongSeek：不用等发布安装包。点“立即更新”，应用在源码文件夹里取 GitHub 上 main 分支的最新代码，先跑全部测试，再编译、签名；测试或编译不通过就停下，当前版本不动。装之前先备份学习库，换下来的旧版本放在“应用备份”里，可以回退。完成后自动重新打开。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("自动检查（启动后与每 6 小时一次；有更新只在首页提示）", isOn: $autoCheck)
                    .onChange(of: autoCheck) { if autoCheck { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() } }
                HStack {
                    Text("代理")
                    TextField("", text: $proxy, prompt: Text("自动（使用系统代理）"))
                }
                Text("连不上 GitHub 时用：如 127.0.0.1:7890。现在的系统代理：" + (AppUpdater.systemProxy ?? "无（直连）"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("源码与备份") {
                LabeledContent("源码文件夹", value: (AppUpdater.sourceRoot.path as NSString).abbreviatingWithTildeInPath)
                HStack {
                    Button("在访达中显示") {
                        let root = AppUpdater.sourceRoot
                        if FileManager.default.fileExists(atPath: root.path) { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }
                    Button("用本地源码重新构建…") { confirmsLocal = true }.disabled(updater.isBusy)
                    Button("回退到上一版…") { confirmsRollback = true }.disabled(updater.isBusy || updater.backups.isEmpty)
                    Button("更新日志") { NSWorkspace.shared.open(AppUpdater.logURL) }
                }
                Text(updater.backups.isEmpty ? "还没有可回退的旧版本。" : "可回退：" + updater.backups.prefix(3).map { $0.replacingOccurrences(of: ".app", with: "") }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("用本地源码重新构建？", isPresented: $confirmsLocal, titleVisibility: .visible) {
            Button("重新构建") { updater.update(fromLocalSource: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不连 GitHub，直接用源码文件夹里现有的代码测试、编译并安装（约几分钟），之后 KongReview 自动重新打开。")
        }
        .confirmationDialog("回退到 \(updater.backups.first?.replacingOccurrences(of: ".app", with: "") ?? "")？", isPresented: $confirmsRollback, titleVisibility: .visible) {
            Button("回退") { updater.rollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只换回应用本身，学习库保持现在的样子（新版本加过的内容旧版本可能不显示）。每次更新前都备份过学习库，可在“数据 → 从备份恢复”找回。")
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: d)
    }
}
