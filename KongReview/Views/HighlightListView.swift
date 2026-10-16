import SwiftUI
import AppKit
import KongReviewCore

struct HighlightFilter: Hashable {
    var sourceId: Int64?
    var tag: String?
    var favoritesOnly = false
    var masteryOnly = false
    var unsortedOnly = false
    var deletedOnly = false

    /// 这些全库列表每次只载入一页；出处、标签等列表保留原来的逐步加载。
    var usesPagination: Bool {
        unsortedOnly || favoritesOnly || deletedOnly
            || (sourceId == nil && tag == nil && !masteryOnly)
    }
}

struct HighlightListView: View {
    @Environment(LibraryStore.self) private var store
    let title: String
    let filter: HighlightFilter
    /// 从“已存搜索”打开时带入的搜索词与筛选
    var saved: SavedSearch? = nil

    private var state: ListState { store.list }

    private var query: HighlightQuery {
        let x = state.extra
        return HighlightQuery(
            text: state.query, sourceId: filter.sourceId ?? x.sourceId, tag: filter.tag,
            favoritesOnly: filter.favoritesOnly || x.favoritesOnly, masteryOnly: filter.masteryOnly,
            unsortedOnly: filter.unsortedOnly, deletedOnly: filter.deletedOnly,
            tags: x.tags, dateFrom: x.from, dateTo: x.to,
            orderByPage: filter.sourceId != nil && !filter.deletedOnly && state.sourceByPage
        )
    }

    private var terms: [String] { SearchTerms.terms(state.query) }

    /// 分页列表始终只渲染一页，长库也能直接跳到最后一页。
    private var usesPages: Bool { filter.usesPagination }

