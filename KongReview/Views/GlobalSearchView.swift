import SwiftUI

struct GlobalSearchPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var state = store.globalSearch
        return content.sheet(isPresented: $state.isPresented, onDismiss: {
            if let target = state.takePendingTarget() { store.openGlobalSearchResult(target) }
        }) {
            GlobalSearchView()
        }
    }
}

struct GlobalSearchView: View {
    @Environment(LibraryStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var state = store.globalSearch
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("全局搜索").font(.title2.bold()).foregroundStyle(ReviewPalette.ink)
                    Spacer()
                    Button("关闭") { state.close() }
                        .keyboardShortcut(.cancelAction)
                        .handCursor()
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ReviewPalette.sub)
                    TextField("搜索摘录、记忆卡、网页正文或出处", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($searchFocused)
                        .onSubmit {
                            if !state.isLoading, let first = state.sections.flatMap(\.items).first {
                                state.choose(first.target)
                            }
                        }
                    if !state.query.isEmpty {
                        Button { state.query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(ReviewPalette.sub)
                        }
                        .buttonStyle(.plain).handCursor().help("清空搜索")
                    }
                }
                .padding(12)
                .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReviewPalette.hair))
                Picker("搜索范围", selection: $state.selectedKind) {
                    Text("全部").tag(Optional<GlobalSearchKind>.none)
                    ForEach(GlobalSearchKind.allCases) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(20)

            Divider()
            results
            Divider()
            HStack {
                Text(state.normalizedQuery.isEmpty ? "输入关键词开始查找" : "共找到 \(state.total) 项")
                Spacer()
                Text("点击打开完整内容 · 回车打开首项")
            }
            .font(.caption).foregroundStyle(ReviewPalette.sub)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(ReviewPalette.page)
        .frame(minWidth: 620, idealWidth: 760, maxWidth: 900, minHeight: 540, idealHeight: 680, maxHeight: 820)
        .onAppear { searchFocused = true }
        .task(id: state.requestID) { await state.search(db: store.db) }
        .onChange(of: store.revision) { _, _ in state.invalidate() }
        .onDisappear { state.cancelLoads() }
    }

    @ViewBuilder private var results: some View {
        let state = store.globalSearch
        if state.normalizedQuery.isEmpty {
            ContentUnavailableView {
                Label("从全部资料中查找", systemImage: "magnifyingglass")
            } description: {
                Text("可搜索摘录原文、译文、按语，记忆卡正反面与标签，网页正文和出处信息。")
            }
        } else if state.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在搜索…").foregroundStyle(ReviewPalette.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.total == 0, state.error == nil {
            ContentUnavailableView {
                Label("没有找到匹配内容", systemImage: "magnifyingglass")
            } description: {
                Text("试试较短的关键词，或切换搜索范围。")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let error = state.error {
                        HStack {
                            Text(error).font(.callout).foregroundStyle(ReviewPalette.again)
                            Spacer()
                            Button("重试") { state.invalidate() }.handCursor()
                        }
                    }
                    ForEach(state.sections.filter { $0.total > 0 }, id: \.kind) { page in
                        resultSection(page)
                    }
                }
                .padding(20)
            }
        }
    }

    private func resultSection(_ page: GlobalSearchPage) -> some View {
        let state = store.globalSearch
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(page.kind.title, systemImage: page.kind.symbol).font(.headline)
                Text("\(page.total)").font(.caption.monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                Spacer()
            }
            .foregroundStyle(ReviewPalette.ink)
            VStack(spacing: 0) {
                ForEach(page.items) { hit in
                    Button { state.choose(hit.target) } label: {
                        resultRow(hit)
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help(openHint(hit.target.kind))
                    if hit.id != page.items.last?.id { Divider().padding(.horizontal, 14) }
                }
            }
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ReviewPalette.hair))
            if page.hasMore {
                HStack {
                    Text("已显示 \(page.items.count) / \(page.total) 项")
                        .font(.caption).foregroundStyle(ReviewPalette.sub)
                    Spacer()
                    if state.loadingKinds.contains(page.kind) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("加载更多\(page.kind.title)") { state.loadMore(page.kind, db: store.db) }
                            .handCursor()
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func resultRow(_ hit: GlobalSearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(hit.title.isEmpty ? hit.target.kind.title : hit.title)
                        .font(.body.weight(.medium)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                    if let badge = hit.badge {
                        Text(badge).font(.caption2).foregroundStyle(ReviewPalette.sub)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(ReviewPalette.soft, in: Capsule())
                    }
                }
                if !hit.preview.isEmpty {
                    Text(hit.preview).font(.callout).foregroundStyle(ReviewPalette.ink.opacity(0.85)).lineLimit(3)
                }
                if !hit.context.isEmpty {
                    Text(hit.context).font(.caption).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(ReviewPalette.sub)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func openHint(_ kind: GlobalSearchKind) -> String {
        switch kind {
        case .highlight: return "打开完整摘录，可查看与编辑"
        case .card: return "打开记忆卡，可查看与编辑"
        case .article: return "阅读已存档的完整网页"
        case .source: return "打开出处及其摘录"
        }
    }
}
