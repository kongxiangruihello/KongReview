import SwiftUI
import KongReviewCore

/// 新建 / 编辑摘录。⌘↩ 保存，Esc 取消。
struct HighlightEditorView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 直接读写 store.editorDraft（不用 @State，见 ViewState.swift）
    private var draftBinding: Binding<HighlightDraft> {
        Binding(
            get: { store.editorDraft ?? HighlightDraft(highlight: Highlight(text: "")) },
            set: { store.editorDraft = $0 }
        )
    }
    private var draft: HighlightDraft { draftBinding.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    RichEditor(text: draftBinding.highlight.text, font: .highlight, placeholder: "摘录原文",
                               autoHeight: true, minHeight: 150, focus: draft.isNew, slot: "hl-text",
                               onSubmit: submit, onCancel: cancel)
                        .richEditorFrame()
                } header: {
                    Text("原文")
                } footer: {
                    Text("所见即所得：⌘B 粗体、⌘I 斜体、⌘K 链接、⌘1/⌘2 标题、⇧⌘8 列表、⇧⌘. 引用；也可直接敲 Markdown（行首“# ”“- ”“> ”，或 **粗体**）。从网页、Word 粘贴时保留粗体、标题、列表等格式。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("出处") {
                    if draft.showNewSource || !draft.newSourceTitle.isEmpty {
                        TextField("标题", text: draftBinding.newSourceTitle)
                        TextField("作者", text: draftBinding.newSourceAuthor)
                        Picker("类型", selection: draftBinding.newSourceKind) {
                            ForEach(SourceKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        TextField("网址（可选）", text: draftBinding.newSourceURL)
                        Button("改为选择已有出处") {
                            draftBinding.wrappedValue.newSourceTitle = ""
                            draftBinding.wrappedValue.showNewSource = false
                        }
                    } else {
                        Picker("出处", selection: draftBinding.highlight.sourceId) {
                            Text("（未归类）").tag(Int64?.none)
                            ForEach(store.sources) { s in
                                Text(s.author.isEmpty ? s.title : "\(s.title) · \(s.author)")
                                    .tag(s.id)
                            }
                        }
                        Button("新建出处…") { draftBinding.wrappedValue.showNewSource = true }
                    }
                    TextField("位置（页码、卷次、章节）", text: optional(draftBinding.highlight.location))
                }

                Section("译文 / 白话（可选）") {
                    RichEditor(text: optional(draftBinding.highlight.translation), placeholder: "译文或白话",
                               toolbar: false, autoHeight: true, minHeight: 60, slot: "hl-translation",
                               onSubmit: submit, onCancel: cancel)
                        .richEditorFrame()
                }

                Section("按语（可选）") {
                    RichEditor(text: optional(draftBinding.highlight.note), font: .note, placeholder: "按语",
                               autoHeight: true, minHeight: 70, slot: "hl-note",
                               onSubmit: submit, onCancel: cancel)
                        .richEditorFrame()
                }

                Section("标签") {
                    TextField("用逗号、空格或 # 分隔", text: draftBinding.tagsText)
                    if !store.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(store.tags, id: \.self) { tag in
                                    Button("#\(tag)") { appendTag(tag) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !draft.isNew {
                    Text("创建于 \(draft.highlight.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "保存" : "更新") { store.commit(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(draft.highlight.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 620)
    }

    private func cancel() {
        store.editorDraft = nil
        dismiss()
    }

    /// 编辑器里按 ⌘↩
    private func submit() {
        guard let d = store.editorDraft,
              !d.highlight.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.commit(d)
    }

    private func appendTag(_ tag: String) {
        var tags = TagParser.parse(draft.tagsText)
        guard !tags.contains(tag) else { return }
        tags.append(tag)
        draftBinding.wrappedValue.tagsText = TagParser.format(tags)
    }

    /// 把 String? 绑定转成 String 绑定（空串存为 nil）
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
