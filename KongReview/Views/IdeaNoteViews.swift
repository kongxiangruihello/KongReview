import SwiftUI
import KongReviewCore

// MARK: - 4.1：札记——列表、札记页、记札记面板、引用摘录选择

/// 全部札记：按最近修改；可搜索，可看已删除
struct IdeaNoteListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var showsDeleted = false
    @State private var items: [IdeaNoteSummary] = []
    @State private var confirmPurge: IdeaNoteSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("札记").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("一条札记写一个观点，用自己的话写，题目就是观点本身。可引用多条摘录，用 [[题目]] 链接其他札记；被引用、被链接的地方会显示反向链接。")
                        .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { store.composeIdeaNote() } label: { Label("新写札记", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).handCursor()
                    TextField("搜索题目与正文（繁简通搜）", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Spacer()
                    Picker("", selection: $showsDeleted) { Text("在用").tag(false); Text("已删除").tag(true) }
                        .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                if items.isEmpty {
                    ContentUnavailableView(showsDeleted ? "没有已删除的札记" : (query.isEmpty ? "还没有札记" : "没有找到"),
                                           systemImage: "lightbulb",
                                           description: Text(showsDeleted ? "" : "在今日回顾按 Z，或在按语旁点“发展为札记”，都可以开始写。"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
                ForEach(items) { n in row(n) }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("札记")
        .task(id: "\(query)|\(showsDeleted)|\(store.ideaNoteRevision)") {
            try? await Task.sleep(nanoseconds: query.isEmpty ? 0 : 250_000_000)
            guard !Task.isCancelled else { return }
            items = (try? await store.db.ideaNoteSummaries(query: query, deleted: showsDeleted)) ?? []
        }
        .confirmationDialog("彻底删除札记“\(confirmPurge?.title ?? "")”？", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button("彻底删除", role: .destructive) { if let n = confirmPurge { store.purgeIdeaNote(n.id) }; confirmPurge = nil }
        } message: { Text("引用的摘录本身不受影响；其他札记里指向它的 [[题目]] 会显示为“未建”。此操作无法撤销。") }
    }

    private func row(_ n: IdeaNoteSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb").foregroundStyle(ReviewPalette.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(n.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                if !n.preview.isEmpty { Text(n.preview).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).lineLimit(2) }
                Text("修改于 \(n.updatedAt.formatted(.dateTime.year().month().day())) · 引用摘录 \(n.highlightCount) · 被链接 \(n.backlinkCount)")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 8)
            if n.deletedAt != nil {
                Button("恢复") { store.setIdeaNoteDeleted(n.id, false) }.controlSize(.small).handCursor()
                Button("彻底删除", role: .destructive) { confirmPurge = n }.controlSize(.small).handCursor()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        .contentShape(Rectangle())
        .onTapGesture { if n.deletedAt == nil { store.selection = .ideaNote(n.id) } }
        .handCursor()
    }
}

/// 札记页：左栏观点与引文，右栏反向链接与可能相关的摘录
struct IdeaNoteView: View {
    @Environment(LibraryStore.self) private var store
    let noteId: Int64
    @State private var detail: IdeaNoteDetail?
    @State private var missing = false
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var picking = false
    @State private var related: [Highlight] = []
    /// 4.1.1：以本札记为解答的问题、挂着本札记的问题
    @State private var questions: (answered: [QuestionRef], holding: [QuestionRef]) = ([], [])
    /// 4.1.2：收入了这条札记的专题笔记本
    @State private var notebooks: [Notebook] = []

    var body: some View {
        Group {
            if let d = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(d)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 18) {
                                main(d).frame(maxWidth: .infinity, alignment: .leading)
                                side(d).frame(width: 260)
                            }
                            .frame(minWidth: 720)
                            VStack(alignment: .leading, spacing: 18) { main(d); side(d) }
                        }
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
            } else if missing {
                ContentUnavailableView("这条札记已被彻底删除", systemImage: "lightbulb.slash")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(detail?.note.title ?? "札记")
        .task(id: "\(noteId)|\(store.ideaNoteRevision)|\(store.questionRevision)") { await load() }
        .onDisappear { if editing { commit() } }
        .sheet(isPresented: $picking) {
            HighlightPickerSheet(excluding: Set(detail?.highlights.compactMap(\.id) ?? [])) { ids in
                store.addHighlights(ids, toIdeaNote: noteId)
            }
            .environment(store)
        }
    }

    private func load() async {
        do {
            let d = try await store.db.ideaNoteDetail(id: noteId)
            detail = d; missing = false
            questions = (try? await store.db.questionsForNote(noteId)) ?? ([], [])
            notebooks = (try? store.db.notebooksContaining(noteId: noteId)) ?? []
            if !editing { draftTitle = d.note.title; draftBody = d.note.body }
            let cited = Set(d.highlights.compactMap(\.id))
            if let index = store.relatedIndex {
                let ids = index.related(toText: d.note.title + "\n" + Markdown.plainText(fromHTML: d.note.body), excluding: cited, limit: 5).map(\.id)
                let hs = (try? store.db.highlights(ids: ids)) ?? []
                related = ids.compactMap { id in hs.first { $0.id == id } }
            } else { related = [] }
        } catch IdeaNoteError.missing { detail = nil; missing = true }
        catch { store.report(error) }
    }

    private func commit() {
        guard let d = detail else { return }
        if draftTitle != d.note.title || draftBody != d.note.body {
            guard store.saveIdeaNote(id: noteId, title: draftTitle, body: draftBody) else { return }
        }
        editing = false
    }

    // MARK: 顶部

    private func header(_ d: IdeaNoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("札记", systemImage: "lightbulb").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                Spacer()
                ResearchProjectLinkMenu(kind: .note, recordId: noteId).fixedSize()
                Button(editing ? "完成" : "编辑") { if editing { commit() } else { draftTitle = d.note.title; draftBody = d.note.body; editing = true } }
                    .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .buttonStyle(.borderedProminent).controlSize(.small).handCursor()
                    .disabled(editing && WikiLinks.normalize(draftTitle).isEmpty)
                Menu {
                    Button("挂到问题…") { store.attachToQuestion(kind: .note, recordId: noteId, preview: d.note.title) }
                    Divider()
                    Button("删除（可在“已删除”中恢复）", role: .destructive) { store.setIdeaNoteDeleted(noteId, true) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if editing {
                TextField("题目：一句话的观点", text: $draftTitle)
                    .font(.system(size: 22, weight: .semibold, design: .serif)).textFieldStyle(.plain)
            } else {
                Text(d.note.title).font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("写于 \(d.note.createdAt.formatted(.dateTime.year().month().day())) · 修改于 \(d.note.updatedAt.formatted(.dateTime.year().month().day())) · 引用摘录 \(d.highlights.count) · 被链接 \(d.backlinks.count)")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
        }
        .disabled(store.fullBackupBusy)
    }

    // MARK: 左栏

    @ViewBuilder private func main(_ d: IdeaNoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if editing {
                RichEditor(text: $draftBody, placeholder: "用自己的话写下这个观点；输入 [[ 即可选择要链接的札记", autoHeight: true, minHeight: 180, slot: "idea-note-body",
                           wikiCompletion: { [noteId] q in store.wikiSuggestions(q, excluding: noteId) })
                    .richEditorFrame()
                HStack(spacing: 12) {
                    Menu {
                        ForEach(((try? store.db.recentIdeaNotes(limit: 40)) ?? []).filter { $0.id != noteId }) { n in
                            Button(n.title) { appendLink(n.title) }
                        }
                    } label: { Label("链接札记…", systemImage: "link") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("在正文末尾加上 [[题目]]；更方便的是直接在正文里输入 [[，从列表中选")
                    Text("⌘↩ 完成").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
            } else if d.note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("还没有正文。点“编辑”写下这个观点。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            } else {
                let targets = Dictionary(d.outgoing.map { (WikiLinks.key($0.title), $0.id) }, uniquingKeysWith: { a, _ in a })
                RichWebText(text: d.note.body, style: .preview, slot: "idea-note-\(noteId)",
                            linkify: { html in WikiLinks.render(html) { targets[WikiLinks.key($0)] } })
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("引用摘录 · \(d.highlights.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                    Spacer()
                    Button { picking = true } label: { Label("引用摘录…", systemImage: "plus").font(.system(size: 12.5)) }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                }
                if d.highlights.isEmpty {
                    Text("这个观点所依据的材料：点“引用摘录”搜索添加，或在今日回顾时按 Z 把当前摘录加进来。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(d.highlights.enumerated()), id: \.element.id) { i, h in quote(h, index: i, all: d.highlights) }
            }
        }
    }

    private func appendLink(_ title: String) {
        let link = "[[\(title)]]"
        if draftBody.contains("<") { draftBody += "<p>\(link)</p>" } else { draftBody += (draftBody.isEmpty ? "" : "\n\n") + link }
    }

    private func quote(_ h: Highlight, index: Int, all: [Highlight]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(ReviewPalette.accent.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(Markdown.plainText(fromHTML: h.text)).font(.system(size: 14, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                let source = store.source(for: h)
                Text([source.map { "《\($0.title)》" }, h.location].compactMap { $0 }.joined(separator: " ")).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 6)
            VStack(spacing: 6) {
                Button { move(h, by: -1, in: all) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(h, by: 1, in: all) } label: { Image(systemName: "chevron.down") }.disabled(index == all.count - 1)
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(ReviewPalette.sub)
            Menu {
                Button("打开摘录") { store.edit(h) }
                Button("不再引用", role: .destructive) { if let id = h.id { store.removeHighlight(id, fromIdeaNote: noteId) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func move(_ h: Highlight, by delta: Int, in all: [Highlight]) {
        var ids = all.compactMap(\.id)
        guard let id = h.id, let i = ids.firstIndex(of: id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        store.reorderHighlights(ids, inIdeaNote: noteId)
    }

    // MARK: 右栏

    private func side(_ d: IdeaNoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectPanel(title: "反向链接", subtitle: "\(d.backlinks.count) 条") {
                if d.backlinks.isEmpty {
                    Text("还没有札记链接到这里。在其他札记里写 [[\(d.note.title)]] 即可。")
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(d.backlinks) { ref in noteLink(ref) }
            }
            if !questions.answered.isEmpty || !questions.holding.isEmpty {
                ProjectPanel(title: "相关问题", subtitle: "") {
                    ForEach(questions.answered) { q in questionLink(q, note: "以本札记为解答") }
                    ForEach(questions.holding.filter { h in !questions.answered.contains { $0.id == h.id } }) { q in questionLink(q, note: "挂着本札记") }
                }
            }
            if !notebooks.isEmpty {
                ProjectPanel(title: "收入专题", subtitle: "\(notebooks.count) 本") {
                    ForEach(notebooks) { n in
                        Button { if let id = n.id { store.selection = .notebook(id) } } label: {
                            Label(n.title, systemImage: "book.closed").font(.system(size: 13)).lineLimit(2)
                        }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                    }
                    Text("笔记本里的札记块随这里的正文更新。").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                }
            }
            if !d.outgoing.isEmpty || !d.unresolved.isEmpty {
                ProjectPanel(title: "本条链接到", subtitle: "") {
                    ForEach(d.outgoing) { ref in noteLink(ref) }
                    ForEach(d.unresolved, id: \.self) { title in
                        Button { _ = store.createIdeaNote(title: title, open: true) } label: {
                            Label("\(title)（未建，点击新建）", systemImage: "plus.circle").font(.system(size: 12.5)).lineLimit(2)
                        }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.sub).handCursor()
                    }
                }
            }
            ProjectPanel(title: "可能相关", subtitle: "未引用的摘录") {
                if related.isEmpty {
                    Text(store.relatedIndex == nil ? "相关索引正在建立。" : "暂无。正文写得越具体，找到的越准。")
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                }
                ForEach(related, id: \.id) { h in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Markdown.plainText(fromHTML: h.text)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink).lineLimit(3)
                        Spacer(minLength: 4)
                        Button { if let id = h.id { store.addHighlights([id], toIdeaNote: noteId) } } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor().help("引用这条摘录")
                    }
                }
                Text("按用词相近程度找出，只作提示，不自动引用。").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
        }
    }

    private func questionLink(_ q: QuestionRef, note: String) -> some View {
        Button { store.selection = .question(q.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(q.title, systemImage: "questionmark.bubble").font(.system(size: 13)).lineLimit(2)
                Text("\(q.status.title) · \(note)").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
    }

    private func noteLink(_ ref: IdeaNoteRef) -> some View {
        Button { store.selection = .ideaNote(ref.id) } label: {
            Label(ref.title, systemImage: "lightbulb").font(.system(size: 13)).lineLimit(2)
        }
        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
    }
}

/// 记札记：新写一条（引用当前摘录），或把当前摘录加入已有札记
struct IdeaNoteComposerSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var composer: IdeaNoteComposer
    @State private var appendMode = false
    @State private var query = ""
    @State private var candidates: [IdeaNoteSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(composer.fromAnnotation ? "按语发展为札记" : "记札记").font(.title2.bold())
            if !composer.highlightPreview.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(ReviewPalette.accent.opacity(0.6)).frame(width: 3)
                    Text(composer.highlightPreview + "…").font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.sub).lineLimit(2)
                }
                if !composer.fromAnnotation {
                    Picker("", selection: $appendMode) { Text("新写一条札记").tag(false); Text("加入已有札记").tag(true) }
                        .pickerStyle(.segmented).labelsHidden()
                }
            }
            if appendMode {
                TextField("搜索札记题目或正文", text: $query).textFieldStyle(.roundedBorder)
                List(candidates) { n in
                    Button {
                        if let h = composer.highlightID { store.addHighlights([h], toIdeaNote: n.id) }
                        close()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.title).font(.system(size: 13.5, weight: .medium))
                            Text("引用摘录 \(n.highlightCount) · 修改于 \(n.updatedAt.formatted(.dateTime.month().day()))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain).handCursor()
                }
                .frame(minHeight: 200)
                .task(id: query) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    candidates = Array(((try? await store.db.ideaNoteSummaries(query: query)) ?? []).prefix(50))
                }
            } else {
                TextField("题目：一句话的观点（如“乾嘉考据并非一味反理学”）", text: $composer.title)
                    .textFieldStyle(.roundedBorder).font(.system(size: 15))
                RichEditor(text: $composer.body, placeholder: "用自己的话写；输入 [[ 即可选择要链接的札记（可先空着，以后再写）",
                           autoHeight: true, minHeight: 140, slot: "idea-note-composer",
                           wikiCompletion: { q in store.wikiSuggestions(q) })
                    .richEditorFrame()
                if composer.fromAnnotation {
                    Text("按语本身不变；新札记以按语为底稿，并引用这条摘录。").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                if !appendMode {
                    Button("保存札记") {
                        let ids = composer.highlightID.map { [$0] } ?? []
                        if store.createIdeaNote(title: composer.title, body: composer.body, highlightIDs: ids) != nil {
                            close()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(WikiLinks.normalize(composer.title).isEmpty || store.fullBackupBusy)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
    }

    private func close() {
        store.ideaNoteComposer = nil
        dismiss()
    }
}

/// 引用摘录：搜索全部摘录，可多选（4.1.1：也用来给问题挂札记、记忆卡）
struct HighlightPickerSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let excluding: Set<Int64>
    var kind: GlobalSearchKind = .highlight
    var title = "引用摘录"
    var action = "引用"
    let onPick: ([Int64]) -> Void
    @State private var query = ""
    @State private var hits: [GlobalSearchHit] = []
    @State private var chosen: [Int64] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            TextField(kind == .highlight ? "搜索原文、译文、按语、出处或标签（繁简通搜）" : "搜索\(kind.title)（繁简通搜）", text: $query).textFieldStyle(.roundedBorder)
            List(hits) { hit in
                let id = hit.target.recordID
                let already = excluding.contains(id)
                Button {
                    guard !already else { return }
                    if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else { chosen.append(id) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: already ? "checkmark.circle" : (chosen.contains(id) ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(already ? Color.secondary : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.preview).font(.system(size: 13)).lineLimit(3)
                            Text(hit.title + (hit.context.isEmpty ? "" : " · " + hit.context) + (already ? " · 已\(action)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain).handCursor()
            }
            .frame(minHeight: 280)
            HStack {
                Text(chosen.isEmpty ? "可多选" : "已选 \(chosen.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { onPick(chosen); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { hits = []; return }
            hits = (try? await store.db.globalSearch(query: q, kind: kind, limit: 50))?.first?.items ?? []
        }
    }
}
