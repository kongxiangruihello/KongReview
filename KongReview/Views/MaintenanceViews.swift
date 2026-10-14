import SwiftUI
import KongReviewCore

// MARK: - 1.5：重复摘录整理面板

struct DuplicatesView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let r = store.duplicateReview
        let exactCount = r?.groups.filter(\.exact).count ?? 0
        let summary: String = r.map { r in
            (r.groups.isEmpty ? "没有找到重复的摘录。" : "\(r.groups.count) 组（完全重复 \(exactCount) 组）")
                + (r.merged > 0 ? "，已合并 \(r.merged) 组" : "")
        } ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("重复摘录").font(.title2.bold())
                Spacer()
                if let r, !r.scanning {
                    Text(summary)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("完全重复：繁简、空格、标点不计，文字相同。相似：同一出处里多几个字或断句不同。合并时保留选中的那一条的原文与出处，其余几条的按语、标签、收藏、回顾次数并进来，记忆卡、专题笔记本里的引用改指向它；其余几条移入“最近删除”。合并前自动备份，⌘Z 可撤销。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if r?.scanning ?? true {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在比对全部摘录…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(r.groups) { g in
                            groupCard(g, r)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                if exactCount > 0 {
                    Button("合并全部完全重复（\(exactCount) 组）") { store.mergeAllExactDuplicates() }
                        .buttonStyle(.borderedProminent)
                        .handCursor()
                }
                Spacer()
                Button("关闭") { store.duplicateReview = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 640)
        .background(ReviewPalette.page)
    }

    private func groupCard(_ g: DuplicateFinder.Group, _ r: DuplicateReview) -> some View {
        let keeper = r.keeper[g.id] ?? g.ids[0]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(g.exact ? "完全重复" : "相似")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(g.exact ? ReviewPalette.accent : ReviewPalette.hard)
                    .background((g.exact ? ReviewPalette.accentSoft : ReviewPalette.hard.opacity(0.12)), in: Capsule())
                Text("\(g.ids.count) 条，点选要保留的一条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("不是重复") { store.ignoreDuplicateGroup(g.id) }
                    .buttonStyle(.link).font(.caption)
                    .handCursor()
                    .help("以后不再把这几条列为重复")
                Button("合并") { store.mergeDuplicateGroup(g.id) }
                    .controlSize(.small)
                    .handCursor()
            }
            ForEach(g.ids, id: \.self) { id in
                if let h = r.highlights[id] {
                    row(h, keep: id == keeper) { store.duplicateReview?.keeper[g.id] = id }
                }
            }
        }
        .padding(14)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }

    private func row(_ h: Highlight, keep: Bool, choose: @escaping () -> Void) -> some View {
        let src = store.source(for: h)
        var meta: [String] = [src.map { "《\($0.title)》" } ?? "未归类"]
        if let l = h.location, !l.isEmpty { meta.append(l) }
        meta.append("录入于 " + h.createdAt.formatted(date: .abbreviated, time: .omitted))
        if h.isFavorite { meta.append("★ 收藏") }
        if !(h.note ?? "").isEmpty { meta.append("有按语") }
        if store.cardHighlightIDs.contains(h.id ?? -1) { meta.append("记忆卡") }
        if !h.tags.isEmpty { meta.append(h.tags.map { "#" + $0 }.joined(separator: " ")) }
        if h.isDiscarded { meta.append("已弃置") }
        return Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: keep ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(keep ? ReviewPalette.accent : ReviewPalette.sub)
                    .font(.system(size: 15))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(MarkdownText.attributed(h.text))
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(ReviewPalette.ink)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    Text(meta.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if keep {
                    Text("保留").font(.caption.weight(.semibold)).foregroundStyle(ReviewPalette.accent)
                }
            }
            .padding(8)
            .background(keep ? ReviewPalette.accentSoft.opacity(0.6) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

struct MaintenanceSheets: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content.sheet(item: $store.duplicateReview) { _ in DuplicatesView() }
    }
}
