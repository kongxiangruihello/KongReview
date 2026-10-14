import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 1.3：专题笔记本

/// 一本笔记本：标题、块列表（摘录 / 文字 / 小标题）、块之间的插入条、导出
struct NotebookView: View {
    @Environment(LibraryStore.self) private var store
    let notebookId: Int64

    private var st: NotebookState { store.notebookState }

    var body: some View {
        let _ = store.revision
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if st.blocks.isEmpty {
                        emptyState
                    } else {
                        InsertBar(after: nil, atStart: true)
                        ForEach(st.blocks) { b in
                            if let id = b.id {
                                NotebookBlockRow(block: b)
                                    .id(id)
                                InsertBar(after: id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 30)
                .padding(.bottom, 60)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(st.titleDraft.isEmpty ? "专题笔记本" : st.titleDraft)
        .navigationSubtitle("\(st.quoteCount) 条摘录 · \(st.blocks.count - st.quoteCount) 段文字")
        .task(id: notebookId) { store.loadNotebook(notebookId) }
        .onChange(of: store.revision) { store.refreshNotebookHighlights() }
        .onDisappear { store.flushNotebookSaves() }
        .toolbar {
            ToolbarItem {
                Button {
                    store.flushNotebookSaves()
                    // 每次点“回顾这本”都从头开始（不沿用当天的进度）
                    UserDefaults.standard.removeObject(forKey: ReviewSessionRecord.key(theme: ReviewScope.notebook(notebookId)))
                    store.review.theme = ReviewScope.notebook(notebookId)
                    store.review.sessionToken += 1
                    store.selection = .review
                } label: {
                    Label("回顾这本", systemImage: "sun.max")
                }
                .help("在“今日回顾”里按顺序把这本笔记本中的摘录过一遍")
                .disabled(st.quoteCount == 0)
            }
            ToolbarItem {
                // 1.7：笔记本 ↔ 记忆卡
                Menu {
                    let _ = store.revision
                    let cs = store.notebookCardStatus(notebookId)
                    Text("\(cs.quotes) 条摘录，\(cs.withCards) 条已有记忆卡（共 \(cs.cards) 张）")
                    Divider()
                    Button("做成问答卡（牌组“\(store.notebookTitle(notebookId))”）") { store.makeNotebookCards(notebookId) }
                    Button("逐条做填空卡…") { store.startNotebookCloze(notebookId) }
                    Divider()
                    Button("学习这本的记忆卡") { store.startNotebookStudy(notebookId) }
                        .disabled(cs.cards == 0)
                } label: {
                    Label("记忆卡", systemImage: "rectangle.on.rectangle.angled")
                }
                .help("把笔记本里的摘录做成记忆卡（牌组以笔记本命名），或只学习这本笔记本的卡片")
                .disabled(st.quoteCount == 0)
            }
            ToolbarItem {
                Button { store.openNotebookPicker(after: st.blocks.last?.id) } label: {
                    Label("插入摘录", systemImage: "text.quote")
                }
                .help("搜索摘录，勾选后插到末尾（也可在两块之间点“＋”插入）")
            }
            ToolbarItem {
                Menu {
                    Button("Word 文档（含脚注、目录、页码）…") { NotebookExport.exportDocx(store: store) }
                    Button("演示稿（PowerPoint / Keynote）…") { NotebookExport.exportPptx(store: store) }
                    Button("PDF（讲义、打印）…") { NotebookExport.exportPDF(store: store) }
                    Button("Markdown（脚注 [^1]）…") { NotebookExport.exportMarkdown(store: store) }
                    Button("复制到剪贴板（粘到 Word、Pages，含脚注）") { NotebookExport.copyRTF(store: store) }
                    Divider()
                    Toggle("出处做成脚注（否则写在引文后的括号里）", isOn: Bindable(st).exportFootnotes)
                    Toggle("文末附参考文献表（GB/T 7714）", isOn: Bindable(st).exportBibliography)
                    Toggle("附上摘录的按语", isOn: Bindable(st).exportNotes)
                    Toggle("Word 加目录（按小标题）", isOn: Bindable(st).exportTOC)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .help("导出为 Word、演示稿、Markdown，或复制后粘到 Word")
            }
            ToolbarItem {
                Menu {
                    Button("删除这本笔记本…", role: .destructive) {
                        store.notebookPendingDeletion = store.notebooks.first { $0.id == notebookId }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: Bindable(st).picker) { _ in NotebookPickerView() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("笔记本标题", text: Binding(
                get: { st.titleDraft },
                set: { st.titleDraft = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 26, weight: .bold, design: .serif))
            .foregroundStyle(ReviewPalette.ink)
            .onSubmit { store.renameNotebook(notebookId, to: st.titleDraft) }
            .onChange(of: st.titleDraft) {
                // 停顿后自动保存标题
                let t = st.titleDraft
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if st.titleDraft == t { store.renameNotebook(notebookId, to: t) }
                }
            }
            Text("把摘录与自己的文字编排成一篇长文。两块之间点“＋”插入文字、小标题或摘录；拖动左侧把手或用 ↑↓ 调整顺序。导出 Word 时摘录出处自动成为脚注。")
                .font(.system(size: 12))
                .foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.book.closed").font(.system(size: 34)).foregroundStyle(ReviewPalette.sub)
            Text("还没有内容").font(.headline)
            Text("在摘录列表或回顾卡片上选“加入专题笔记本”，或从这里开始：")
                .font(.callout).foregroundStyle(ReviewPalette.sub)
            HStack(spacing: 10) {
                PillButton(icon: "text.quote", title: "插入摘录…") { store.openNotebookPicker(after: nil) }
                PillButton(icon: "text.alignleft", title: "写一段文字") { store.insertNotebookBlock(.text, after: nil) }
                PillButton(icon: "textformat.size", title: "小标题") { store.insertNotebookBlock(.heading, after: nil) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// 块之间的插入条：平时是一条细缝，鼠标移上去出现“＋”
struct InsertBar: View {
    @Environment(LibraryStore.self) private var store
    let after: Int64?
    var atStart = false

    var body: some View {
        let key: Int64 = atStart ? -1 : (after ?? -2)
        let hovered = store.notebookState.hoveredGap == key
        HStack(spacing: 8) {
            Rectangle().fill(hovered ? ReviewPalette.accent.opacity(0.35) : Color.clear).frame(height: 1)
            Menu {
                Button("文字") { store.insertNotebookBlock(.text, after: after, atStart: atStart) }
                Button("小标题") { store.insertNotebookBlock(.heading, after: after, atStart: atStart) }
                Button("摘录…") { store.openNotebookPicker(after: after, atStart: atStart) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ReviewPalette.accent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(ReviewPalette.card))
                    .overlay(Circle().stroke(ReviewPalette.accent.opacity(0.4)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .handCursor()
            .opacity(hovered ? 1 : 0)
            .help("在这里插入文字、小标题或摘录")
            Rectangle().fill(hovered ? ReviewPalette.accent.opacity(0.35) : Color.clear).frame(height: 1)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { store.notebookState.hoveredGap = key } else if store.notebookState.hoveredGap == key { store.notebookState.hoveredGap = nil }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = Int64(s) else { return false }
            // 拖到这条缝上：放到“下一块”之前
            let blocks = store.notebookState.blocks
            let next: Int64?
            if atStart { next = blocks.first?.id }
            else if let after, let i = blocks.firstIndex(where: { $0.id == after }) { next = i + 1 < blocks.count ? blocks[i + 1].id : nil }
            else { next = nil }
            store.moveNotebookBlock(id, before: next)
            return true
        }
    }
}

/// 一块：左侧把手（拖动）、内容、右侧操作（上移、下移、删除）
struct NotebookBlockRow: View {
    @Environment(LibraryStore.self) private var store
    let block: NotebookBlock

    var body: some View {
        let id = block.id ?? 0
        let st = store.notebookState
        let hovered = st.hovered == id
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ReviewPalette.sub)
                .frame(width: 16, height: 24)
                .opacity(hovered ? 1 : 0.15)
                .draggable(String(id)) {
                    Text(dragPreview).font(.callout).padding(8)
                        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 6))
                }
                .handCursor()
                .help("拖动调整位置")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                CardIconButton(icon: "chevron.up", help: "上移") { store.moveNotebookBlock(id, by: -1) }
                CardIconButton(icon: "chevron.down", help: "下移") { store.moveNotebookBlock(id, by: 1) }
                CardIconButton(icon: "trash", help: "删除这一块（⌘Z 可撤销）") { store.deleteNotebookBlock(id) }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { st.hovered = id } else if st.hovered == id { st.hovered = nil }
        }
    }

    private var dragPreview: String {
        let t = block.kind == .highlight
            ? (block.highlightId.flatMap { store.notebookState.highlights[$0]?.text } ?? block.text)
            : block.text
        return String(NotebookExporter.plain(t).prefix(40))
    }

    @ViewBuilder
    private var content: some View {
        let id = block.id ?? 0
        switch block.kind {
        case .heading:
            TextField("小标题", text: Binding(
                get: { store.notebookState.blocks.first { $0.id == id }?.text ?? "" },
                set: { store.updateNotebookBlockText(id, $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ReviewPalette.ink)
            .padding(.top, 10)
        case .text:
            RichEditor(text: Binding(
                get: { store.notebookState.blocks.first { $0.id == id }?.text ?? "" },
                set: { store.updateNotebookBlockText(id, $0) }
            ), font: .body, placeholder: "写一段文字：过渡、论述、小结……", toolbar: false, autoHeight: true,
               minHeight: 44, focus: block.text.isEmpty, slot: "nb-\(id)")
        case .highlight:
            quote
        }
    }

    /// 有本文批注，或刚点了“＋ 本文批注”
    private var hasNote: Bool {
        let cur = store.notebookState.blocks.first { $0.id == block.id }?.note ?? block.note
        return !(cur ?? "").isEmpty || (block.id != nil && store.notebookState.editingNote == block.id)
    }

    private var quote: some View {
        let h = block.highlightId.flatMap { store.notebookState.highlights[$0] }
        let text = h?.text ?? block.text
        let source = h.flatMap { store.source(for: $0) }
        let cite = h.map { CitationFormatter.citation(for: $0, source: source, style: CitationSettings.style) } ?? ""
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5).fill(ReviewPalette.accent.opacity(0.55)).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(MarkdownText.attributed(text))
                    .font(.system(size: 15.5, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(cite.isEmpty ? (h == nil ? "原摘录已删除（保留加入时的文字）" : "无出处") : cite)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ReviewPalette.sub)
                        .lineLimit(2)
                    if let h {
                        Button("编辑摘录") { store.edit(h) }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                            .handCursor()
                    }
                    if !hasNote, let id = block.id {
                        Button("＋ 本文批注") { store.notebookState.editingNote = id }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                            .handCursor()
                            .help("只属于这本笔记本的批注，不改原摘录的按语；导出 Word 时排在引文后，导出演示稿时放进演讲者备注")
                    }
                }
                if hasNote, let id = block.id {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本文批注").font(.system(size: 11, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                        RichEditor(text: Binding(
                            get: { store.notebookState.blocks.first { $0.id == id }?.note ?? "" },
                            set: { store.updateNotebookBlockNote(id, $0) }
                        ), font: .note, placeholder: "写下这条引文在本文中的用意、要讲的要点……", toolbar: false, autoHeight: true,
                           minHeight: 40, focus: store.notebookState.editingNote == id && (block.note ?? "").isEmpty,
                           slot: "nb-note-\(id)")
                        .richEditorFrame()
                    }
                    .padding(.top, 4)
                    .onDisappear { if store.notebookState.editingNote == id { store.notebookState.editingNote = nil } }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReviewPalette.hair))
    }
}

/// 插入摘录：搜索（繁简通搜），勾选，按勾选顺序插入
struct NotebookPickerView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let p = store.notebookState.picker
        return VStack(alignment: .leading, spacing: 10) {
            Text("插入摘录").font(.title2.bold())
            TextField("搜索原文、译文、按语", text: Binding(
                get: { store.notebookState.picker?.query ?? "" },
                set: { store.searchNotebookPicker($0) }
            ))
            .textFieldStyle(.roundedBorder)
            List {
                ForEach(p?.results ?? []) { h in
                    let picked = p?.selected.firstIndex(of: h.id ?? -1)
                    Button {
                        guard let id = h.id else { return }
                        if let k = store.notebookState.picker?.selected.firstIndex(of: id) {
                            store.notebookState.picker?.selected.remove(at: k)
                        } else {
                            store.notebookState.picker?.selected.append(id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().stroke(ReviewPalette.hair).frame(width: 18, height: 18)
                                if let k = picked {
                                    Circle().fill(ReviewPalette.accent).frame(width: 18, height: 18)
                                    Text("\(k + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(RichText.marked(h.text, terms: SearchTerms.terms(p?.query ?? "")))
                                    .font(.system(size: 13.5, design: .serif))
                                    .lineLimit(3)
                                Text(store.source(for: h).map { "《\($0.title)》" + (h.location.map { " · " + $0 } ?? "") } ?? "未归类")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
            .listStyle(.inset)
            HStack {
                Text((p?.selected.isEmpty ?? true) ? "点选摘录（可多选，按点选顺序插入）" : "已选 \(p?.selected.count ?? 0) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { store.notebookState.picker = nil }
                    .keyboardShortcut(.cancelAction)
                Button("插入") { store.commitNotebookPicker() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(p?.selected.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}

/// 新建笔记本：输入标题
struct NewNotebookView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建专题笔记本").font(.title2.bold())
            TextField("标题，如“《论语》中的学与思”", text: Binding(
                get: { store.newNotebookRequest?.title ?? "" },
                set: { store.newNotebookRequest?.title = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit(create)
            if let n = store.newNotebookRequest?.highlightIDs.count, n > 0 {
                Text("建好后放入所选的 \(n) 条摘录。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.newNotebookRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("新建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        guard let r = store.newNotebookRequest else { return }
        store.newNotebookRequest = nil
        store.createNotebook(title: r.title, with: r.highlightIDs)
    }
}

/// “加入专题笔记本”子菜单（摘录右键、批量操作、回顾卡片）
struct AddToNotebookMenu: View {
    @Environment(LibraryStore.self) private var store
    let ids: [Int64]

    var body: some View {
        Menu("加入专题笔记本") {
            ForEach(store.notebooks) { n in
                if let nid = n.id {
                    Button(n.title) { store.addHighlights(ids, toNotebook: nid) }
                }
            }
            if !store.notebooks.isEmpty { Divider() }
            Button("新建笔记本…") { store.newNotebookRequest = NewNotebookRequest(highlightIDs: ids) }
        }
    }
}

struct NotebookSheets: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content
            .sheet(item: $store.newNotebookRequest) { _ in NewNotebookView() }
            .confirmationDialog(
                "删除笔记本《\(store.notebookPendingDeletion?.title ?? "")》？",
                isPresented: Binding(
                    get: { store.notebookPendingDeletion != nil },
                    set: { if !$0 { store.notebookPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除笔记本", role: .destructive) {
                    if let n = store.notebookPendingDeletion { store.deleteNotebook(n) }
                    store.notebookPendingDeletion = nil
                }
                Button("取消", role: .cancel) { store.notebookPendingDeletion = nil }
            } message: {
                Text("只删除笔记本和其中的文字，库里的摘录不受影响。删除前自动备份。")
            }
    }
}

// MARK: - 导出

@MainActor
enum NotebookExport {
    static func options(_ store: LibraryStore) -> NotebookExportOptions {
        NotebookExportOptions(footnotes: store.notebookState.exportFootnotes,
                              bibliography: store.notebookState.exportBibliography ? store.notebookBibliography() : [],
                              toc: store.notebookState.exportTOC)
    }

    static func title(_ store: LibraryStore) -> String {
        let t = store.notebookState.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "专题笔记本" : t
    }

    static func savePanel(_ name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "／")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exportDocx(store: LibraryStore) {
        store.flushNotebookSaves()
        let t = title(store)
        guard let url = savePanel(t + ".docx", type: UTType(filenameExtension: "docx") ?? .data) else { return }
        let files = NotebookDocx.files(title: t, pieces: store.notebookPieces(), options: options(store))
        writePackage(files, to: url, store: store, what: "Word")
    }

    /// 1.6：PDF（出处排成节末注；页眉、页码在生成后补画）
    static func exportPDF(store: LibraryStore) {
        store.flushNotebookSaves()
        let t = title(store)
        guard let url = savePanel(t + ".pdf", type: .pdf) else { return }
        let html = NotebookHTML.page(title: t, pieces: store.notebookPieces(), options: options(store))
        store.importProgress = "正在生成 PDF…"
        PDFExporter.export(html: html, title: t, to: url) { error in
            store.importProgress = nil
            if let error {
                store.report(error)
            } else {
                AppLog.write("导出专题笔记本为 PDF")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// 1.4：演示稿
    static func exportPptx(store: LibraryStore) {
        store.flushNotebookSaves()
        let t = title(store)
        guard let url = savePanel(t + ".pptx", type: UTType(filenameExtension: "pptx") ?? .data) else { return }
        let files = NotebookPptx.files(title: t, pieces: store.notebookPieces(), options: options(store))
        writePackage(files, to: url, store: store, what: "演示稿")
    }

    /// 把各部件写进临时文件夹，用系统自带的 zip 打包成 .docx / .pptx
    static func writePackage(_ files: [String: String], to url: URL, store: LibraryStore, what: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-ooxml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            for (path, xml) in files {
                let f = tmp.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try xml.write(to: f, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.removeItem(at: url)
            let tops = Set(files.keys.map { String($0.split(separator: "/").first ?? "") }).sorted()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = tmp
            // [Content_Types].xml 放在最前面
            p.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml"] + tops.filter { $0 != "[Content_Types].xml" }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ImportFileError("打包\(what)失败（zip 退出码 \(p.terminationStatus)）。") }
            AppLog.write("导出专题笔记本为\(what)：\(store.notebookState.blocks.count) 块")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.report(error)
        }
    }

    static func exportMarkdown(store: LibraryStore) {
        store.flushNotebookSaves()
        let t = title(store)
        guard let url = savePanel(t + ".md", type: UTType(filenameExtension: "md") ?? .plainText) else { return }
        do {
            try NotebookExporter.markdown(title: t, pieces: store.notebookPieces(), options: options(store))
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.report(error)
        }
    }

    static func copyRTF(store: LibraryStore) {
        store.flushNotebookSaves()
        let t = title(store)
        let pieces = store.notebookPieces()
        let opts = options(store)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = NotebookExporter.rtf(title: t, pieces: pieces, options: opts).data(using: .ascii) {
            pb.setData(data, forType: .rtf)
        }
        pb.setString(NotebookExporter.markdown(title: t, pieces: pieces, options: opts), forType: .string)
        store.infoMessage = "已复制。在 Word 或 Pages 里按 ⌘V 粘贴，摘录出处会成为脚注。"
    }
}
