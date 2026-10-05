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
            ReviewSettings()
                .tabItem { Label("回顾", systemImage: "sun.max") }
            CaptureSettings()
                .tabItem { Label("摘录", systemImage: "square.and.arrow.down") }
            DataSettings()
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 340)
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
    @State private var copied = false

    var body: some View {
        Form {
            Section("浏览器书签小程序") {
                Text("在浏览器中新建一个书签，把下面的代码粘贴到“网址”栏。阅读网页时选中文字、点这个书签，就会打开 KongGlean 的新建摘录面板，标题与网址已自动填好。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied ? "已复制" : "复制书签代码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CaptureRequest.bookmarklet, forType: .string)
                        copied = true
                    }
                    Spacer()
                }
            }
            Section("链接格式（供快捷指令、kongfetch 调用）") {
                Text("kongglean://add?text=…&title=…&author=…&url=…&location=…&tags=…")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Form {
            Section("存储") {
                Text("全部数据保存在一个 SQLite 文件中。备份时复制整个文件夹即可。")
                    .font(.callout)
                Button("在访达中显示数据文件夹") {
                    if let dir = try? FileManager.default
                        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                        .appendingPathComponent("KongGlean") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
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
