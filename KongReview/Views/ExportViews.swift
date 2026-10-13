import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 导出选项（专题汇编 / Anki）

struct ExportOptionsView: View {
    @Environment(LibraryStore.self) private var store

    private func binding<T>(_ kp: WritableKeyPath<ExportRequest, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.exportRequest?[keyPath: kp] ?? fallback },
            set: { store.exportRequest?[keyPath: kp] = $0 }
        )
    }

    var body: some View {
        if let req = store.exportRequest {
            VStack(alignment: .leading, spacing: 14) {
                Text(req.kind == .compilation ? "专题汇编" : "导出到 Anki").font(.title2.bold())
                Text(req.scopeLabel).font(.callout).foregroundStyle(.secondary)

                Form {
                    if req.kind == .compilation {
                        TextField("标题", text: binding(\.title, ""))
                        Picker("编排", selection: binding(\.grouping, .bySource)) {
                            ForEach(CompilationOptions.Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("包含译文 / 白话", isOn: binding(\.includeTranslation, true))
                        Toggle("包含按语", isOn: binding(\.includeNotes, true))
                        Toggle("包含标签", isOn: binding(\.includeTags, false))
                        Picker("格式", selection: binding(\.wordFormat, true)) {
                            Text("Word（.docx）").tag(true)
                            Text("Markdown（.md）").tag(false)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Text("每条摘录生成一张卡片：正面为原文，背面为译文、按语与出处；摘录的标签会带过去，另加标签 KongReview。在 Anki 里用“文件 → 导入”选择导出的文件即可（需要 Anki 2.1.54 或更新版本）。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("引文体例", selection: binding(\.style, .footnote)) {
                        ForEach(CitationStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { store.exportRequest = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("导出…") { ExportService.runExport(store: store) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .handCursor()
                        .disabled(req.highlights.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 520)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

extension ExportService {
    /// 按导出面板的选项写文件
    static func runExport(store: LibraryStore) {
        guard let req = store.exportRequest else { return }
        var sources: [Int64: Source] = [:]
        for s in store.sources { if let id = s.id { sources[id] = s } }
        let safeTitle = MarkdownExporter.fileName(for: Source(title: req.title)).replacingOccurrences(of: ".md", with: "")

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch req.kind {
        case .compilation:
            panel.nameFieldStringValue = safeTitle + (req.wordFormat ? ".docx" : ".md")
            panel.allowedContentTypes = [UTType(filenameExtension: req.wordFormat ? "docx" : "md") ?? .data]
        case .anki:
            panel.nameFieldStringValue = "KongReview-Anki-\(safeTitle).txt"
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch req.kind {
            case .compilation:
                let options = CompilationOptions(
                    title: req.title, grouping: req.grouping, includeTranslation: req.includeTranslation,
                    includeNotes: req.includeNotes, includeTags: req.includeTags, style: req.style
                )
                let c = CompilationBuilder.build(highlights: req.highlights, sources: sources, options: options)
                if req.wordFormat {
                    try DocxWriter.write(c, to: url)
                } else {
                    try CompilationBuilder.markdown(c).write(to: url, atomically: true, encoding: .utf8)
                }
            case .anki:
                let text = AnkiExporter.export(highlights: req.highlights, sources: sources, style: req.style)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            CitationSettings.style = req.style
            store.exportRequest = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.report(error)
        }
    }
}

// MARK: - 批量操作输入（加标签 / 去标签 / 移到出处）

struct BatchPromptView: View {
    @Environment(LibraryStore.self) private var store

    private var text: Binding<String> {
        Binding(get: { store.batchPrompt?.text ?? "" }, set: { store.batchPrompt?.text = $0 })
    }

    var body: some View {
        if let p = store.batchPrompt {
            VStack(alignment: .leading, spacing: 12) {
                switch p.kind {
                case .addTags:
                    Text("给 \(p.ids.count) 条摘录加标签").font(.title3.bold())
                    TextField("用逗号或空格分隔", text: text).onSubmit { store.commitBatchPrompt() }
                    tagChips(store.tags, add: true)
                case .removeTags:
                    Text("从 \(p.ids.count) 条摘录中去掉标签").font(.title3.bold())
                    TextField("要去掉的标签", text: text).onSubmit { store.commitBatchPrompt() }
                    tagChips(store.tags(of: p.ids), add: true)
                case .move:
                    Text("把 \(p.ids.count) 条摘录移到出处").font(.title3.bold())
                    TextField("搜索出处", text: text)
                    sourcePicker(p)
                }
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { store.batchPrompt = nil }
                        .keyboardShortcut(.cancelAction)
                    if p.kind != .move {
                        Button("确定") { store.commitBatchPrompt() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .handCursor()
                            .disabled(TagParser.parse(p.text).isEmpty)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(20)
            .frame(width: 460)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func tagChips(_ tags: [String], add: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tags.prefix(40), id: \.self) { t in
                    Button("#\(t)") {
                        var cur = TagParser.parse(text.wrappedValue)
                        if !cur.contains(t) { cur.append(t) }
                        text.wrappedValue = TagParser.format(cur)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func sourcePicker(_ p: BatchPrompt) -> some View {
        let q = p.text.trimmingCharacters(in: .whitespaces)
        let matches = store.sources.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
        return List {
            Button("（未归类）") {
                store.batch(.move(nil), ids: p.ids)
                store.batchPrompt = nil
            }
            ForEach(matches.prefix(200)) { s in
                Button {
                    store.batch(.move(s.id), ids: p.ids)
                    store.batchPrompt = nil
                } label: {
                    HStack {
                        Text(s.title).lineLimit(1)
                        if !s.author.isEmpty { Text(s.author).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text("\(store.highlightCounts[s.id ?? -1] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
        }
        .frame(height: 300)
    }
}
