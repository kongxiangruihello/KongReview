import SwiftUI
import KongReviewCore

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        @Bindable var updater = AppUpdater.shared
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 168, ideal: 196, max: 280)
        } detail: {
            VStack(spacing:0) {
                CardAppendUndoBanner()
                CardEntryOrganizationUndoBanner()
                detail
            }
        }
        .disabled(store.fullBackupBusy)
        .overlay {
            if store.fullBackupBusy {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView(store.maintenanceProgress ?? "正在处理完整备份…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.showGlobalSearch() } label: { Label("全局搜索", systemImage: "magnifyingglass") }
                    .disabled(!store.canShowGlobalSearch)
                    .handCursor()
                    .help("查找摘录、记忆卡、出处和札记（⌘⇧F）")
            }
        }
        // 5.2.1：在线更新
        .sheet(isPresented: $updater.showsPanel) { UpdatePanel() }
        .sheet(item: $store.ideaNoteComposer) { composer in IdeaNoteComposerSheet(composer: composer).environment(store) }
        .sheet(item: $store.questionCreator) { request in QuestionCreateSheet(request: request).environment(store) }
        .sheet(item: $store.questionAttach) { request in QuestionAttachSheet(request: request) { store.questionAttach = nil }.environment(store) }
        .modifier(GlobalSearchPresentation())
        .modifier(LearningExplorerPresentation())
        .modifier(LearningMaterialExportPresentation())
        .modifier(FullBackupPresentation())
        .sheet(item: $store.editorDraft) { _ in
            HighlightEditorView().modifier(EditorDraftCloseConfirmation(kind: .highlight))
        }
        // 6.4.1：标注面板挂在最外层——今日日课、摘录列表与回顾的右键菜单都能打开
        .sheet(item: $store.annotating) { AnnotateSheet(request: $0).environment(store) }
        .onChange(of: store.editorDraft == nil) { _, closed in
            if closed { store.resumeAnnotationAfterEdit() }
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
        .sheet(item: $store.cardEditor,onDismiss:{ store.resumeBulkAfterOriginalEditorDismissed() }) { _ in
            CardEditorView().modifier(EditorDraftCloseConfirmation(kind: .card))
        }
        .sheet(item: $store.articleSourceDraft) { _ in
            ArticleSourceEditorView()
        }
        .modifier(CardSheets())
        .modifier(EditorDraftRecoverySheets())
        .modifier(CardEntryPresetPresentation(insideEditor:false))
        .modifier(DeckEntryPresetPresentation(host:.main))
        .modifier(CardEntryBatchPresentation(insideEditor:false))
        .modifier(CardEntryHistoryPresentation(insideEditor:false))
        .modifier(CardBulkEntryPresentation(insideEditor:false))
        .modifier(TagSheets())
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
        // 6.0.1：网页存档与研究项目已舍弃，旧位置回到首页
        case .home, .none, .articles, .project, .projects:
            HomeView()
        case .review:
            DailyReviewView()
        case .all:
            HighlightListView(title: "全部摘录", filter: .init())
        case .favorites:
            HighlightListView(title: "收藏", filter: .init(favoritesOnly: true))
        case .cards:
            CardsHomeView()
        // 6.0.5：个人成长、回顾统计、复盘并入成绩册
        case .growth, .stats, .reflection, .gradebook:
            GradebookView()
        case .unsorted:
            HighlightListView(title: "未归类", filter: .init(unsortedOnly: true))
        case .trash:
            HighlightListView(title: "最近删除", filter: .init(deletedOnly: true))
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
        case .ideaNotes:
            IdeaNoteListView()
        case .ideaNote(let id):
            IdeaNoteView(noteId: id).id(id)
        case .questionBook:
            QuestionBookView()
        case .question(let id):
            QuestionView(questionId: id).id(id)
        // 6.0.3 起重温、自测、今日检查都在今日试卷里
        case .revisit, .selfTest, .dailyCheck:
            ExamView()
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
                else if destination == .dailyCheck { store.openExam() }
                else if destination == .gradebook { store.openGradebook() }
                else { store.selection = destination }
            }
        )) {
            // 6.0.1：侧栏改为三组——考场（每天来考）、题库（考的内容）、其他。各组可折叠，记住状态。
            Section(isExpanded: store.sidebarGroupBinding("exam")) {
                Label("日课首页", systemImage: "door.left.hand.open")
                    .sidebarMenuRow()
                    .tag(SidebarItem.home)
                // 6.0.3：今日试卷——今日检查、今日回顾、记忆卡学习、重温、自测合成一张卷子；行尾为还没答的题数
                HStack {
                    Label("今日日课", systemImage: "list.clipboard")
                    Spacer()
                    if store.dailyCheck.left > 0 { SidebarCount(store.dailyCheck.left) }
                }
                .sidebarMenuRow()
                .tag(SidebarItem.dailyCheck)
                // 6.0.5：成绩册——日评、打卡、走势、常错的题、周报月报（复盘、个人成长、回顾统计并入）
                Label("成绩册", systemImage: "chart.line.uptrend.xyaxis")
                    .sidebarMenuRow()
                    .tag(SidebarItem.gradebook)
            } header: {
                Text("日课")
            }

            Section(isExpanded: store.sidebarGroupBinding("bank")) {
                // 6.0.3：记忆卡的牌组、浏览、录入放在题库；学习在今日试卷里
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
                Label("全部摘录", systemImage: "text.quote")
                    .sidebarMenuRow()
                    .tag(SidebarItem.all)
                Label("收藏", systemImage: "star")
                    .sidebarMenuRow()
                    .tag(SidebarItem.favorites)
                Label("未归类", systemImage: "tray")
                    .sidebarMenuRow()
                    .tag(SidebarItem.unsorted)
                ForEach(store.savedSearches) { s in
                    Label(s.name, systemImage: "bookmark")
                        .sidebarMenuRow()
                        .tag(SidebarItem.saved(s.id))
                        .contextMenu {
                            Button("删除已存搜索", role: .destructive) { store.deleteSavedSearch(s.id) }
                        }
                }
                if !store.tags.isEmpty {
                    // 标签默认折叠（记住上次状态）；1.1 起按“/”分层显示，右键可改名、合并、删除
                    DisclosureGroup(isExpanded: Bindable(store).tagsExpanded) {
                        OutlineGroup(store.tagTree, children: \.childrenOrNil) { node in
                            TagSidebarRow(node: node)
                                .sidebarMenuRow()
                        }
                    } label: {
                        HStack {
                            Label("标签", systemImage: "tag")
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
                HStack {
                    Label("札记", systemImage: "lightbulb")
                    Spacer()
                    if store.ideaNoteCount > 0 { SidebarCount(store.ideaNoteCount) }
                }
                .sidebarMenuRow()
                .tag(SidebarItem.ideaNotes)
                .contextMenu { Button("新写札记…") { store.composeIdeaNote() } }
                // 6.4.0：问题簿、专题笔记本已并入札记，侧栏不再单列
            } header: {
                HStack {
                    Text("题库")
                    Spacer()
                    Menu { AddEverythingMenu() } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .handCursor()
                        .help("新建摘录、添加网页、记忆卡、札记、出处，或导入")
                }
            }

            Section(isExpanded: store.sidebarGroupBinding("other")) {
                Label("出处管理", systemImage: "books.vertical")
                    .sidebarMenuRow()
                    .tag(SidebarItem.sourceManager)
                // 出处列表默认折叠（记住上次状态）
                DisclosureGroup(isExpanded: Bindable(store).sourcesExpanded) {
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
                } label: {
                    HStack {
                        Label("出处", systemImage: "book")
                        Spacer()
                        SidebarCount(store.sources.count)
                    }
                }
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
            } header: {
                HStack {
                    Text("其他")
                    Spacer()
                    Menu {
                        Picker("出处排序", selection: Bindable(store).sourceSort) {
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
        }
        .listStyle(.sidebar)
        // 1.1：侧边栏收紧——字号比正文小一号、行高更矮，计数用小号灰字
        .font(.system(size: 12.5))
        .environment(\.defaultMinListRowHeight, 22)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBrandView()
        }
        .toolbar {
            // 6.3：加号列出所有可以新建、导入的
            ToolbarItem {
                Menu { AddEverythingMenu() } label: { Label("新建", systemImage: "plus") }
                    .menuIndicator(.hidden)
                    .help("新建摘录（⌘N）、添加网页（⌘L）、记忆卡、札记、出处，或导入")
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
            .sheet(item: $store.dailyLimitsEditor) { _ in
                DailyLimitsView()
            }
            .sheet(item: $store.templateEditor) { _ in
                NoteTemplateEditorView()
            }
            .sheet(isPresented: $store.showsPlainCardStyle) {
                PlainCardStyleEditorView()
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

/// 6.3：侧栏加号的菜单——所有可以新建、导入的都在这里
struct AddEverythingMenu: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Group {
            Section("新建") {
                Button { store.newHighlight() } label: { Label("新建摘录（⌘N）", systemImage: "text.quote") }
                Button { QuickCaptureController.shared.show() } label: { Label("快速录入浮窗（⌥⌘N）", systemImage: "rectangle.and.pencil.and.ellipsis") }
                // 6.3.3：添加网页（6.0.1 前的“存档网页”）——整篇正文存为一条摘录
                Button { store.showAddWebPage() } label: { Label("添加网页…（⌘L）", systemImage: "globe") }
                Button { store.newCard(deck: store.study.lastDeck) } label: { Label("新建记忆卡", systemImage: "rectangle.on.rectangle") }
                Button { store.showsCardBulkEntry = true } label: { Label("批量粘贴问答（记忆卡）…", systemImage: "list.bullet.rectangle") }
                Button { store.composeIdeaNote() } label: { Label("新写札记…", systemImage: "lightbulb") }
                Button { QuickNoteController.shared.show() } label: { Label("随手札记浮窗（⌥⌘J）", systemImage: "square.and.pencil") }
                Button { store.editingSource = Source(title: "") } label: { Label("新建出处…", systemImage: "books.vertical") }
            }
            Section("导入") {
                Button("从 KongFolio 导入") { store.checkKongFolio(quiet: false, force: true) }
                Button("从 KongFolio 文件导入…") { store.chooseKongFolioFile() }
                Button("从 LiquidText 导入笔记…") { ExportService.importLiquidText(store: store) }
                Button("从剪贴板导入 LiquidText 笔记") { ExportService.importLiquidTextFromClipboard(store: store) }
                Button("导入 Anki 牌组…") { ExportService.importAnki(store: store) }
            }
        }
        .disabled(store.fullBackupBusy)
    }
}
