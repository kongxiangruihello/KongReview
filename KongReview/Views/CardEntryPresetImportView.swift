import SwiftUI
import KongReviewCore

struct CardEntryPresetImportRequest: Identifiable {
    let id = UUID()
    var presets: [CardEntryPreset]
}

struct CardEntryPresetImportView: View {
    private struct Row: Identifiable {
        let id = UUID()
        var preset: CardEntryPreset
        var name: String
        var selected = true
        var value: CardEntryPreset { var value = preset; value.name = name; return value.cleaned }
    }
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var templates: [String: NoteTemplate] = [:]
    @State private var existingNames: [String] = []
    @State private var error: String?
    @State private var loaded = false
    let onImported: (Int) -> Void

    init(presets: [CardEntryPreset], onImported: @escaping (Int) -> Void) {
        _rows = State(initialValue: presets.map { Row(preset: $0, name: $0.name) })
        self.onImported = onImported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入录入模板 · 预览").font(.title2.bold())
            Text("每项均另存为独立模板，现有模板及牌组绑定不会被覆盖。模板仅保留空白栏目、默认牌组与标签、填写提示和必填规则。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择可用项") { for i in rows.indices { rows[i].selected = structuralIssue(rows[i]) == nil } }.handCursor()
                Button("取消全选") { for i in rows.indices { rows[i].selected = false } }.handCursor()
                Button("为重名项生成新名称") { renameConflicts() }.handCursor()
                Spacer()
                Text("已选 \(selected.count) / \(rows.count) 项").font(.caption).foregroundStyle(.secondary)
            }.disabled(!loaded || store.fullBackupBusy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle("导入", isOn: $row.selected).toggleStyle(.checkbox).disabled(structuralIssue(row) != nil)
                                TextField("另存名称", text: $row.name).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("另存模板名称：\(row.preset.name)")
                            }
                            Text("默认牌组：\(row.value.deck) · 标签：\(row.value.tags.isEmpty ? "无" : row.value.tags.joined(separator: "、"))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let issue = structuralIssue(row) {
                                Text("暂不能导入：\(issue)").font(.callout).foregroundStyle(.orange)
                                Text("请先修正原模板再导入。使用笔记类型时，应用内须有名称与字段顺序完全一致的类型；不会自动新建或猜测字段对应。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if row.selected, let issue = nameIssue(row) {
                                Text(issue).font(.callout).foregroundStyle(.red)
                            }
                            DisclosureGroup("查看结构与填写规则") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let type = row.preset.noteType {
                                        Text("笔记类型：\(type)").font(.headline)
                                        ForEach(Array(row.preset.fieldNames.enumerated()), id: \.offset) { index, name in
                                            ruleLine(name, row.preset.fieldRules?.indices.contains(index) == true ? row.preset.fieldRules?[index] : nil)
                                        }
                                    } else {
                                        ruleLine("正面", row.preset.frontRule)
                                        ruleLine("背面", row.preset.backRule)
                                        ForEach(Array(row.preset.sections.enumerated()), id: \.offset) { _, section in
                                            ruleLine(section.name + (section.folded ? "（默认折叠）" : ""), section.rule)
                                        }
                                    }
                                }.padding(.top, 6)
                            }.font(.callout)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.trailing, 6)
            }.disabled(!loaded || store.fullBackupBusy)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("名称冲突须改名或取消勾选；导入后可另行设置牌组绑定。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入所选（\(selected.count)）") { performImport() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canImport || store.fullBackupBusy)
            }
        }.padding(24).frame(minWidth: 680, idealWidth: 740, minHeight: 500, idealHeight: 620)
            .task { load() }
    }

    private var selected: [Row] { rows.filter(\.selected) }
    private var canImport: Bool { loaded && !selected.isEmpty && selected.allSatisfy { structuralIssue($0) == nil && nameIssue($0) == nil } }

    @ViewBuilder private func ruleLine(_ name: String, _ rule: CardEntryInputRule?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name + (rule?.required == true ? " · 必填" : ""))
            if let hint = rule?.hint, !hint.isEmpty { Text(hint).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
    private func structuralIssue(_ row: Row) -> String? {
        do {
            var value = row.value
            value.name = "结构检查"
            try value.validate(templates: templates)
            return nil
        } catch { return error.localizedDescription }
    }
    private func nameIssue(_ row: Row) -> String? {
        let name = row.value.name
        if name.isEmpty { return "请填写另存名称。" }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "已有同名模板，请修改另存名称，或取消勾选此项。"
        }
        if rows.contains(where: { $0.id != row.id && $0.selected && $0.value.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "所选文件中有同名模板，请分别命名。"
        }
        return nil
    }
    private func renameConflicts() {
        var occupied = existingNames
        for index in rows.indices where rows[index].selected {
            let name = rows[index].value.name
            if occupied.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                rows[index].name = CardEntryPresetTransfer.suggestedCopyName(name, existingNames: occupied)
            }
            occupied.append(rows[index].value.name)
        }
    }
    private func load() {
        do {
            templates = try store.db.noteTemplates()
            existingNames = try store.db.cardEntryPresetLibrary().presets.map(\.name)
            for index in rows.indices where structuralIssue(rows[index]) != nil { rows[index].selected = false }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func performImport() {
        guard canImport, !store.fullBackupBusy else { return }
        do {
            let imported = try store.db.importCardEntryPresets(selected.map(\.value))
            onImported(imported.count)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            // Re-read names/types after a race with another management window.
            templates = (try? store.db.noteTemplates()) ?? templates
            existingNames = (try? store.db.cardEntryPresetLibrary().presets.map(\.name)) ?? existingNames
        }
    }
}
