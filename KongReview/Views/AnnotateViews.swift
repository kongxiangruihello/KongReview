import SwiftUI
import KongReviewCore

// MARK: - 6.0.4：每天标注文章
//
// 今日试卷上的“今日标注”：每天从还没划过的长文里抽几篇（设置 → 考场 可改篇数）。
// 打开一篇，选中一段按 H（或点“划为摘录”）就存为同一出处下的一条摘录；看完点“这篇标完了”。

/// 卷面上的“今日标注”一栏
struct AnnotateSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let today = store.annotate
        if !today.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("今日标注 \(today.done) / \(today.items.count) 篇", systemImage: "highlighter")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(today.left == 0 ? ReviewPalette.done : ReviewPalette.ink)
                    Spacer()
                    if today.remaining > 0 {
                        Text("此外约 \(today.remaining) 篇待标").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    }
                }
                Text("全部摘录里整篇存进来、还没划过要点的文章。打开读一遍，选中要紧的一段按 H，就存为同一出处下的一条摘录，以后在卷子上出题；原文不动。划过一条或点了“标完了”即算这篇完成。")
                    .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(today.items) { item in row(item) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        }
    }

    private func row(_ item: AnnotateItem) -> some View {
        Button { store.openAnnotation(item.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.doneToday ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.doneToday ? ReviewPalette.done : ReviewPalette.pending)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13.5, weight: .medium, design: .serif))
                        .foregroundStyle(ReviewPalette.ink).lineLimit(1)
                    Text(detail(item)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Text(item.doneToday ? "再看看" : "开始标注").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.accent)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    private func detail(_ item: AnnotateItem) -> String {
        var parts: [String] = []
        if !item.author.isEmpty { parts.append(item.author) }
        parts.append("约 \(item.length) 字")
        if item.marksToday > 0 { parts.append("今天划了 \(item.marksToday) 条") }
        if item.finishedToday { parts.append("已标完") }
        return parts.joined(separator: " · ")
    }
}

/// 标注一篇：阅读器 + 划为摘录 / 这篇标完了 / 下一篇
struct AnnotateSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: AnnotateRequest
    @State private var article: Article?

    var body: some View {
        let _ = store.revision
        let marks = (try? store.db.annotationMarks(articleId: request.articleId)) ?? []
        let item = store.annotate.items.first { $0.id == request.articleId }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article?.title ?? "").font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ReviewPalette.ink).lineLimit(1)
                    Text(subtitle(item, marks: marks.count)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Button {
                    ReaderBridge.shared.sendSelection()
                } label: { Label("划为摘录", systemImage: "highlighter") }
                .help("把选中的文字存为一条摘录（也可直接按 H）")
                Button {
                    store.finishAnnotation(request.articleId)
                    store.openNextAnnotation(after: request.articleId)
                } label: { Label("这篇标完了", systemImage: "checkmark") }
                .keyboardShortcut(.return, modifiers: .command)
                .help("看完了，划了几条都行（⌘↩）；接着打开下一篇")
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if let article {
                ReaderWebView(article: article, marks: marks, store: store, findQuery: "", findRevision: 0)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, maxWidth: .infinity, minHeight: 460, idealHeight: 680, maxHeight: .infinity)
        .task(id: request.articleId) {
            article = try? store.db.annotationArticle(articleId: request.articleId)
        }
    }

    private func subtitle(_ item: AnnotateItem?, marks: Int) -> String {
        var parts: [String] = []
        if let item { parts.append("约 \(item.length) 字") }
        if let item, item.marks > 0 { parts.append("在这里划了 \(item.marks) 条" + (item.marksToday > 0 ? "（今天 \(item.marksToday) 条）" : "")) }
        parts.append("选中文字后按 H 摘录")
        return parts.joined(separator: " · ")
    }
}
