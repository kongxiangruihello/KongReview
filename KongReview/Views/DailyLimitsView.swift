import SwiftUI
import KongReviewCore

// MARK: - 3.13：每日学习量

/// 可直接输入的数字框加步进器；超出 0–9999 时自动收回范围
struct DailyLimitNumberField: View {
    @Binding var value: Int
    var step = 5

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding(get: { value }, set: { value = DailyLimitSettings.clamp($0) }),
                      format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Stepper("", value: $value, in: DailyLimitSettings.valueRange, step: step)
                .labelsHidden()
        }
        .fixedSize()
    }
}

/// 集中设置：牌组默认值、全库合计、各牌组上限，并即时预览今天还可学多少
struct DailyLimitsView: View {
    @Environment(LibraryStore.self) private var store

    private func binding<T>(_ kp: WritableKeyPath<DailyLimitsDraft, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { store.dailyLimitsEditor?[keyPath: kp] ?? fallback },
                set: { store.dailyLimitsEditor?[keyPath: kp] = $0 })
    }

    var body: some View {
        let draft = store.dailyLimitsEditor
        return VStack(alignment: .leading, spacing: 12) {
            Text("每日学习量").font(.title2.bold())
            Text("一张卡今天能否出现，要同时满足牌组自己的上限和全库合计（若已设置）。改动保存后立即生效。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let draft { previewBar(draft) }
            ScrollViewReader { proxy in
                Form {
                    if let draft {
                        totalSection(draft)
                        defaultSection
                        deckSection(draft)
                        if draft.hasTodayExtra { extraSection(draft) }
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    if let deck = draft?.focusDeck {
                        DispatchQueue.main.async { proxy.scrollTo(deck, anchor: .center) }
                    }
                }
            }
            HStack {
                Text("仅今天多学几张：学完后在完成页点“今天再学”，次日自动恢复。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("取消", role: .cancel) { store.dailyLimitsEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { if let d = store.dailyLimitsEditor { store.saveDailyLimits(d) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 680)
    }

    // MARK: 今天的预览

    private func previewBar(_ draft: DailyLimitsDraft) -> some View {
        let p = draft.preview
        let spent = draft.ledger.totalSpent
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("按以上设置，今天此刻还可学").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    count("新卡", p.new, DeckColors.newColor)
                    count("学习中", p.learning, DeckColors.learnColor)
                    count("复习", p.review, DeckColors.reviewColor)
                    Text("约 \(DeckOverview.estimatedMinutes(p)) 分钟").foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("今天已学").font(.caption).foregroundStyle(.secondary)
                Text("新卡 \(spent.new) · 复习 \(spent.review)").monospacedDigit()
            }
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ReviewPalette.soft))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReviewPalette.hair))
    }

    private func count(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text("\(n)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
    }

    // MARK: 全库合计

    private func totalSection(_ draft: DailyLimitsDraft) -> some View {
        let sum = draft.sumOfDeckLimits
        return Section("全库合计（所有牌组加起来）") {
            totalRow("限制每天新卡合计", enabled: \.totalNewEnabled, value: \.totalNew, step: 5)
            totalRow("限制每天复习合计", enabled: \.totalReviewEnabled, value: \.totalReview, step: 10)
            Text("各牌组上限加起来：新卡 \(sum.new) 张、复习 \(sum.review) 张。合计设得更小时以合计为准，先学的牌组先用；牌组自己的上限仍然有效。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func totalRow(_ title: String, enabled: WritableKeyPath<DailyLimitsDraft, Bool>,
                          value: WritableKeyPath<DailyLimitsDraft, Int>, step: Int) -> some View {
        let on = store.dailyLimitsEditor?[keyPath: enabled] ?? false
        return HStack {
            Toggle(title, isOn: binding(enabled, false))
            Spacer()
            if on {
                DailyLimitNumberField(value: binding(value, 0), step: step)
            } else {
                Text("不限").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 牌组默认

    private var defaultSection: some View {
        Section("牌组默认（未单独设置的牌组各用这个数）") {
            LabeledContent("每天新卡") { DailyLimitNumberField(value: binding(\.newPerDay, 20), step: 5) }
            LabeledContent("每天复习上限") { DailyLimitNumberField(value: binding(\.reviewsPerDay, 200), step: 10) }
        }
    }

    // MARK: 各牌组

    private func deckSection(_ draft: DailyLimitsDraft) -> some View {
        Section {
            if draft.overview.rows.isEmpty {
                Text("还没有牌组。").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("牌组")
                        Text("每天新卡")
                        Text("每天复习")
                        Text("今天已学").gridColumnAlignment(.trailing)
                        Text("此刻可学").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(draft.overview.rows) { row in
                        deckRow(row, draft: draft)
                    }
                }
            }
        } header: {
            Text("各牌组")
        } footer: {
            Text("“默认”表示跟随牌组默认值，点一下改为单独设置；单独设置的数字旁点 ↺ 恢复默认。“此刻可学”已扣除今天已学，并受全库合计约束。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deckRow(_ row: DailyLimitDeckRow, draft: DailyLimitsDraft) -> some View {
        let parts = DeckOverview.split(row.deck)
        let focused = draft.focusDeck == row.deck
        let can = draft.deckPreview(row)
        return GridRow {
            VStack(alignment: .leading, spacing: 1) {
                if let parent = parts.parent {
                    Text(parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(parts.leaf).fontWeight(focused ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.vertical, 2)
            .padding(.horizontal, focused ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: 6).fill(focused ? ReviewPalette.accent.opacity(0.12) : .clear))
            .id(row.deck)   // 供从牌组标签进入时滚动定位；放在单元格上，不包住 GridRow
            limitCell(row.deck, .new, default: draft.newPerDay, step: 5)
            limitCell(row.deck, .review, default: draft.reviewsPerDay, step: 10)
            Text("新 \(row.spent.new) · 复 \(row.spent.review)")
                .monospacedDigit().foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text("新 \(can.new) · 复 \(can.review)" + (row.learning > 0 ? " · 学 \(row.learning)" : ""))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func limitCell(_ deck: String, _ kind: DailyLimitKind, default fallback: Int, step: Int) -> some View {
        if let value = store.dailyLimitsEditor?.limit(deck, kind) {
            HStack(spacing: 2) {
                DailyLimitNumberField(value: Binding(get: { value },
                                                     set: { store.dailyLimitsEditor?.setLimit(deck, kind, $0) }),
                                      step: step)
                Button { store.dailyLimitsEditor?.setLimit(deck, kind, nil) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("恢复为牌组默认值（\(fallback)）")
            }
        } else {
            Button("默认 \(fallback)") { store.dailyLimitsEditor?.setLimit(deck, kind, fallback) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("跟随牌组默认值；点一下为这个牌组单独设置")
        }
    }

    // MARK: 仅今天

    private func extraSection(_ draft: DailyLimitsDraft) -> some View {
        Section("今天的临时加量（明天自动恢复）") {
            Text(draft.todayExtraDescription).font(.callout)
            Button("清除今天的加量") { store.clearTodayExtra() }
        }
    }
}
