import SwiftUI
import Charts
import KongReviewCore

/// 回顾统计：连续天数、最近 30 天每天回顾的摘录与记忆卡、记忆卡正确率、库存数字
struct StatsView: View {
    @Environment(LibraryStore.self) private var store
    /// 首页沿用全部统计，在同一个滚动区域末尾显示今天的入口。
    var showsHomeActions = false

    private struct Bar: Identifiable {
        var day: Date
        var kind: String
        var count: Int
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        _ = store.revision
        _ = store.today
        let s = store.stats
        let insights = store.cardInsights
        let cards = insights?.counts ?? CardStateCounts()
        let classified = store.highlightCounts.values.reduce(0, +)
        let highlights = store.staleSummary.total
        let unsorted = max(0, highlights - classified)
        let bars = s.lastDays.flatMap { d -> [Bar] in
            let date = Self.parse(d.key)
            return [Bar(day: date, kind: "摘录", count: d.highlights), Bar(day: date, kind: "记忆卡", count: d.cards)]
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    tile("今天", "\(s.today.highlights) 条摘录\n\(s.today.cards) 次记忆卡", "sun.max")
                    tile("连续回顾", "\(s.currentStreak) 天", "flame")
                    tile("最长连续", "\(s.longestStreak) 天", "trophy")
                    tile("回顾过的天数", "\(s.activeDays) 天", "calendar")
                    tile("累计回顾", "\(s.totalHighlights) 条摘录\n\(s.totalCards) 次记忆卡", "sum")
                    tile("记忆卡正确率", s.cardAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—", "checkmark.circle")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近 30 天").font(.headline)
                    Chart(bars) { b in
                        BarMark(x: .value("日期", b.day, unit: .day), y: .value("次数", b.count))
                            .foregroundStyle(by: .value("类别", b.kind))
                    }
                    .chartForegroundStyleScale(["摘录": Color.blue, "记忆卡": Color.purple])
                    .frame(height: 220)
                }

                if insights?.counts.total ?? 0 > 0 {
                    DeckStudySection()
                }

                if let insights, insights.counts.total > 0 {
                    CardInsightsSection(insights: insights)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("库存").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { Text("摘录"); Text("共 \(highlights) 条（已归类 \(classified)，未归类 \(unsorted)）") }
                        GridRow { Text("出处"); Text("\(store.sources.count) 个") }
                        GridRow { Text("网页存档"); Text("\(store.articleCount) 篇") }
                        GridRow { Text("专题笔记本"); Text("\(store.notebooks.count) 本") }
                        GridRow { Text("标签"); Text("\(store.tags.count) 个") }
                        GridRow {
                            Text("记忆卡")
                            Text("\(store.cardCount) 张" + (insights == nil ? "" : "：新卡 \(cards.new)，学习中 \(cards.learning)，复习中 \(cards.review)，已暂停 \(cards.suspended)"))
                        }
                    }
                    .monospacedDigit()
                }

                staleSection

                ClassicProgressSection()

                Text("统计从 0.7 版开始记录：每日回顾里“下一条 / 收藏 / 弃置 / 做成记忆卡”算回顾一条摘录；记忆卡每评一次分算一次。")
                    .font(.caption).foregroundStyle(.secondary)

                if showsHomeActions {
                    HomeActionsView()
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .onAppear { store.refreshDerived() }   // 2.2：打开统计页时按最新记录重算
        .sheet(item: Bindable(store).chapterProgressRequest) { req in
            ChapterProgressSheet(sourceId: req.sourceId)
        }
        .navigationTitle(showsHomeActions ? "首页" : "回顾统计")
        // 卡片统计只在打开本页、数据变化时重算（SQL 汇总，不读出全部卡片）
        .task(id: store.revision) { store.refreshCardInsights() }
    }

