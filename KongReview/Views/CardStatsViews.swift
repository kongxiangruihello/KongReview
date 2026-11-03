import SwiftUI
import Charts
import KongReviewCore

// 6.0.5：“回顾统计”页并入成绩册；这里留下成绩册“记忆卡”一节用的两块。

// MARK: - 1.1：记忆卡负荷预测与实际保留率

struct CardInsightsSection: View {
    let insights: LibraryStore.CardInsights

    var body: some View {
        let load = insights.load
        let ret = insights.retention
        let weeks = ret.weeks.filter { $0.reviews > 0 }
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("记忆卡：未来 30 天的复习量").font(.headline)
                    Spacer()
                    Text(summary(load)).font(.caption).foregroundStyle(.secondary)
                }
                Chart(load.days) { d in
                    BarMark(x: .value("日期", d.date, unit: .day), y: .value("到期", d.count))
                        .foregroundStyle(ReviewPalette.accent.opacity(d.date == load.days.first?.date ? 1 : 0.7))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .frame(height: 170)
                Text("只算已学过的卡（新卡按每日上限另外引入）；已过期未复习的 \(load.overdue) 张计入今天。哪天特别高，可以提前在“记忆卡”里多复习一些，或调低新卡上限。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("实际保留率（每周）").font(.headline)
                    Spacer()
                    Text(retentionSummary(ret)).font(.caption).foregroundStyle(.secondary)
                }
                if weeks.isEmpty {
                    Text("还没有隔天以上的复习记录。复习几天后这里会显示每周记住的比例。")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Chart {
                        RuleMark(y: .value("目标", insights.target * 100))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("目标 \(Int((insights.target * 100).rounded()))%").font(.caption2).foregroundStyle(.secondary)
                            }
                        ForEach(weeks) { w in
                            LineMark(x: .value("周", w.start, unit: .weekOfYear), y: .value("保留率", (w.retention ?? 0) * 100))
                                .foregroundStyle(ReviewPalette.accent)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("周", w.start, unit: .weekOfYear), y: .value("保留率", (w.retention ?? 0) * 100))
                                .foregroundStyle(ReviewPalette.accent)
                                .symbolSize(w.reviews < 20 ? 14 : 30)
                        }
                    }
                    .chartYScale(domain: yDomain(weeks, target: insights.target))
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { if let n = v.as(Double.self) { Text("\(Int(n))%") } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .frame(height: 170)
                }
                Text("只算隔天以上再见到的复习（同一天的学习步、重学步不算），答“困难 / 良好 / 简单”算记住。明显低于目标线：间隔偏长，可调高期望保留率或优化 FSRS 参数；明显高于：可适当调低以减少复习量。小点表示当周复习不足 20 次，参考价值有限。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ l: CardForecast.Load) -> String {
        var parts = ["今天 \(l.days.first?.count ?? 0)", "7 天日均 \(String(format: "%.0f", l.average(first: 7)))",
                     "30 天共 \(l.total)"]
        if let p = l.peak, p.count > 0 {
            parts.append("最多 \(p.date.formatted(.dateTime.month(.defaultDigits).day())) \(p.count) 张")
        }
        return parts.joined(separator: " · ")
    }

    private func retentionSummary(_ r: CardForecast.Retention) -> String {
        guard let v = r.last30 else { return "近 30 天暂无复习" }
        return String(format: "近 30 天 %.1f%%（%d 次复习）", v * 100, r.last30Reviews)
    }

    private func yDomain(_ weeks: [CardForecast.Week], target: Double) -> ClosedRange<Double> {
        let values = weeks.compactMap(\.retention).map { $0 * 100 } + [target * 100]
        let lo = max(0, (values.min() ?? 70) - 5)
        let hi = min(100, (values.max() ?? 100) + 3)
        return lo...max(hi, lo + 10)
    }
}

// MARK: - 2.3：按牌组的学习统计

/// 今天（或最近 7 天）各牌组：新卡学了几张 / 每日上限、复习几张 / 上限、评分几次、“重来”几次、答对率、还剩多少。
/// 用来核对牌组页的数字：上限 − 已学 = 牌组页显示的“新卡”“待复习”（不超过实际到期的张数）。
struct DeckStudySection: View {
    @Environment(LibraryStore.self) private var store

