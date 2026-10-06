import SwiftUI
import KongGleanCore

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .sheet(item: $store.editorDraft) { _ in
            HighlightEditorView()
        }
        .sheet(item: $store.editingSource) { _ in
            SourceEditorView()
        }
        .overlay(alignment: .bottom) {
            if let progress = store.importProgress.flatMap({ store.pendingImport == nil ? $0 : nil })
                ?? store.articleProgress.flatMap({ store.addArticleDraft == nil ? $0 : nil }) {
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
        .sheet(item: $store.pendingImport) { _ in
            ImportPreviewView()
        }
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
        case .review, .none:
            DailyReviewView()
        case .all:
            HighlightListView(title: "全部摘录", filter: .init())
        case .favorites:
            HighlightListView(title: "收藏", filter: .init(favoritesOnly: true))
        case .mastery:
            HighlightListView(title: "记忆卡", filter: .init(masteryOnly: true))
        case .unsorted:
            HighlightListView(title: "未归类", filter: .init(unsortedOnly: true))
        case .trash:
            HighlightListView(title: "最近删除", filter: .init(deletedOnly: true))
        case .articles:
            ArticlesView()
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
        List(selection: $store.selection) {
            Section {
                Label("今日回顾", systemImage: "sun.max").tag(SidebarItem.review)
                Label("全部摘录", systemImage: "text.quote").tag(SidebarItem.all)
                Label("收藏", systemImage: "star").tag(SidebarItem.favorites)
                Label("记忆卡", systemImage: "brain").tag(SidebarItem.mastery)
                Label("未归类", systemImage: "tray").tag(SidebarItem.unsorted)
                HStack {
                    Label("网页存档", systemImage: "globe")
                    Spacer()
                    if store.articleCount > 0 {
                        Text("\(store.articleCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .tag(SidebarItem.articles)
                HStack {
                    Label("最近删除", systemImage: "trash")
                    Spacer()
                    if store.trashCount > 0 {
                        Text("\(store.trashCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .tag(SidebarItem.trash)
            }

            Section("出处") {
                ForEach(store.sources) { source in
                    if let id = source.id {
                        HStack {
                            Label(source.title, systemImage: icon(for: source.kind))
                                .lineLimit(1)
                            Spacer()
                            Text("\(store.highlightCounts[id] ?? 0)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
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
            }

            if !store.tags.isEmpty {
                Section("标签") {
                    ForEach(store.tags, id: \.self) { tag in
                        Label(tag, systemImage: "number").tag(SidebarItem.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        case .other: return "square.stack"
        }
    }
}
