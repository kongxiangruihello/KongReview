import SwiftUI
import KongReviewCore

// MARK: - 5.0.3：首页“常念的问题”“去年今日”

/// 常念的问题：一行列出前三个，点开即问题页
struct PinnedQuestionsHomeCard: View {
    @Environment(LibraryStore.self) private var store
    @State private var items: [QuestionRef] = []
    @State private var total = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Color.orange)
                    Text("常念的问题").foregroundStyle(ReviewPalette.ink)
                }
                .font(.system(size: 15, weight: .semibold, design: .serif))
                if total > 0 { Text("\(total) 个").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
                Spacer()
                Button(total > items.count ? "全部 \(total) 个" : "问题簿") { store.openQuestionBook(QuestionFilter(state: .unsolved)) }
                    .buttonStyle(.borderless).font(.system(size: 12.5)).handCursor()
            }
            if items.isEmpty {
                Text("在问题簿里把最放不下的十来个问题标为「常念」，它们会排在最前，约每周在重温里回来一次。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { chips }
                    VStack(alignment: .leading, spacing: 6) { chips }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        .task(id: store.questionRevision) {
            let r = (try? store.db.pinnedQuestions()) ?? (items: [], total: 0)
            items = r.items; total = r.total
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(items) { q in
            Button { store.selection = .question(q.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: q.status.symbol).font(.system(size: 11)).foregroundStyle(q.status.color)
                    Text(q.title).font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(ReviewPalette.soft, in: Capsule())
                .overlay(Capsule().stroke(ReviewPalette.hair))
            }
            .buttonStyle(.plain).handCursor()
            .help(q.title)
        }
    }
}

/// 去年今日：有就显示一条，可展开全部；没有就不显示（由首页读取，空时首页不放这张卡）
struct OnThisDayHomeCard: View {
    @Environment(LibraryStore.self) private var store
    let items: [OnThisDayItem]
    @State private var expanded = false

    var body: some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("去年今日").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        Text("往年的今天，在想什么").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                        Spacer()
                        if items.count > 1 {
                            Button(expanded ? "收起" : "展开全部 \(items.count) 条") { expanded.toggle() }
                                .buttonStyle(.borderless).font(.system(size: 12.5)).handCursor()
                        }
                    }
                    ForEach(expanded ? items : Array(items.prefix(1))) { item in row(item) }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
    }

    private func row(_ item: OnThisDayItem) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.yearsAgo) 年前 · \(item.label)").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).fixedSize()
                Text(item.text).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    private func open(_ item: OnThisDayItem) {
        switch item.kind {
        case .note: store.selection = .ideaNote(item.recordId)
        case .question: store.selection = .question(item.recordId)
        case .highlight:
            if let h = try? store.db.highlights(ids: [item.recordId]).first { store.edit(h) }
        }
    }
}
