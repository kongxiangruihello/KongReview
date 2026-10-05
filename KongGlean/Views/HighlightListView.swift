import SwiftUI
import AppKit
import KongGleanCore

struct HighlightFilter: Hashable {
    var sourceId: Int64?
    var tag: String?
    var favoritesOnly = false
    var masteryOnly = false
    var unsortedOnly = false
}

struct HighlightListView: View {
    @Environment(LibraryStore.self) private var store
    let title: String
    let filter: HighlightFilter

    @State private var query = ""
    @State private var items: [Highlight] = []

    private struct LoadKey: Hashable {
        var filter: HighlightFilter
        var query: String
        var revision: Int
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "还没有摘录" : "没有找到", systemImage: "text.quote")
                } description: {
                    Text(query.isEmpty ? "按 ⌘N 新建一条摘录，或在浏览器里用书签小程序发送选中文字。" : "换个关键词试试。两个字以内的查询使用模糊匹配。")
                }
            } else {
                List(items) { h in
                    HighlightRow(highlight: h, source: store.source(for: h))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.edit(h) }
                        .contextMenu { HighlightMenu(highlight: h) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(items.count) 条")
        .searchable(text: $query, prompt: "搜索原文、译文、按语")
        .task(id: LoadKey(filter: filter, query: query, revision: store.revision)) {
            load()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.newHighlight(in: filter.sourceId)
                } label: {
                    Label("新建摘录", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func load() {
        do {
            items = try store.db.highlights(
                query: query,
                sourceId: filter.sourceId,
                tag: filter.tag,
                favoritesOnly: filter.favoritesOnly,
                masteryOnly: filter.masteryOnly,
                unsortedOnly: filter.unsortedOnly
            )
        } catch {
            store.report(error)
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
                let cite = CitationFormatter.citation(for: highlight, source: source)
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
        Button("删除", role: .destructive) { store.delete(highlight) }
    }

    private func copy(withCitation: Bool) {
        var s = highlight.text
        if withCitation {
            let cite = CitationFormatter.citation(for: highlight, source: store.source(for: highlight))
            if !cite.isEmpty { s += "\n——\(cite)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyMarkdown() {
        let md = MarkdownExporter.block(for: highlight, source: store.source(for: highlight))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}
