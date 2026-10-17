import SwiftUI
import KongReviewCore

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 168, ideal: 196, max: 280)
        } detail: {
            detail
        }
        .sheet(item: $store.editorDraft) { _ in
            HighlightEditorView().modifier(EditorDraftCloseConfirmation(kind: .highlight))
        }
        .sheet(item: $store.editingSource) { _ in
            SourceEditorView()
        }
        .overlay(alignment: .bottom) {
            if let progress = store.importProgress.flatMap({ store.pendingImport == nil ? $0 : nil })
                ?? store.articleProgress.flatMap({ store.addArticleDraft == nil ? $0 : nil })
                ?? store.maintenanceProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
        }
        .sheet(item: $store.addArticleDraft) { _ in
            AddArticleView()
        }
        .confirmationDialog(
            "删除“\(store.articlePendingDeletion?.title ?? "")”的存档？",
            isPresented: Binding(
                get: { store.articlePendingDeletion != nil },
                set: { if !$0 { store.articlePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除存档", role: .destructive) {
                if let a = store.articlePendingDeletion { store.deleteArticle(a) }
                store.articlePendingDeletion = nil
            }
            Button("取消", role: .cancel) { store.articlePendingDeletion = nil }
        } message: {
            Text("只删除保存的网页正文；这篇文章的出处和已经划下的摘录都会保留。")
        }
        .sheet(item: $store.batchPrompt) { _ in
            BatchPromptView()
        }
        .sheet(item: $store.exportRequest) { _ in
            ExportOptionsView()
        }
        .sheet(item: $store.mergeRequest) { _ in
            MergeSourcesView()
        }
        .confirmationDialog(
            store.sourcesPendingDeletion.count == 1
                ? "删除出处“\(store.sourcesPendingDeletion.first?.title ?? "")”？"
                : "删除 \(store.sourcesPendingDeletion.count) 个出处？",
            isPresented: Binding(
                get: { !store.sourcesPendingDeletion.isEmpty },
                set: { if !$0 { store.sourcesPendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除出处", role: .destructive) { store.commitDeleteSources() }
            Button("取消", role: .cancel) { store.sourcesPendingDeletion = [] }
        } message: {
            Text("其下的摘录会保留，转入“未归类”。")
        }
        .sheet(item: $store.pendingImport) { _ in
            ImportPreviewView()
        }
        .sheet(item: $store.cardImport) { _ in
            CardImportPreviewView()
        }
        .sheet(item: $store.cardEditor) { _ in
            CardEditorView().modifier(EditorDraftCloseConfirmation(kind: .card))
        }
        .sheet(item: $store.articleSourceDraft) { _ in
            ArticleSourceEditorView()
        }
        .modifier(CardSheets())
        .modifier(EditorDraftRecoverySheets())
        .modifier(TagSheets())
        .modifier(WritingSheets())
        .modifier(NotebookSheets())
        .modifier(MaintenanceSheets())
        .alert("完成", isPresented: Binding(
            get: { store.infoMessage != nil },
            set: { if !$0 { store.infoMessage = nil } }
        )) {
            Button("好") { store.infoMessage = nil }
        } message: {
            Text(store.infoMessage ?? "")
        }
        .confirmationDialog(
            "删除出处“\(store.sourcePendingDeletion?.title ?? "")”？",
            isPresented: Binding(
                get: { store.sourcePendingDeletion != nil },
                set: { if !$0 { store.sourcePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除出处", role: .destructive) {
                if let s = store.sourcePendingDeletion { store.delete(s) }
                store.sourcePendingDeletion = nil
            }
            Button("取消", role: .cancel) { store.sourcePendingDeletion = nil }
        } message: {
            Text("其下的摘录会保留，转入“未归类”。")
        }
        .onAppear {
            // 让菜单栏、链接等 AppKit 代码在主窗口关闭后也能重新打开它
            WindowOpener.openMain = { openWindow(id: "main") }
            WindowOpener.openSettingsAction = { openSettings() }
            // 撤销：用主窗口的撤销管理器（“编辑”菜单的撤销 / 重做与 ⌘Z、⇧⌘Z）
            store.undoManager = undoManager
        }
        .alert("出错了", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .home, .none:
            HomeView()
        case .review:
            DailyReviewView()
        case .all:
            HighlightListView(title: "全部摘录", filter: .init())
        case .favorites:
            HighlightListView(title: "收藏", filter: .init(favoritesOnly: true))
        case .cards:
            CardsHomeView()
        case .stats:
            StatsView()
        case .unsorted:
            HighlightListView(title: "未归类", filter: .init(unsortedOnly: true))
        case .trash:
            HighlightListView(title: "最近删除", filter: .init(deletedOnly: true))
        case .articles:
            ArticlesView()
        case .sourceManager:
            SourceManagerView()
        case .help:
            HelpView()
        case .saved(let id):
            if let saved = store.savedSearches.first(where: { $0.id == id }) {
                HighlightListView(title: saved.name, filter: .init(), saved: saved)
            } else {
                ContentUnavailableView("这个已存搜索已删除", systemImage: "bookmark.slash")
            }
        case .notebook(let id):
            NotebookView(notebookId: id).id(id)
        case .source(let id):
            let title = store.sources.first { $0.id == id }?.title ?? "出处"
            HighlightListView(title: title, filter: .init(sourceId: id))
        case .tag(let tag):
            HighlightListView(title: "#\(tag)", filter: .init(tag: tag))
        }
    }
}

// Source 需要 Identifiable 才能用于 .sheet(item:)；Core 里已声明（id 为 Int64?）。
// 新建出处时 id 为 nil，多个 nil 会被视为同一项，但同一时间只会弹出一个面板，不影响使用。

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(
            get: { store.selection },
            set: { destination in
                if destination == .review { store.openTodayReview() }
                else if destination == .cards { store.openCardsHome() }
                else { store.selection = destination }
            }
        )) {
            Section {
                Label("首页", systemImage: "house")
                    .sidebarMenuRow()
                    .tag(SidebarItem.home)
                // 已选中时再点，也要从主题范围回到全库今日队列。
                Button { store.openTodayReview() } label: {
                    Label("今日回顾", systemImage: "sun.max")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarMenuRow()
                .tag(SidebarItem.review)
                Label("全部摘录", systemImage: "text.quote")
                    .sidebarMenuRow()
                    .tag(SidebarItem.all)
                Label("收藏", systemImage: "star")
                    .sidebarMenuRow()
                    .tag(SidebarItem.favorites)
                Button { store.openCardsHome() } label: {
                    HStack {
                        Label("记忆卡", systemImage: "brain")
                        Spacer()
                        if store.cardCount > 0 {
                            SidebarCount(store.cardCount)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarMenuRow()
                .tag(SidebarItem.cards)
                Label("回顾统计", systemImage: "chart.bar.xaxis")
                    .sidebarMenuRow()
                    .tag(SidebarItem.stats)
                Label("未归类", systemImage: "tray")
                    .sidebarMenuRow()
                    .tag(SidebarItem.unsorted)
                HStack {
                    Label("网页存档", systemImage: "globe")
                    Spacer()
                    if store.articleCount > 0 {
                        SidebarCount(store.articleCount)
                    }
                }
                .sidebarMenuRow()
                .tag(SidebarItem.articles)
                Label("出处管理", systemImage: "books.vertical")
                    .sidebarMenuRow()
                    .tag(SidebarItem.sourceManager)
                HStack {
                    Label("最近删除", systemImage: "trash")
                    Spacer()
                    if store.trashCount > 0 {
                        SidebarCount(store.trashCount)
                    }
                }
                .sidebarMenuRow()
                .tag(SidebarItem.trash)
                Label("使用说明", systemImage: "questionmark.circle")
                    .sidebarMenuRow()
                    .tag(SidebarItem.help)
            }

            // 出处默认折叠（点“出处”标题旁的箭头展开；记住上次状态）
            Section(isExpanded: Bindable(store).sourcesExpanded) {
                ForEach(store.sources) { source in
                    if let id = source.id {
                        HStack {
                            Label(source.title, systemImage: icon(for: source.kind))
                                .lineLimit(1)
                            Spacer()
                            SidebarCount(store.highlightCounts[id] ?? 0)
                        }
                        .sidebarMenuRow()
                        .tag(SidebarItem.source(id))
                        .contextMenu {
                            Button("编辑出处…") { store.editingSource = source }
                            Button("在此出处下新建摘录") { store.newHighlight(in: id) }
                            Divider()
                            Button("导出为 Markdown…") { ExportService.export(source: source, store: store) }
                            Divider()
                            Button("删除出处（保留摘录）…", role: .destructive) { store.sourcePendingDeletion = source }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("出处")
                    Spacer()
                    Menu {
                        Picker("排序", selection: Bindable(store).sourceSort) {
                            ForEach(SourceSort.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .handCursor()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("出处排序：\(store.sourceSort.label)")
                }
            }


            // 1.3：专题笔记本
            Section {
                ForEach(store.notebooks) { n in
                    if let id = n.id {
                        HStack {
                            Label(n.title, systemImage: "text.book.closed").lineLimit(1)
                            Spacer()
                            SidebarCount(store.notebookQuoteCounts[id] ?? 0)
                        }
                        .sidebarMenuRow()
                        .tag(SidebarItem.notebook(id))
                        .contextMenu {
                            Button("删除笔记本…", role: .destructive) { store.notebookPendingDeletion = n }
                        }
                    }
                }
                if store.notebooks.isEmpty {
                    Button {
                        store.newNotebookRequest = NewNotebookRequest()
                    } label: {
                        Label("新建专题笔记本…", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .sidebarMenuRow()
                }
            } header: {
                HStack {
                    Text("专题笔记本")
                    Spacer()
                    Button {
                        store.newNotebookRequest = NewNotebookRequest()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .handCursor()
                    .help("新建专题笔记本")
                }
            }

            if !store.savedSearches.isEmpty {
                Section("已存搜索") {
                    ForEach(store.savedSearches) { s in
                        Label(s.name, systemImage: "bookmark")
                            .sidebarMenuRow()
                            .tag(SidebarItem.saved(s.id))
                            .contextMenu {
                                Button("删除已存搜索", role: .destructive) { store.deleteSavedSearch(s.id) }
                            }
                    }
                }
            }

            if !store.tags.isEmpty {
                // 标签默认折叠（记住上次状态）；1.1 起按“/”分层显示，右键可改名、合并、删除
                Section(isExpanded: Bindable(store).tagsExpanded) {
                    OutlineGroup(store.tagTree, children: \.childrenOrNil) { node in
                        TagSidebarRow(node: node)
                            .sidebarMenuRow()
                    }
                } header: {
                    HStack {
                        Text("标签")
                        Spacer()
                        Button {
                            store.showTagManager = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .handCursor()
                        .help("整理标签：改名、合并、删除、分层")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 1.1：侧边栏收紧——字号比正文小一号、行高更矮，计数用小号灰字
        .font(.system(size: 12.5))
        .environment(\.defaultMinListRowHeight, 22)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBrandView()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.newHighlight()
                } label: {
                    Label("新建摘录", systemImage: "plus")
                }
                .help("新建摘录（⌘N）")
            }
        }
    }

    private func icon(for kind: SourceKind) -> String {
        switch kind {
        case .book: return "book.closed"
        case .article: return "doc.text"
        case .web: return "globe"
        case .pdf: return "doc.richtext"
        case .ai: return "sparkles"
        case .other: return "square.stack"
        }
    }
}

private extension View {
    /// 仅在可点击的侧栏行内显示手形，空白区域也与菜单文字保持一致。
    func sidebarMenuRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .handCursor()
    }
}

/// 侧边栏行尾的计数：小号灰色等宽数字
struct SidebarCount: View {
    let value: Int
    init(_ value: Int) { self.value = value }
    var body: some View {
        Text("\(value)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// 0.8 新增的面板与提示（单独成一个修饰器，避免主视图的修饰链过长、编译器类型检查超时）
struct CardSheets: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content
            .sheet(item: $store.duplicateCardReview) { _ in CardDuplicateReviewView() }
            .sheet(item: $store.deckOptionsEditor) { _ in
                DeckOptionsView()
            }
            .sheet(item: $store.templateEditor) { _ in
                NoteTemplateEditorView()
            }
            .sheet(item: $store.apkgExport) { _ in
                ApkgExportView()
            }
            .sheet(item: $store.clozeDraft) { _ in
                ClozeEditorView()
            }
            .sheet(item: $store.shareImageHighlight) { _ in
                ShareImageView()
            }
            .alert("同步更新记忆卡？", isPresented: Binding(
                get: { store.cardSyncOffer != nil },
                set: { if !$0 { store.cardSyncOffer = nil } }
            )) {
                Button("同步") {
                    if let o = store.cardSyncOffer { store.syncCards(fromHighlight: o.highlightId) }
                    store.cardSyncOffer = nil
                }
                Button("总是同步") {
                    UserDefaults.standard.set("always", forKey: CardSettings.syncFromHighlightKey)
                    if let o = store.cardSyncOffer { store.syncCards(fromHighlight: o.highlightId) }
                    store.cardSyncOffer = nil
                }
                Button("不同步", role: .cancel) { store.cardSyncOffer = nil }
            } message: {
                Text("这条摘录已做成 \(store.cardSyncOffer?.cardCount ?? 1) 张记忆卡。同步后卡片的正反面换成摘录的新内容，复习进度不变。（可在“设置 → 记忆卡”改为总是同步或从不同步）")
            }
    }
}