    /// 今天的全库合计上限（含临时加量）；不限时为 nil
    private func totalLimit(_ kind: DailyLimitKind) -> Int? {
        store.dailyLimitLedgerCache?.totalLimit(kind)
    }

    var body: some View {
        let week = store.deckStudyShowWeek
        let stats = week ? store.deckStudyWeek : store.deckStudyToday
        let summaries = store.deckSummaryCache
        // 今天：学过的牌组 + 还有卡要学的牌组；最近 7 天：只列学过的
        var names = stats.map(\.deck)
        if !week {
            for d in summaries where d.counts.total > 0 && !names.contains(d.name) { names.append(d.name) }
        }
        let byDeck = Dictionary(stats.map { ($0.deck, $0) }, uniquingKeysWith: { a, _ in a })
        let total = stats.reduce(DeckStudyStat(deck: "合计")) { $0 + $1 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("记忆卡：按牌组").font(.headline)
                Spacer()
                Picker("", selection: Bindable(store).deckStudyShowWeek) {
                    Text("今天").tag(false)
                    Text("最近 7 天").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if names.isEmpty {
                Text(week ? "最近 7 天没有复习记忆卡。" : "今天还没有复习记忆卡，也没有到期的卡。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        Text("牌组").gridColumnAlignment(.leading)
                        Text(week ? "新卡" : "新卡 / 上限")
                        Text(week ? "复习" : "复习 / 上限")
                        Text("评分")
                        Text("重来")
                        Text("答对率")
                        if !week { Text("还剩") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(names, id: \.self) { name in
                        let s = byDeck[name] ?? DeckStudyStat(deck: name)
                        let o = store.options(for: name)
                        // 3.13：上限含今天的临时加量，与牌组页一致
                        let limit = store.dailyLimitLedgerCache?.deckLimit(name)
                            ?? DailyAmount(new: o.newPerDay ?? CardSettings.newPerDay, review: o.reviewsPerDay ?? CardSettings.reviewsPerDay)
                        let left = summaries.first { $0.name == name }?.counts
                        GridRow {
                            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                            Text(week ? "\(s.newCards)" : "\(s.newCards) / \(limit.new)")
                                .foregroundStyle(DeckColors.newColor)
                            Text(week ? "\(s.reviewCards)" : "\(s.reviewCards) / \(limit.review)")
                                .foregroundStyle(DeckColors.reviewColor)
                            Text("\(s.answers)")
                            Text("\(s.again)").foregroundStyle(s.again > 0 ? DeckColors.seal : Color.secondary)
                            Text(s.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            if !week {
                                Text(left.map { "新 \($0.new) · 学 \($0.learning) · 复 \($0.review)" } ?? "—")
                                    .foregroundStyle((left?.total ?? 0) > 0 ? ReviewPalette.pending : Color.secondary)
                            }
                        }
                    }
                    if names.count > 1 || totalLimit(.new) != nil || totalLimit(.review) != nil {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("合计").bold()
                            Text(week ? "\(total.newCards)" : "\(total.newCards)" + (totalLimit(.new).map { " / \($0)" } ?? ""))
                            Text(week ? "\(total.reviewCards)" : "\(total.reviewCards)" + (totalLimit(.review).map { " / \($0)" } ?? ""))
                            Text("\(total.answers)")
                            Text("\(total.again)")
                            Text(total.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            if !week { Text("") }
                        }
                        .font(.callout.weight(.semibold))
                    }
                }
                .font(.callout.monospacedDigit())
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(ReviewPalette.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReviewPalette.hair))
            }
            Text("新卡、复习按“张”算（同一张卡今天评几次分只算一张）：第一次评分前还是新卡的算新卡，其余算复习。“评分”是评分次数，学习步骤里一张卡会评好几次。牌组页显示的“新卡”“待复习”＝上限减去已学，且不超过实际到期的张数；设了全库合计时，还不超过合计的余额（合计行显示“已学 / 合计上限”）。“还剩”就是牌组页此刻的数字（新卡 · 学习中 · 待复习）。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
