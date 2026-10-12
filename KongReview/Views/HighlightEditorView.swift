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
                    TextEditor(text: draftBinding.highlight.text)
                        .font(.system(.body, design: .serif))
                        .frame(minHeight: 140)
                    if !draft.highlight.text.isEmpty {
                        MarkdownPreview(text: draft.highlight.text, font: .system(.body, design: .serif))
                    }
                } header: {
                    Text("原文")
                } footer: {
                    Text("原文、译文、按语都支持 Markdown：# 标题、- 列表、> 引用、**粗体**、*斜体*、`代码`、[链接](https://…)，下方实时预览。")
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
                    TextEditor(text: optional(draftBinding.highlight.translation))
                        .frame(minHeight: 50)
                    if let t = draft.highlight.translation, !t.isEmpty {
                        MarkdownPreview(text: t)
                    }
                }

                Section("按语（可选）") {
                    TextEditor(text: optional(draftBinding.highlight.note))
                        .frame(minHeight: 60)
                    if let n = draft.highlight.note, !n.isEmpty {
                        MarkdownPreview(text: n)
                    }
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