    private struct LoadKey: Hashable {
        var title: String
        var query: HighlightQuery
        var revision: Int
        var limit: Int
        var page: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1.6：出处书页——书目信息、统计、排序、导出读书笔记
            if let sid = filter.sourceId, !filter.deletedOnly {
                SourcePageHeader(sourceId: sid)
                Divider()
            }
            if !filter.deletedOnly && (state.showFilters || !state.extra.isEmpty) {
                ListFilterBar(base: filter)
                Divider()
            }
            listContent
        }
        .task(id: title) {
            // 换了列表：已存搜索带入它的条件，其他列表清空上一个列表的组合筛选
            if state.extraOwner != title {
                state.page = 1
                state.pageInput = "1"
                state.selection = []
            }
            if let saved {
                state.query = saved.text
                state.extra = saved.filter
                state.showFilters = true
            } else if state.extraOwner != title {
                state.extra = ListFilter()
            }
            state.extraOwner = title
        }
        .alert("保存当前搜索", isPresented: Binding(
            get: { store.savingSearchName != nil },
            set: { if !$0 { store.savingSearchName = nil } }
        )) {
            TextField("名称，如：严复 · 进化", text: Binding(get: { store.savingSearchName ?? "" }, set: { store.savingSearchName = $0 }))
            Button("取消", role: .cancel) { store.savingSearchName = nil }
            Button("保存") { store.saveCurrentSearch(named: store.savingSearchName ?? "") }
        } message: {
            Text("搜索词与筛选条件会保存到侧边栏“已存搜索”，点一下就能再次打开。")
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            if state.items.isEmpty {
                if state.isLoading {
                    ProgressView("正在载入摘录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(state.query.isEmpty ? "还没有摘录" : "没有找到", systemImage: "text.quote")
                    } description: {
                        Text(filter.deletedOnly
                             ? "删除的摘录会在这里保留 30 天，可随时恢复。"
                             : (state.query.isEmpty ? "按 ⌘N 新建一条摘录，或在任意应用中按 \(HotKeyPreset.current.label) 快速录入。" : "换个关键词试试。两个字以内的查询使用模糊匹配。"))
                    }
                }
            } else {
                List(selection: Bindable(store.list).selection) {
                    ForEach(state.items, id: \.id) { h in
                        HighlightRow(highlight: h, source: store.source(for: h), terms: terms)
                            .tag(h.id ?? -1)
                            .onAppear {
                                if !usesPages, h.id == state.items.last?.id, state.hasMore { state.limit += ListState.pageSize }
                            }
                    }
                    if !usesPages && state.hasMore {
                        HStack {
                            Spacer()
                            Button("加载更多（已显示 \(state.items.count) / \(state.total)）") {
                                state.limit += ListState.pageSize
                            }
                            .buttonStyle(.link)
                            .handCursor()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Int64.self) { ids in
                    contextItems(Array(ids))
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let h = state.items.first(where: { $0.id == id }) {
                        store.edit(h)
                    }
                }
            }
            if usesPages {
                Divider()
                pageControls
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(state.selection.isEmpty ? "共 \(state.total) 条" : "共 \(state.total) 条 · 已选 \(state.selection.count) 条")
        .searchable(text: Bindable(store.list).query, prompt: "搜索原文、译文、按语")
        .task(id: LoadKey(title: title, query: query, revision: store.revision, limit: state.limit, page: state.page)) {
            await load()
        }
        .confirmationDialog(
            "彻底删除“最近删除”里的全部 \(store.trashCount) 条摘录？",
            isPresented: Binding(
                get: { store.confirmingEmptyTrash },
                set: { store.confirmingEmptyTrash = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) { store.emptyTrash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空全部最近删除，包括其他页和搜索未显示的摘录。此操作无法撤销（每日自动备份中仍保留删除前的数据）。")
        }
        .toolbar {
            if !filter.deletedOnly {
                ToolbarItem {
                    Button {
                        state.showFilters.toggle()
                    } label: {
                        Label("筛选", systemImage: state.extra.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help("按出处、多个标签、日期组合筛选")
                }
                ToolbarItem {
                    Menu {
                        Button("专题汇编（Word / Markdown）…") { startExport(.compilation) }
                        Button("导出到 Anki…") { startExport(.anki) }
                        Divider()
                        Button("参考文献表（GB/T 7714）…") { showBibliography() }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .help(state.selection.isEmpty ? "导出当前列表中的全部摘录" : "导出所选摘录")
                    .disabled(state.total == 0)
                }
            }
            if !state.selection.isEmpty {
                ToolbarItem {
                    Menu {
                        contextItems(Array(state.selection), batchOnly: true)
                    } label: {
                        Label("批量操作", systemImage: "checklist")
                    }
                    .help("对已选的 \(state.selection.count) 条摘录批量操作")
                }
            }
            ToolbarItem {
                if filter.deletedOnly {
                    Button(role: .destructive) {
                        store.confirmingEmptyTrash = true
                    } label: {
                        Label("清空", systemImage: "trash.slash")
                    }
                    .help("彻底删除最近删除中的全部摘录，包括其他页和搜索未显示的内容（无法恢复）")
                    .disabled(store.trashCount == 0)
                } else {
                    Button {
                        store.newHighlight(in: filter.sourceId)
                    } label: {
                        Label("新建摘录", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextItems(_ ids: [Int64], batchOnly: Bool = false) -> some View {
        if !batchOnly, ids.count == 1, let h = state.items.first(where: { $0.id == ids[0] }) {
            HighlightMenu(highlight: h)
        } else if !ids.isEmpty {
            BatchMenu(ids: ids, inTrash: filter.deletedOnly)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            if state.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(pageRangeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { goToPage(state.page - 1) } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(state.page <= 1 || state.isLoading)
            Text("第 \(state.page) / \(state.pageCount) 页")
                .monospacedDigit()
            Button { goToPage(state.page + 1) } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(state.page >= state.pageCount || state.isLoading)
            TextField("页码", text: Bindable(store.list).pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.center)
                .onSubmit(jumpToPage)
                .accessibilityLabel("跳转到页码")
            Button("跳转", action: jumpToPage)
                .disabled(state.isLoading)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pageRangeLabel: String {
        guard state.total > 0 else { return "共 0 条 · 每页 \(ListState.pageSize) 条" }
        let first = (state.page - 1) * ListState.pageSize + 1
        let last = min(state.page * ListState.pageSize, state.total)
        return "第 \(first)–\(last) 条，共 \(state.total) 条"
    }

    private func goToPage(_ page: Int) {
        let target = min(max(1, page), state.pageCount)
        state.pageInput = String(target)
        guard target != state.page else { return }
        // 切页立即作废旧请求，避免新任务启动前旧页结果回填。
        state.loadID = UUID()
        state.items = []
        state.isLoading = true
        state.selection = []
        state.page = target
    }

    private func jumpToPage() {
        goToPage(Int(state.pageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? state.page)
    }

    @MainActor
    private func load() async {
        let requestedQuery = query
        let requestedRevision = store.revision
        let requestID = UUID()
        state.loadID = requestID
        do {
            if state.lastQuery != requestedQuery {
                // 换了筛选条件：回到第一页，清空选择
                state.lastQuery = requestedQuery
                state.selection = []
                state.items = []
                if usesPages {
                    state.pageInput = "1"
                    if state.page != 1 {
                        state.page = 1
                        return
                    }
                } else if state.limit != ListState.pageSize {
                    state.limit = ListState.pageSize
                    return   // limit 变化会再次触发 load
                }
            }
            let requestedPage = state.page
            let requestedLimit = usesPages ? ListState.pageSize : state.limit
            state.isLoading = true
            defer { if state.loadID == requestID { state.isLoading = false } }
            let result = try await store.db.highlightPage(requestedQuery, limit: requestedLimit,
                                                         offset: usesPages ? (requestedPage - 1) * ListState.pageSize : 0)
            guard !Task.isCancelled, state.loadID == requestID,
                  state.page == requestedPage, query == requestedQuery,
                  store.revision == requestedRevision else { return }
            state.total = result.total
            if usesPages && requestedPage > state.pageCount {
                state.selection = []
                state.items = []
                state.page = state.pageCount
                state.pageInput = String(state.page)
                return
            }
            // 1.7：待选中的摘录可能超出当前分页：先放宽分页（limit 变化会再次触发 load）
            if !usesPages, state.pendingSelection != nil, state.limit < state.total {
                state.limit = state.total
                return
            }
            state.items = result.items
            if usesPages { state.pageInput = String(requestedPage) }
            if let pending = state.pendingSelection {
                state.selection = pending
                state.pendingSelection = nil
            }
            state.selection = state.selection.filter { id in state.items.contains { $0.id == id } }
        } catch {
            if !Task.isCancelled, state.loadID == requestID { store.report(error) }
        }
    }

    /// 1.2：当前列表（或已选摘录）涉及的出处 → 参考文献表
    private func showBibliography() {
        let ids = Array(state.selection)
        if ids.isEmpty {
            store.showBibliography(for: (try? store.db.highlights(query)) ?? [], title: title)
        } else {
            let order = state.items.compactMap(\.id).filter { state.selection.contains($0) }
            store.showBibliography(for: (try? store.db.highlights(ids: order)) ?? [], title: title)
        }
    }

    private func startExport(_ kind: ExportRequest.Kind) {
        let ids = Array(state.selection)
        let hs: [Highlight]
        let scope: String
        if ids.isEmpty {
            hs = (try? store.db.highlights(query)) ?? []
            scope = "\(title) · 全部 \(hs.count) 条"
        } else {
            // 按列表中的顺序
            let order = state.items.compactMap(\.id).filter { state.selection.contains($0) }
            hs = (try? store.db.highlights(ids: order)) ?? []
            scope = "\(title) · 已选 \(hs.count) 条"
        }
        store.exportRequest = ExportRequest(kind: kind, scopeLabel: scope, highlights: hs, title: title)
    }
}

/// 多选时的批量菜单
struct BatchMenu: View {
    @Environment(LibraryStore.self) private var store
    let ids: [Int64]
    let inTrash: Bool

    var body: some View {
        if inTrash {
            Button("恢复 \(ids.count) 条") {
                store.perform { try store.db.modifyHighlights(ids: ids) { $0.deletedAt = nil } }
            }
        } else {
            Text("已选 \(ids.count) 条")
            Divider()
            Button("加标签…") { store.batchPrompt = BatchPrompt(kind: .addTags, ids: ids) }
            Button("去掉标签…") { store.batchPrompt = BatchPrompt(kind: .removeTags, ids: ids) }
            Button("移到出处…") { store.batchPrompt = BatchPrompt(kind: .move, ids: ids) }
            Divider()
            Button("收藏") { store.batch(.favorite(true), ids: ids) }
            Button("取消收藏") { store.batch(.favorite(false), ids: ids) }
            Button("做成记忆卡") { store.batch(.addToMastery, ids: ids) }
            AddToNotebookMenu(ids: ids)
            Button("弃置（不再出现在回顾中）") { store.batch(.discard(true), ids: ids) }
            Button("取消弃置") { store.batch(.discard(false), ids: ids) }
            Divider()
            Button("删除 \(ids.count) 条（移入最近删除）", role: .destructive) { store.batch(.delete, ids: ids) }
        }
    }
}

struct HighlightRow: View {
    @Environment(LibraryStore.self) private var store
    let highlight: Highlight
    let source: Source?
    var terms: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(RichText.marked(preview(highlight.text, limit: 1600), terms: terms))
                .font(.system(.body, design: .serif))
                .lineLimit(6)
                .textSelection(.enabled)
            if let t = highlight.translation {
                Text(RichText.marked("译：" + preview(t, limit: 600), terms: terms)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if let n = highlight.note {
                Text(RichText.marked("按：" + preview(n, limit: 600), terms: terms)).font(.callout).foregroundStyle(.blue).lineLimit(3)
            }
            HStack(spacing: 8) {
                let cite = CitationFormatter.citation(for: highlight, source: source, style: CitationSettings.style)
                if !cite.isEmpty {
                    Text(cite).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(highlight.tags, id: \.self) { tag in
                    Text("#\(tag)").font(.caption).foregroundStyle(.tint)
                }
                Spacer()
                if highlight.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if let id = highlight.id, store.cardHighlightIDs.contains(id) {
                    Image(systemName: "brain").foregroundStyle(.purple).help("已做成记忆卡")
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// lineLimit 只限制绘制，不限制 Markdown 解析；列表只解析预览，编辑时仍使用完整原文。
    private func preview(_ text: String, limit: Int) -> String {
        let prefix = text.prefix(limit)
        return prefix.endIndex == text.endIndex ? text : String(prefix) + "…"
    }
}

/// 摘录的右键菜单（列表与回顾共用）
struct HighlightMenu: View {
    @Environment(LibraryStore.self) private var store
    let highlight: Highlight

    var body: some View {
        if highlight.isDeleted {
            Button("恢复") { store.restore(highlight) }
            Divider()
            Button("彻底删除", role: .destructive) { store.deletePermanently(highlight) }
        } else {
            normalItems
        }
    }

    @ViewBuilder
    private var normalItems: some View {
        Button("编辑…") { store.edit(highlight) }
        Button("复制（含出处）") { copy(withCitation: true) }
        Button("复制为 Markdown") { copyMarkdown() }
        Divider()
        Button(highlight.isFavorite ? "取消收藏" : "收藏") {
            var h = highlight
            h.isFavorite.toggle()
            store.save(h)
        }
        Button("做成填空卡…") { store.startCloze(for: highlight) }
        if let id = highlight.id { AddToNotebookMenu(ids: [id]) }
        Menu("回顾频率") {
            Button((highlight.frequency ?? 0) > 0 ? "✓ 多出现" : "多出现") { store.setFrequency(1, for: highlight) }
            Button((highlight.frequency ?? 0) == 0 ? "✓ 正常" : "正常") { store.setFrequency(nil, for: highlight) }
            Button((highlight.frequency ?? 0) < 0 ? "✓ 少出现" : "少出现") { store.setFrequency(-1, for: highlight) }
        }
        Button("生成分享图…") { store.shareImageHighlight = highlight }
        if let u = store.source(for: highlight)?.url, let url = URL(string: u), url.isFileURL || u.hasPrefix("http") {
            Button(url.isFileURL ? "打开原文件" : "打开原网页") { NSWorkspace.shared.open(url) }
        }
        if let id = highlight.id, store.cardHighlightIDs.contains(id) {
            Button("查看记忆卡") {
                store.selection = .cards
                if let c = try? store.db.cards().first(where: { $0.highlightId == id }) { store.editCard(c) }
            }
        } else {
            Button("做成记忆卡") { store.makeCard(from: highlight) }
        }
        if highlight.isDiscarded {
            Button("恢复（取消弃置）") {
                var h = highlight
                h.isDiscarded = false
                store.save(h)
            }
        }
        Divider()
        Button("删除（移入最近删除）", role: .destructive) { store.delete(highlight) }
    }

    private func copy(withCitation: Bool) {
        var s = highlight.text
        if withCitation {
            let cite = CitationFormatter.citation(for: highlight, source: store.source(for: highlight), style: CitationSettings.style)
            if !cite.isEmpty { s += "\n——\(cite)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyMarkdown() {
        let md = MarkdownExporter.block(for: highlight, source: store.source(for: highlight), style: CitationSettings.style)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

/// 列表上方的组合筛选条：出处 · 标签（可多选，须同时具备） · 日期 · 只看收藏 · 保存为搜索
struct ListFilterBar: View {
    @Environment(LibraryStore.self) private var store
    let base: HighlightFilter
    private var state: ListState { store.list }

    private var datePreset: String {
        guard let from = state.extra.from else { return "不限日期" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: from),
                                                    to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if state.extra.to == nil {
            switch days {
            case 6: return "近 7 天"
            case 29: return "近 30 天"
            case 364: return "近一年"
            default: break
            }
        }
        return "自定义"
    }

    private func preset(_ days: Int?) {
        if let days {
            state.extra.from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date())
            state.extra.to = nil
        } else {
            state.extra.from = nil
            state.extra.to = nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if base.sourceId == nil {
                Picker("出处", selection: Bindable(store.list).extra.sourceId) {
                    Text("全部出处").tag(Int64?.none)
                    ForEach(store.sources) { s in Text(s.title).tag(s.id) }
                }
                .frame(maxWidth: 220)
            }
            Menu {
                if store.tags.isEmpty { Text("还没有标签") }
                ForEach(store.tags, id: \.self) { t in
                    Button(state.extra.tags.contains(t) ? "✓ #\(t)" : "#\(t)") {
                        if let i = state.extra.tags.firstIndex(of: t) { state.extra.tags.remove(at: i) } else { state.extra.tags.append(t) }
                    }
                }
            } label: {
                Text(state.extra.tags.isEmpty ? "标签" : "标签：" + state.extra.tags.map { "#\($0)" }.joined(separator: " "))
                    .lineLimit(1)
            }
            .fixedSize()
            .help("可选多个标签：只显示同时带有这些标签的摘录")
            Menu(datePreset) {
                Button("不限日期") { preset(nil) }
                Button("近 7 天") { preset(7) }
                Button("近 30 天") { preset(30) }
                Button("近一年") { preset(365) }
                Button("自定义…") {
                    if state.extra.from == nil { preset(30) }
                    state.extra.to = Date()
                }
            }
            .fixedSize()
            if state.extra.from != nil && datePreset == "自定义" {
                DatePicker("", selection: Binding(get: { state.extra.from ?? Date() }, set: { state.extra.from = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().fixedSize()
                Text("至").foregroundStyle(.secondary)
                DatePicker("", selection: Binding(get: { state.extra.to ?? Date() }, set: { state.extra.to = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().fixedSize()
            }
            if !base.favoritesOnly {
                Toggle("只看收藏", isOn: Bindable(store.list).extra.favoritesOnly)
                    .toggleStyle(.checkbox)
            }
            Spacer()
            if !state.extra.isEmpty {
                Button("清除筛选") { state.extra = ListFilter() }
                    .buttonStyle(.link)
                    .handCursor()
            }
            Button {
                store.savingSearchName = state.query.isEmpty ? "" : state.query
            } label: {
                Label("保存为搜索", systemImage: "bookmark")
            }
            .disabled(state.extra.isEmpty && state.query.isEmpty)
            .help("把当前的搜索词和筛选条件存到侧边栏")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
