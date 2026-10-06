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
}

struct HighlightListView: View {
    @Environment(LibraryStore.self) private var store
    let title: String
    let filter: HighlightFilter

    private var state: ListState { store.list }

    private var query: HighlightQuery {
        HighlightQuery(
            text: state.query, sourceId: filter.sourceId, tag: filter.tag,
            favoritesOnly: filter.favoritesOnly, masteryOnly: filter.masteryOnly,
            unsortedOnly: filter.unsortedOnly, deletedOnly: filter.deletedOnly
        )
    }

    private struct LoadKey: Hashable {
        var query: HighlightQuery
        var revision: Int
        var limit: Int
    }

    var body: some View {
        Group {
            if state.items.isEmpty {
                ContentUnavailableView {
                    Label(state.query.isEmpty ? "还没有摘录" : "没有找到", systemImage: "text.quote")
                } description: {
                    Text(filter.deletedOnly
                         ? "删除的摘录会在这里保留 30 天，可随时恢复。"
                         : (state.query.isEmpty ? "按 ⌘N 新建一条摘录，或在任意应用中按 \(HotKeyPreset.current.label) 快速录入。" : "换个关键词试试。两个字以内的查询使用模糊匹配。"))
                }
            } else {
                List(selection: Bindable(store.list).selection) {
                    ForEach(state.items, id: \.id) { h in
                        HighlightRow(highlight: h, source: store.source(for: h))
                            .tag(h.id ?? -1)
                            .onAppear {
                                if h.id == state.items.last?.id, state.hasMore { state.limit += ListState.pageSize }
                            }
                    }
                    if state.hasMore {
                        HStack {
                            Spacer()
                            Button("加载更多（已显示 \(state.items.count) / \(state.total)）") {
                                state.limit += ListState.pageSize
                            }
                            .buttonStyle(.link)
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
        }
        .navigationTitle(title)
        .navigationSubtitle(state.selection.isEmpty ? "共 \(state.total) 条" : "共 \(state.total) 条 · 已选 \(state.selection.count) 条")
        .searchable(text: Bindable(store.list).query, prompt: "搜索原文、译文、按语")
        .task(id: LoadKey(query: query, revision: store.revision, limit: state.limit)) {
            load()
        }
        .confirmationDialog(
            "彻底删除“最近删除”里的 \(state.total) 条摘录？",
            isPresented: Binding(
                get: { store.confirmingEmptyTrash },
                set: { store.confirmingEmptyTrash = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) { store.emptyTrash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销（每日自动备份中仍保留删除前的数据）。")
        }
        .toolbar {
            if !filter.deletedOnly {
                ToolbarItem {
                    Menu {
                        Button("专题汇编（Word / Markdown）…") { startExport(.compilation) }
                        Button("导出到 Anki…") { startExport(.anki) }
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
                    .help("立即彻底删除这里的全部摘录（无法恢复）")
                    .disabled(state.items.isEmpty)
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

    private func load() {
        do {
            if state.lastQuery != query {
                // 换了筛选条件：回到第一页，清空选择
                state.lastQuery = query
                state.selection = []
                if state.limit != ListState.pageSize {
                    state.limit = ListState.pageSize
                    return   // limit 变化会再次触发 load
                }
            }
            state.total = try store.db.count(query)
            state.items = try store.db.highlights(query, limit: state.limit)
            state.selection = state.selection.filter { id in state.items.contains { $0.id == id } }
        } catch {
            store.report(error)
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
            Button("加入记忆卡") { store.batch(.addToMastery, ids: ids) }
            Button("弃置（不再出现在回顾中）") { store.batch(.discard(true), ids: ids) }
            Button("取消弃置") { store.batch(.discard(false), ids: ids) }
            Divider()
            Button("删除 \(ids.count) 条（移入最近删除）", role: .destructive) { store.batch(.delete, ids: ids) }
        }
    }
}

struct HighlightRow: View {
    let highlight: Highlight
    let source: Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(highlight.text)
                .font(.system(.body, design: .serif))
                .lineLimit(6)
                .textSelection(.enabled)
            if let t = highlight.translation {
                Text("译：\(t)").font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if let n = highlight.note {
                Text("按：\(n)").font(.callout).foregroundStyle(.blue).lineLimit(3)
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
                if highlight.isInMastery { Image(systemName: "brain").foregroundStyle(.purple) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 摘录的右键菜单（列表与回顾共用）
struct HighlightMenu: View {
    @Environment(LibraryStore.self) private var store
    let highlight: Highlight
    private let scheduler = ReviewScheduler()

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
        Button(highlight.isInMastery ? "移出记忆卡" : "加入记忆卡") {
            store.save(highlight.isInMastery
                       ? scheduler.removeFromMastery(highlight)
                       : scheduler.addToMastery(highlight))
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
