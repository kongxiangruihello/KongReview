import SwiftUI
import KongReviewCore

struct CardDuplicateReviewView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let state = store.duplicateCardReview
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("比较与整理记忆卡").font(.title2.bold())
                Spacer()
                if let state, !state.scanning {
                    Text("已整理 \(state.removed) 张")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("重新扫描") { store.findDuplicateCards() }
                    .disabled(state?.processing == true || state?.scanning == true)
            }
            HStack(spacing: 18) {
                Picker("比对方式", selection: Binding(
                    get: { store.duplicateCardReview?.mode ?? .exact },
                    set: { store.findDuplicateCards(mode: $0) }
                )) {
                    ForEach(CardDuplicateScanMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 320)
                Picker("范围", selection: Binding(
                    get: { store.duplicateCardReview?.scopeDeck ?? "" },
                    set: { store.findDuplicateCards(scopeDeck: $0) }
                )) {
                    Text("全部牌组").tag("")
                    ForEach(Array(Set(store.deckSummaryCache.map(\.name) + (state?.scopeDeck.map { [$0] } ?? []))).sorted(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }.frame(maxWidth: 300)
            }.disabled(state?.processing == true || state?.scanning == true)
            Text("逐组比较，选择要保留的一张：它的牌组、标签和原学习排程全部保留，其余卡片标记为删除，历史回顾记录保留。首次整理前自动备份，可用 ⌘Z 撤销。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = state?.scanNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = state?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state?.mode == .similar {
                HStack {
                    if state?.scanning == true { Button("暂停扫描") { store.pauseFullSimilarity() } }
                    else if state?.paused == true {
                        Button("继续扫描") { store.continueFullSimilarity() }.disabled((state?.groups.count ?? 0) >= 200)
                        Button("清空本批建议并继续") {
                            store.duplicateCardReview?.groups = []
                            store.duplicateCardReview?.keeper = [:]
                            store.duplicateCardReview?.position = 0
                            store.continueFullSimilarity()
                        }
                        Text("暂停后可比较和整理；关闭窗口将结束本次扫描。").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(state?.processing == true)
            }
            if state?.scanning == true {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(state?.mode == .similar ? "正在查找高度相似的正反面内容…" : "正在比对全部记忆卡…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let state, let group = state.currentGroup {
                HStack {
                    Text("第 \(state.position + 1) / \(state.groups.count) 组 · \(group.cards.count) 张")
                        .font(.headline)
                    if let score = group.similarityScore {
                        Text("相似度约 \(Int((score * 100).rounded()))% · 请核对差异")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("上一组") { store.moveDuplicateCardGroup(-1) }
                        .disabled(state.position == 0 || state.processing)
                    Button("下一组") { store.moveDuplicateCardGroup(1) }
                        .disabled(state.position + 1 >= state.groups.count || state.processing)
                }
                ScrollView {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(group.cards) { card in
                                comparisonColumn(card, groupID: group.id,
                                                 selected: state.keeper[group.id] == card.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                .disabled(state.processing)
                HStack {
                    if state.processing {
                        ProgressView().controlSize(.small)
                        Text(state.backupDone ? "正在整理…" : "正在备份并整理…")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if state.keeper[group.id] == nil {
                        Text("请先点选要保留的卡片。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("保留选中项，整理其余 \(group.cards.count - 1) 张…") {
                        store.requestResolveDuplicateCardGroup(group.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.processing || state.keeper[group.id] == nil)
                }
            } else {
                ContentUnavailableView(state?.error == nil ? (state?.mode == .similar ? (state?.paused == true ? "扫描已暂停，暂无待比较建议" : "本次扫描未发现高度相似的记忆卡") : "没有待整理的重复记忆卡") : "扫描未完成",
                                       systemImage: state?.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("模板、全部字段和自定义栏目必须一致；相似内容仅作建议，请逐字核对后再整理。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { store.closeDuplicateCardReview() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state?.processing == true)
            }
        }
        .padding(22)
        .frame(minWidth: 800, idealWidth: 960, minHeight: 620, idealHeight: 740)
        .interactiveDismissDisabled(state?.processing == true)
        .onDisappear { store.fullSimilarityTask?.cancel(); store.fullSimilaritySession = nil }
        .confirmationDialog("保留选中的卡片及其学习进度？", isPresented: Binding(
            get: { store.duplicateCardReview?.confirmingGroupID != nil },
            set: { if !$0 { store.duplicateCardReview?.confirmingGroupID = nil } }
        ), titleVisibility: .visible) {
            if let groupID = state?.confirmingGroupID {
                Button("确认整理其余卡片", role: .destructive) {
                    store.resolveDuplicateCardGroup(groupID)
                }
            }
            Button("继续比较", role: .cancel) { store.duplicateCardReview?.confirmingGroupID = nil }
        } message: {
            Text("保留项的内容、标签、牌组和学习排程保持原样，其余项不会合并进来。整理前自动备份，整理后可用 ⌘Z 撤销。")
        }
    }

    private func comparisonColumn(_ card: Card, groupID: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let id = card.id { store.selectDuplicateCardKeeper(groupID: groupID, cardID: id) }
            } label: {
                Label(selected ? "保留这张及其学习进度" : "选择保留这张", systemImage: selected ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(selected ? ReviewPalette.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? ReviewPalette.accent : ReviewPalette.ink)
            .contentShape(Rectangle())
            .handCursor()

            Text("牌组：\(card.deck)").font(.headline)
            Text("标签：" + (card.tags.isEmpty ? "无" : card.tags.map { "#" + $0 }.joined(separator: " ")))
                .font(.callout).textSelection(.enabled)
            Text("\(stateLabel(card)) · 已复习 \(card.reps) 次 · 遗忘 \(card.lapses) 次")
                .font(.callout)
            Text("间隔 \(Int(card.interval)) 天 · 到期 \(card.due.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let stability = card.stability {
                Text("FSRS 稳定性 \(String(format: "%.1f", stability)) 天"
                     + (card.difficulty.map { " · 难度 \(String(format: "%.1f", $0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("创建于 \(card.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let highlightID = card.highlightId {
                Text("关联摘录 #\(highlightID)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("正面").font(.headline)
            RichWebText(text: card.front, slot: "duplicate-card-\(card.id ?? 0)-front")
            Text("背面").font(.headline).padding(.top, 6)
            RichWebText(text: card.back, slot: "duplicate-card-\(card.id ?? 0)-back")
            if let type = card.noteType {
                Text("笔记类型：\(type)").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                    Text("字段 \(index + 1)").font(.headline)
                    RichWebText(text: field, slot: "duplicate-card-\(card.id ?? 0)-field-\(index)")
                }
            }
            ForEach(card.sections ?? []) { section in
                Text(section.name.isEmpty ? "自定义栏目" : section.name).font(.headline)
                RichWebText(text: section.text, slot: "duplicate-card-\(card.id ?? 0)-section-\(section.id)")
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? ReviewPalette.accent : ReviewPalette.hair,
                                                        lineWidth: selected ? 2 : 1))
    }

    private func stateLabel(_ card: Card) -> String {
        if card.isSuspended { return "已暂停" }
        switch card.state {
        case .new: return "新卡"
        case .learning: return "学习中"
        case .review: return "复习卡"
        case .relearning: return "重新学习中"
        }
    }
}
