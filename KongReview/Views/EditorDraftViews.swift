import SwiftUI

/// 首页入口仅在有实际未保存内容时出现；用户可继续其他工作，再按需恢复。
struct DraftRecoveryBanner: View {
    var highlights: [SavedHighlightDraft]
    var cards: [SavedCardDraft]
    var onOpen: () -> Void

    var body: some View {
        let count = highlights.count + cards.count
        if count > 0 {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.clock").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("有 \(count) 份未保存的编辑草稿").font(.headline)
                    Text("可继续编辑，也可查看后放弃。草稿保存在这台 Mac 上。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看草稿", action: onOpen).buttonStyle(.bordered)
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 恢复列表的状态由 LibraryStore 持有。两类草稿分别存储，可以同时保留多份。
struct EditorDraftRecoverySheet: View {
    var highlights: [SavedHighlightDraft]
    var cards: [SavedCardDraft]
    var onRestoreHighlight: (UUID) -> Void
    var onRestoreCard: (UUID) -> Void
    var onDiscardHighlight: (UUID) -> Void
    var onDiscardCard: (UUID) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("未保存的编辑草稿").font(.title2.bold())
            Text("选择一份继续编辑。恢复时若原条目已经更新或删除，草稿会作为新条目打开，保留现有数据。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !highlights.isEmpty {
                        Text("摘录 · \(highlights.count)").font(.headline)
                        ForEach(highlights) { draft in
                            recoveryRow(title: draft.title, subtitle: "摘录", date: draft.savedAt,
                                        restore: { onRestoreHighlight(draft.id) },
                                        discard: { onDiscardHighlight(draft.id) })
                        }
                    }
                    if !cards.isEmpty {
                        Text("记忆卡 · \(cards.count)").font(.headline)
                        ForEach(cards) { draft in
                            recoveryRow(title: draft.title, subtitle: draft.card.deck, date: draft.savedAt,
                                        restore: { onRestoreCard(draft.id) },
                                        discard: { onDiscardCard(draft.id) })
                        }
                    }
                    if highlights.isEmpty && cards.isEmpty {
                        ContentUnavailableView("没有待恢复的草稿", systemImage: "doc.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                Text("恢复后点“保存”才会写入正式数据。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("稍后处理", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 400, idealHeight: 560)
    }

    private func recoveryRow(title: String, subtitle: String, date: Date,
                             restore: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(subtitle) · \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("继续编辑", action: restore).buttonStyle(.borderedProminent)
            Button("放弃草稿", role: .destructive, action: discard).buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