    /// 1.5：久未回顾——从未在每日回顾里出现过、或半年以上没出现的摘录
    private var staleSection: some View {
        let s = store.staleSummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("久未回顾").font(.headline)
                Spacer()
                if s.never + s.old > 0 {
                    Button {
                        store.review.theme = ReviewScope.stale
                        store.review.sessionToken += 1
                        store.selection = .review
                    } label: {
                        Label("本周优先回顾这些", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.link)
                    .handCursor()
                    .help("今日回顾改为只从这些摘录里抽（在回顾页顶部的范围菜单可改回“全部摘录”）")
                }
            }
            HStack(spacing: 12) {
                tile("从未出现", "\(s.never) 条", "eye.slash")
                tile("半年以上没出现", "\(s.old) 条", "clock.arrow.circlepath")
                tile("占全部摘录", s.total > 0 ? String(format: "%.0f%%", Double(s.never + s.old) * 100 / Double(s.total)) : "—", "percent")
            }
            if !s.bySource.isEmpty && s.never > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从未出现的摘录较多的出处").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(s.bySource.enumerated()), id: \.offset) { _, item in
                        HStack {
                            if let id = item.0, let src = store.sources.first(where: { $0.id == id }) {
                                Button("《\(src.title)》") { store.selection = .source(id) }
                                    .buttonStyle(.link)
                                    .handCursor()
                            } else {
                                Text("未归类")
                            }
                            Spacer()
                            Text("\(item.1) 条").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: 420)
            }
            Text("每日回顾按出处权重随机抽取，摘录多的出处里总有一些轮不到。可在“出处管理”里调高某个出处的回顾权重，或点上面的按钮集中看一周。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }

    static func parse(_ key: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key) ?? Date()
    }
}

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

// MARK: - 2.2：古籍篇目进度

/// 统计页：正在读的古籍各有几篇、回顾过几成、全篇过完几篇，最近一周回顾了哪些篇；点一部书打开它的篇目进度
struct ClassicProgressSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let _ = store.revision
        let list = store.classicOverview()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("古籍篇目进度").font(.headline)
                ForEach(list) { o in
                    let tint = DeckColors.color(for: store.chapterBookTitle(o.id))
                    Button {
                        store.chapterProgressRequest = ChapterProgressRequest(sourceId: o.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("《\(o.source.title)》").font(.system(size: 15, weight: .semibold, design: .serif))
                                    .foregroundStyle(ReviewPalette.ink)
                                Text("\(o.chapters.count) 篇 · 全篇回顾过 \(o.finished) 篇 · 摘录回顾过 \(o.reviewed)/\(o.total)")
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ReviewPalette.sub)
                            }
                            // 每篇一小段，回顾过的比例越高颜色越深
                            HStack(spacing: 2) {
                                ForEach(o.chapters) { c in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(c.reviewed == 0 ? ReviewPalette.hair : tint.opacity(0.25 + 0.75 * c.reviewedRatio))
                                        .frame(height: 8)
                                        .help("《\(c.name)》\(c.summary)")
                                }
                            }
                            Text(o.recent.isEmpty ? "最近一周没有回顾这部书。" : "最近一周回顾了：" + o.recent.prefix(12).joined(separator: "、") + (o.recent.count > 12 ? " 等 \(o.recent.count) 篇" : ""))
                                .font(.system(size: 12)).foregroundStyle(o.recent.isEmpty ? ReviewPalette.sub : ReviewPalette.ink)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ReviewPalette.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ReviewPalette.hair))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
        }
    }
}

// MARK: - 2.3：按牌组的学习统计

/// 今天（或最近 7 天）各牌组：新卡学了几张 / 每日上限、复习几张 / 上限、评分几次、“重来”几次、答对率、还剩多少。
/// 用来核对牌组页的数字：上限 − 已学 = 牌组页显示的“新卡”“待复习”（不超过实际到期的张数）。
struct DeckStudySection: View {
    @Environment(LibraryStore.self) private var store

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
                        let left = summaries.first { $0.name == name }?.counts
                        GridRow {
                            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                            Text(week ? "\(s.newCards)" : "\(s.newCards) / \(o.newPerDay ?? CardSettings.newPerDay)")
                                .foregroundStyle(DeckColors.newColor)
                            Text(week ? "\(s.reviewCards)" : "\(s.reviewCards) / \(o.reviewsPerDay ?? CardSettings.reviewsPerDay)")
                                .foregroundStyle(DeckColors.reviewColor)
                            Text("\(s.answers)")
                            Text("\(s.again)").foregroundStyle(s.again > 0 ? DeckColors.seal : Color.secondary)
                            Text(s.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            if !week {
                                Text(left.map { "新 \($0.new) · 学 \($0.learning) · 复 \($0.review)" } ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if names.count > 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("合计").bold()
                            Text("\(total.newCards)")
                            Text("\(total.reviewCards)")
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
            Text("新卡、复习按“张”算（同一张卡今天评几次分只算一张）：第一次评分前还是新卡的算新卡，其余算复习。“评分”是评分次数，学习步骤里一张卡会评好几次。牌组页显示的“新卡”“待复习”＝上限减去已学，且不超过实际到期的张数；“还剩”就是牌组页此刻的数字（新卡 · 学习中 · 待复习）。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
