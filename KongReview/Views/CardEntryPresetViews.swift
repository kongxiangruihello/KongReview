import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

struct CardEntryPresetManagerView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var library = CardEntryPresetLibrary()
    @State private var editing: CardEntryPreset?
    @State private var original: CardEntryPreset?
    @State private var pendingDelete: CardEntryPreset?
    @State private var builtinPreview: CardEntryBuiltin?
    @State private var importRequest: CardEntryPresetImportRequest?
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常用录入预设").font(.title2.bold())
            Text("保存牌组、标签、栏目结构、填写提示与必填规则。内置模板可先预览示例，再复制修改；提示和示例不会写入卡片正文。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("新建预设") { original = nil; editing = CardEntryPreset(name: "") }
                    .handCursor().disabled(store.fullBackupBusy)
                Button("从当前卡片结构创建") { captureCurrent() }
                    .handCursor().disabled(store.cardEditor == nil || store.fullBackupBusy)
                Button("导入…") { chooseImport() }.handCursor().disabled(store.fullBackupBusy)
                Button("导出全部…") { export(library.presets) }.handCursor().disabled(store.fullBackupBusy || library.presets.isEmpty)
                Spacer()
                Text("共 \(library.presets.count) 个").font(.caption).foregroundStyle(.secondary)
            }
            List {
                Section("内置常用模板 · 复制后可修改") {
                    ForEach(CardEntryBuiltins.all) { builtin in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(builtin.preset.name).font(.headline)
                                Text(builtin.preset.sections.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("查看示例") { builtinPreview = builtin }.handCursor()
                            Button("复制并编辑") { original = nil; editing = builtin.editableCopy() }.handCursor()
                        }.padding(.vertical, 4)
                    }
                }
                Section("我的录入预设（\(library.presets.count) 个）") {
                    if library.presets.isEmpty {
                        Text("复制上面的内置模板，或从当前卡片结构创建预设。").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(library.presets) { preset in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                Text(summary(preset)).font(.caption).foregroundStyle(.secondary)
                                if let issue = validationIssue(preset) { Text(issue).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Button("复制") { copy(preset) }.handCursor()
                            Button("编辑") { original = preset; editing = preset }.handCursor()
                            Button("导出…") { export([preset]) }.handCursor()
                            Button("删除", role: .destructive) { pendingDelete = preset }.handCursor()
                        }.padding(.vertical, 5)
                    }
                }
            }.listStyle(.inset).disabled(store.fullBackupBusy)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("为牌组设置预设后，新建卡片会自动带入空白结构。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(22).frame(minWidth: 660, idealWidth: 720, minHeight: 430, idealHeight: 570)
            .task { reload() }
            .onChange(of: store.fullBackupBusy) { _, busy in if !busy { reload() } }
            .sheet(item: $editing, onDismiss: { reload() }) { preset in
                CardEntryPresetEditorView(preset: preset, expected: original)
            }
            .sheet(item: $builtinPreview) { builtin in CardEntryBuiltinPreviewView(builtin: builtin) }
            .sheet(item: $importRequest, onDismiss: { reload() }) { request in
                CardEntryPresetImportView(presets: request.presets) { count in message = "已导入 \(count) 个独立模板；现有模板和牌组绑定保持原样。" }
            }
            .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("删除预设并解除牌组绑定", role: .destructive) {
                    guard !store.fullBackupBusy, let preset = pendingDelete else { return }
                    do { try store.db.deleteCardEntryPreset(id: preset.id); reload(); pendingDelete = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("已有卡片和草稿不会改变。") }
    }

    private func reload() {
        do { library = try store.db.cardEntryPresetLibrary(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func summary(_ preset: CardEntryPreset) -> String {
        let bindingCount = library.deckPresetIDs.values.filter { $0 == preset.id }.count
        let structure = preset.noteType.map { "笔记类型：\($0) · \(preset.fieldNames.count) 个字段" }
            ?? (preset.sections.isEmpty ? "正面／背面" : preset.sections.map { $0.name + ($0.folded ? "（折叠）" : "") }.joined(separator: "、"))
        return "默认牌组：\(preset.deck) · \(structure) · \(bindingCount) 个牌组使用"
    }
    private func validationIssue(_ preset: CardEntryPreset) -> String? {
        do { try preset.validate(templates: store.noteTemplates); return nil }
        catch { return error.localizedDescription }
    }
    private func captureCurrent() {
        guard !store.fullBackupBusy, let draft = store.cardEditor else { return }
        do {
            // A temporary valid name lets the editor present an empty required name field.
            var preset = try CardEntryPreset.capture(name: "新预设", card: draft.card, tags: TagParser.parse(draft.tagsText), templates: store.db.noteTemplates())
                .retainingGuidance(draft.entryGuidance, from: draft.card)
            preset.name = ""
            original = nil; editing = preset
        } catch { self.error = error.localizedDescription }
    }
    private func copy(_ preset: CardEntryPreset) {
        guard !store.fullBackupBusy else { return }
        let name = CardEntryPresetTransfer.suggestedCopyName(preset.name, existingNames: library.presets.map(\.name))
        original = nil
        editing = preset.copied(name: name)
    }
    private func chooseImport() {
        guard !store.fullBackupBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择单独导出的 KongReview 录入模板 JSON；导入前可预览并改名。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !store.fullBackupBusy else { throw CardEntryPresetError.backupBusy }
            importRequest = .init(presets: try CardEntryPresetTransfer.read(from: url))
            error = nil; message = nil
        } catch { self.error = error.localizedDescription }
    }
    private func export(_ presets: [CardEntryPreset]) {
        guard !store.fullBackupBusy else { return }
        do {
            let data = try CardEntryPresetTransfer.encode(presets)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "KongReview-录入模板.json"
            panel.message = "只导出空白结构、默认标签及填写规则，不含卡片正文、学习记录或牌组绑定。"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !store.fullBackupBusy else { throw CardEntryPresetError.backupBusy }
            try data.write(to: url, options: .atomic)
            message = "已导出 \(presets.count) 个录入模板。"; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct CardEntryPresetEditorView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var preset: CardEntryPreset
    let expected: CardEntryPreset?
    @State private var tagsText = ""
    @State private var templates: [String: NoteTemplate] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(expected == nil ? "新建录入预设" : "编辑录入预设").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        TextField("名称", text: $preset.name)
                        TextField("默认牌组", text: $preset.deck)
                        TextField("标签", text: $tagsText, prompt: Text("用空格或逗号分隔"))
                        Picker("笔记类型", selection: Binding(get: { preset.noteType ?? "" }, set: { selectType($0) })) {
                            Text("普通问答与自定义栏目").tag("")
                            ForEach(templates.keys.sorted(), id: \.self) { Text($0).tag($0) }
                            if let missing = preset.noteType, templates[missing] == nil { Text("\(missing)（已不存在）").tag(missing) }
                        }
                    }.textFieldStyle(.roundedBorder)
                    if let type = preset.noteType {
                        Text("\(type)：\(preset.fieldNames.joined(separator: "、"))").font(.callout).foregroundStyle(.secondary)
                        if templates[type]?.fieldNames != preset.fieldNames {
                            Button("采用此类型的当前字段") { selectType(type) }.handCursor().disabled(templates[type] == nil)
                        }
                        ForEach(Array(preset.fieldNames.indices), id: \.self) { index in
                            CardEntryRuleEditor(label: preset.fieldNames[index], rule: fieldRule(index))
                        }
                        Text("字段及正反面布局沿用此笔记类型。重新采用变化后的字段时，旧的填写规则会清空，避免错位。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        CardEntryRuleEditor(label: "正面", rule: Binding(get: { preset.frontRule ?? .init() }, set: { preset.frontRule = $0 }))
                        CardEntryRuleEditor(label: "背面", rule: Binding(get: { preset.backRule ?? .init() }, set: { preset.backRule = $0 }))
                        HStack {
                            Text("背面栏目").font(.headline)
                            Spacer()
                            Button("添加栏目") { preset.sections.append(.init(name: "")) }.handCursor()
                        }
                        ForEach($preset.sections) { $section in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("栏目名称", text: $section.name).textFieldStyle(.roundedBorder)
                                    Toggle("默认折叠", isOn: $section.folded).toggleStyle(.checkbox)
                                    Button { preset.moveSection(id: section.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                        .buttonStyle(.borderless).handCursor().help("上移此栏目（填写规则随栏目移动）")
                                        .accessibilityLabel("上移\(section.name)").disabled(preset.sections.first?.id == section.id)
                                    Button { preset.moveSection(id: section.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                        .buttonStyle(.borderless).handCursor().help("下移此栏目（填写规则随栏目移动）")
                                        .accessibilityLabel("下移\(section.name)").disabled(preset.sections.last?.id == section.id)
                                    Button { let id = section.id; preset.sections.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).handCursor().help("删除此栏目")
                                }
                                CardEntryRuleEditor(label: "填写规则", rule: Binding(get: { section.rule ?? .init() }, set: { section.rule = $0 }))
                            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if preset.sections.isEmpty { Text("可添加释义、出处、例句等空白栏目。").font(.caption).foregroundStyle(.secondary) }
                    }
                    // 6.0.7：写了起始内容时，看新卡片在复习时的样子（正面、背面与栏目合在一起）
                    if preset.hasStartHTML {
                        let card = preset.previewCard()
                        let faces = store.faces(of: card)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("新卡片的样子").font(.headline)
                            CardWebView(front: faces.front, back: faces.back, store: store, css: store.cardCSS(for: card))
                                .frame(height: 240)
                                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            Text("按卡片样式显示起始内容；填写提示不会出现在卡片上。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.trailing, 6)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Text("提示只辅助填写，不进入卡片正文；起始内容（HTML）会先填进新卡片。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 700, height: 620).disabled(store.fullBackupBusy)
            .task {
                tagsText = TagParser.format(preset.tags)
                do { templates = try store.db.noteTemplates() }
                catch { self.error = error.localizedDescription }
            }
    }
    private func fieldRule(_ index: Int) -> Binding<CardEntryInputRule> {
        Binding(get: { preset.fieldRules?.indices.contains(index) == true ? preset.fieldRules![index] : .init() }, set: { rule in
            if preset.fieldRules?.count != preset.fieldNames.count { preset.fieldRules = preset.fieldNames.map { _ in .init() } }
            preset.fieldRules?[index] = rule
        })
    }
    private func selectType(_ name: String) {
        if name.isEmpty { preset.noteType = nil; preset.fieldNames = []; preset.fieldRules = nil }
        else if let template = templates[name] {
            if preset.noteType != name || preset.fieldNames != template.fieldNames { preset.fieldRules = nil }
            preset.noteType = name; preset.fieldNames = template.fieldNames; preset.sections = []
        }
    }
    private func save() {
        guard !store.fullBackupBusy else { return }
        do {
            preset.tags = TagParser.parse(tagsText)
            try store.db.saveCardEntryPreset(preset, expected: expected)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Embed in a deck's options sheet. Binding changes only affect future new cards.
struct CardEntryPresetDeckBindingView: View {
    @Environment(LibraryStore.self) private var store
    let deck: String
    @State private var library = CardEntryPresetLibrary()
    @State private var selected = ""
    @State private var error: String?
    @State private var showsManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("录入模板", selection: Binding(get: { selected }, set: { update($0) })) {
                    Text("不使用模板").tag("")
                    ForEach(library.presets) { Text($0.name).tag($0.id.uuidString) }
                }
                Button("管理…") { showsManager = true }.handCursor()
            }.disabled(store.fullBackupBusy)
            Text("此牌组新建卡片时自动带入模板的标签与空白栏目；已有卡片和当前输入保留。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task(id: deck) { reload() }
            .onChange(of: store.fullBackupBusy) { _, busy in if !busy { reload() } }
            .sheet(isPresented: $showsManager, onDismiss: { reload() }) { CardEntryPresetManagerView() }
    }
    private func reload() {
        do {
            library = try store.db.cardEntryPresetLibrary()
            selected = library.deckPresetIDs[deck]?.uuidString ?? ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func update(_ id: String) {
        guard !store.fullBackupBusy else { return }
        do {
            try store.db.setDeckEntryPreset(deck: deck, presetID: UUID(uuidString: id))
            reload()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CardEntryRuleEditor: View {
    @Environment(LibraryStore.self) private var store
    let label: String
    @Binding var rule: CardEntryInputRule
    @State private var showsHTML = false
    /// 在光标处插入（不在末尾追加）
    @State private var inserter = TemplateCodeInserter()

    private var html: Binding<String> {
        Binding(get: { rule.html ?? "" }, set: { rule.html = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Button(showsHTML ? "收起起始内容" : (rule.startHTML == nil ? "起始内容（HTML）…" : "起始内容（HTML，已设）"))  { showsHTML.toggle() }
                    .buttonStyle(.link).font(.caption).handCursor()
                    .help("用 HTML 写这一栏的起始内容：新建卡片时先填进去，作格式与结构的起点")
                Toggle("必填", isOn: $rule.required).toggleStyle(.checkbox)
            }
            TextField("填写提示（可选）", text: $rule.hint, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            // 6.0.7：起始内容用 HTML 写，右边即时预览
            if showsHTML {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HTML").font(.caption).foregroundStyle(.secondary)
                        // 代码框：等宽，不把直引号换成弯引号（否则 href="…" 会写坏）
                        TemplateCodeEditor(text: html, inserter: inserter)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预览").font(.caption).foregroundStyle(.secondary)
                        EditorHTMLPreview(html: rule.startHTML ?? "", store: store)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                }
                HStack(spacing: 10) {
                    Menu("插入") {
                        ForEach(Self.snippets.indices, id: \.self) { i in
                            Button(Self.snippets[i].0) { inserter.insert(Self.snippets[i].1) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button("清空") { rule.html = nil }.disabled(rule.html == nil)
                    Spacer()
                    Text("新建卡片时先填进这一栏；原样没改不算填写（设了必填仍须填写）。脚本、内嵌框架与事件属性存时去掉。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
        .onAppear { showsHTML = rule.startHTML != nil }
    }

    /// 常用的起始格式
    static let snippets: [(String, String)] = [
        ("粗体小标题", "<p><b>小标题：</b></p>"),
        ("要点列表", "<ul><li></li><li></li><li></li></ul>"),
        ("编号步骤", "<ol><li></li><li></li><li></li></ol>"),
        ("两列表格", "<table><tr><th>项目</th><th>内容</th></tr><tr><td></td><td></td></tr><tr><td></td><td></td></tr></table>"),
        ("引文", "<blockquote><p></p></blockquote>"),
        ("分隔线", "<hr>"),
    ]
}

private struct CardEntryBuiltinPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let builtin: CardEntryBuiltin
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(builtin.preset.name) · 填写示例").font(.title2.bold())
            Text("以下内容仅用于说明填写方式。复制模板后，所有正文字段仍为空白。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(builtin.examples.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(builtin.examples[index].title).font(.headline)
                            Text(builtin.examples[index].text).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(16)
            }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 600, height: 520)
    }
}
