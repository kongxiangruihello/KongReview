import SwiftUI
import KongReviewCore

/// 新建 / 编辑摘录。⌘↩ 保存，Esc 取消。
struct HighlightEditorView: View {
    @Environment(LibraryStore.self) private var store

    @State private var recognitionNotice: String?
    @State private var attribution: SourceAttribution?
    @State private var attributionDraftID: UUID?

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
            if let notice = store.draftRecoveryNotice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.orange).padding()
            }
            Form {
                if let id = draft.highlight.id { RelatedCardsInline(highlightID: id) }
                Section {
                    RichEditor(text: draftBinding.highlight.text, font: .highlight, placeholder: "摘录原文",
                               minHeight: 150, focus: draft.isNew, slot: "hl-text",
                               onSubmit: submit, onCancel: cancel, onAttribution: recognizeAttribution)
                        .frame(height: 280)
                        .richEditorFrame()
                } header: {
                    Text("原文")
                } footer: {
                    Text("长文在编辑区内滚动，格式工具栏保持可见。⌘B 粗体、⌘I 斜体、⌘K 链接、⌘1/⌘2 标题、⇧⌘8 列表、⇧⌘. 引用；也可直接敲 Markdown。从网页、Word 粘贴时保留格式。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("出处") {
                    Button("识别正文末尾的出处…") { recognizeAttribution(); if attribution == nil { recognitionNotice = "未识别到末尾出处。支持：正文——作者《书名》第12页（或 P.12）。" } }
                        .help("识别 正文——作者《书名》第12页，先预览再填入")
                    if let recognitionNotice { Text(recognitionNotice).font(.caption).foregroundStyle(.secondary) }
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

                // 2.1：同一部古籍的其他版本（整理本）里的页码；笔记本导出时可选用哪个版本出注
                let eds = store.editions(for: draft.highlight.sourceId)
                if !eds.isEmpty {
                    Section {
                        ForEach(eds) { e in
                            if let eid = e.id {
                                TextField(editionLabel(e), text: Binding(
                                    get: { store.editorDraft?.editionPages[eid] ?? "" },
                                    set: { store.editorDraft?.editionPages[eid] = $0 }
                                ), prompt: Text("页码，如 12"))
                            }
                        }
                    } header: {
                        Text("其他版本的页码")
                    } footer: {
                        Text("这部古籍还有上面几个版本。填上这条在各版本里的页码，专题笔记本导出时就能选用其中一个版本出注（篇名沿用上面的位置）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("译文 / 白话（可选）") {
                    RichEditor(text: optional(draftBinding.highlight.translation), placeholder: "译文或白话",
                               minHeight: 60, slot: "hl-translation",
                               onSubmit: submit, onCancel: cancel)
                        .frame(height: 120)
                        .richEditorFrame()
                }

                Section("按语（可选）") {
                    RichEditor(text: optional(draftBinding.highlight.note), font: .note, placeholder: "按语",
                               minHeight: 70, slot: "hl-note",
                               onSubmit: submit, onCancel: cancel)
                        .frame(height: 150)
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
            .id(store.editorDraft?.id)

            HStack {
                Text(store.draftSaveError ?? (store.draftPersistence != nil ? "草稿自动保存在本机" : "点击保存后更新正式内容"))
                    .font(.caption)
                    .foregroundStyle(store.draftSaveError == nil ? Color.secondary : Color.red)
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
        .sheet(item:$attribution) { value in
            SourceAttributionView(candidate:value) { title,author,location,remove in
                guard var current = store.editorDraft,current.id == attributionDraftID,current.highlight.text == value.original else { return "正文已变化，请重新识别。" }
                if let source = store.sources.first(where: { $0.title == title && $0.author == author }) {
                    current.highlight.sourceId = source.id; current.newSourceTitle = ""; current.newSourceAuthor = ""; current.showNewSource = false
                } else {
                    current.highlight.sourceId = nil; current.newSourceTitle = title; current.newSourceAuthor = author; current.newSourceURL = ""; current.newSourceKind = .book; current.showNewSource = true
                }
                current.highlight.location = location.nilIfBlank
                if remove { current.highlight.text = value.body }
                store.editorDraft = current; return nil
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 620)
    }

    private func recognizeAttribution() {
        guard let current = store.editorDraft,let value = SourceAttributionRecognition.recognize(current.highlight.text) else { return }
        recognitionNotice = nil; attributionDraftID = current.id; attribution = value
    }
    private func editionLabel(_ s: Source) -> String {
        let info = [s.author, s.publisher ?? "", s.year ?? ""].filter { !$0.isEmpty }.joined(separator: "，")
        return "《\(s.title)》" + (info.isEmpty ? "" : "（\(info)）")
    }

    private func cancel() {
        store.requestCloseHighlightEditor()
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
