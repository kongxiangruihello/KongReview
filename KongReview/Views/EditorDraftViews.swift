import SwiftUI
import KongReviewCore

/// 首页入口仅在有实际未保存内容时出现；用户可继续其他工作，再按需恢复。
struct DraftRecoveryBanner: View {
    var highlights: [SavedHighlightDraft]
    var cards: [SavedCardDraft]
    var onOpen: () -> Void

    var body: some View {
        let count = highlights.count + cards.count
        if count > 0 {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.clock").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("有 \(count) 份未保存的编辑草稿").font(.headline)
                    Text("可继续编辑，也可查看后放弃。草稿保存在这台 Mac 上。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看草稿", action: onOpen).buttonStyle(.bordered)
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 恢复列表的状态由 LibraryStore 持有。两类草稿分别存储，可以同时保留多份。
struct EditorDraftRecoverySheet: View {
    @Environment(LibraryStore.self) private var store
    var highlights: [SavedHighlightDraft]
    var cards: [SavedCardDraft]
    var onRestoreHighlight: (UUID) -> Void
    var onRestoreCard: (UUID) -> Void
    var onDiscardHighlight: (UUID) -> Void
    var onDiscardCard: (UUID) -> Void
    var onClose: () -> Void
    @State private var query = EditorDraftQuery()
    @State private var requestedPage = 1
    @State private var jumpPage = "1"
    @State private var preview: EditorDraftItem?
    @State private var pendingPreviewRestore: EditorDraftItem?
    @State private var previewMessage: String?

    private var result: EditorDraftPage {
        query.page(highlights: highlights, cards: cards, requestedPage: requestedPage)
    }

    var body: some View {
        let page = result
        VStack(alignment: .leading, spacing: 14) {
            Text("未保存的编辑草稿").font(.title2.bold())
            Text("选择一份继续编辑。恢复时若原条目已经更新或删除，草稿会作为新条目打开，保留现有数据。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            filters
            if let previewMessage {
                Text(previewMessage).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(page.items) { item in
                        recoveryRow(item)
                    }
                    if page.total == 0 {
                        ContentUnavailableView(highlights.isEmpty && cards.isEmpty ? "没有待恢复的草稿" : "没有符合条件的草稿",
                                               systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.trailing, 6)
            }
            pagination(page)
            HStack {
                Text("恢复后点“保存”才会写入正式数据。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("稍后处理", action: onClose).keyboardShortcut(.cancelAction).handCursor()
            }
        }
        .padding(24)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 460, idealHeight: 620)
        .onChange(of: query) { _, _ in requestedPage = 1; jumpPage = "1" }
        .onChange(of: page.page) { _, current in requestedPage = current; jumpPage = String(current) }
        .sheet(item: $preview, onDismiss: finishPreviewRestore) { item in
            EditorDraftReadOnlyPreview(item: item) {
                guard isCurrent(item) else { return }
                pendingPreviewRestore = item
                preview = nil
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索正文、题面、标签或牌组", text: $query.keyword)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("draft-recovery-search")
            HStack(spacing: 16) {
                Picker("类型", selection: Binding(get: { query.kind }, set: { query.kind = $0; query.deck = nil })) {
                    ForEach(EditorDraftQuery.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }.frame(width: 200)
                Picker("牌组", selection: Binding(get: { query.deck ?? "" }, set: {
                    query.deck = $0.isEmpty ? nil : $0
                    if !$0.isEmpty { query.kind = .card }
                })) {
                    Text("全部牌组").tag("")
                    ForEach(EditorDraftQuery.decks(in: cards), id: \.self) { Text($0).tag($0) }
                    if let deck = query.deck, !cards.contains(where: { $0.card.deck == deck }) {
                        Text(deck + "（无草稿）").tag(deck)
                    }
                }.frame(maxWidth: 300)
                Spacer(minLength: 0)
                Button("清除筛选") { query = EditorDraftQuery() }.handCursor()
            }
            if query.deck != nil {
                Text("选择牌组时仅显示该牌组的记忆卡草稿。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pagination(_ page: EditorDraftPage) -> some View {
        HStack(spacing: 10) {
            Text(page.rangeText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("上一页") { move(to: page.page - 1) }.disabled(page.page <= 1).handCursor()
            Text("\(page.page) / \(page.pageCount)").font(.callout).monospacedDigit()
            Button("下一页") { move(to: page.page + 1) }.disabled(page.page >= page.pageCount).handCursor()
            TextField("页码", text: $jumpPage).frame(width: 44).textFieldStyle(.roundedBorder)
                .onSubmit(jump)
            Button("跳转", action: jump).handCursor()
        }
    }

    private func move(to page: Int) {
        requestedPage = min(max(1, page), result.pageCount)
        jumpPage = String(requestedPage)
    }

    private func jump() {
        guard let page = Int(jumpPage.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            jumpPage = String(result.page); return
        }
        move(to: page)
    }

    private func recoveryRow(_ item: EditorDraftItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(item.subtitle) · \(item.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("预览") { previewMessage = nil; preview = item }.buttonStyle(.bordered).handCursor()
            Button("继续编辑") { restore(item) }.buttonStyle(.borderedProminent).handCursor()
            Button("放弃草稿", role: .destructive) {
                switch item {
                case .highlight(let draft): onDiscardHighlight(draft.id)
                case .card(let draft): onDiscardCard(draft.id)
                }
            }.buttonStyle(.bordered).handCursor()
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func isCurrent(_ item: EditorDraftItem) -> Bool {
        // Read the current store on the action itself, rather than arrays captured when the sheet opened.
        item.current(in: store.savedHighlightDrafts, cards: store.savedCardDrafts).map { item.matches($0) } ?? false
    }

    private func restore(_ item: EditorDraftItem) {
        guard isCurrent(item) else {
            previewMessage = "这份草稿已更新或移除，请重新预览当前列表中的草稿。"
            return
        }
        switch item {
        case .highlight(let draft): onRestoreHighlight(draft.id)
        case .card(let draft): onRestoreCard(draft.id)
        }
    }

    private func finishPreviewRestore() {
        guard let item = pendingPreviewRestore else { return }
        pendingPreviewRestore = nil
        restore(item)
    }
}

/// A stable nested sheet preserves the list's filters and page when its preview closes.
private struct EditorDraftReadOnlyPreview: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: EditorDraftItem
    let onRestore: () -> Void
    @State private var showingAnswer = false

    private var isCurrent: Bool {
        item.current(in: store.savedHighlightDrafts, cards: store.savedCardDrafts).map { item.matches($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("草稿预览").font(.title2.bold())
            Text(item.subtitle + " · " + item.savedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout).foregroundStyle(.secondary)
            if !isCurrent {
                Label("这份草稿已更新或移除。请关闭预览，重新选择当前草稿。", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            previewContent
            HStack {
                Button("关闭预览") { dismiss() }.keyboardShortcut(.cancelAction).handCursor()
                Spacer()
                if case .card = item {
                    Button(showingAnswer ? "返回正面" : "显示答案") { showingAnswer.toggle() }.handCursor()
                }
                Button("继续编辑", action: onRestore).buttonStyle(.borderedProminent).disabled(!isCurrent).handCursor()
            }
        }.padding(20).frame(minWidth: 660, idealWidth: 760, minHeight: 500, idealHeight: 650)
    }

    @ViewBuilder private var previewContent: some View {
        switch item {
        case .card(let draft):
            let faces = draft.card.faces(using: draft.card.noteType.flatMap { store.noteTemplates[$0] })
            if let type = draft.card.noteType { Text("模板：" + type).font(.caption).foregroundStyle(.secondary) }
            Text("只读预览，不计入学习记录；折叠栏目可展开查看。")
                .font(.caption).foregroundStyle(.secondary)
            CardWebView(front: faces.front, back: showingAnswer ? faces.back : nil, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !draft.tagsText.isEmpty { Text("标签：" + draft.tagsText).font(.caption).textSelection(.enabled) }
        case .highlight(let draft):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    passage("正文", draft.highlight.text)
                    if let text = draft.highlight.translation, !text.isEmpty { passage("译文", text) }
                    if let text = draft.highlight.note, !text.isEmpty { passage("按语", text) }
                    if !draft.tagsText.isEmpty { passage("标签", draft.tagsText) }
                    if let location = draft.highlight.location, !location.isEmpty { passage("位置", location) }
                    if !draft.newSourceTitle.isEmpty { passage("新出处", draft.newSourceTitle) }
                    if !draft.newSourceAuthor.isEmpty { passage("作者", draft.newSourceAuthor) }
                    if !draft.newSourceURL.isEmpty { passage("出处链接", draft.newSourceURL) }
                    ForEach(draft.editionPages.keys.sorted(), id: \.self) { id in
                        if let pages = draft.editionPages[id], !pages.isEmpty { passage("版本 #\(id) 页码", pages) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
        }
    }

    private func passage(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline).foregroundStyle(.secondary)
            Text(RichText.attributed(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
