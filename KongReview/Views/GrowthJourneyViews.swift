import SwiftUI
import Charts
import KongReviewCore

struct JourneyPager: View {
    @Binding var page: Int
    let total: Int
    var pageSize = 50
    var body: some View {
        HStack {
            Text("共 \(total) 项 · 第 \(page+1) / \(max(1,(total+pageSize-1)/pageSize)) 页").font(.caption)
            Spacer()
            Button("上一页") { page -= 1 }.disabled(page == 0)
            Button("下一页") { page += 1 }.disabled((page+1)*pageSize >= total)
        }
    }
}

struct GrowthTrendsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var range: GrowthTrendRange = .days
    @State private var metric: GrowthMetric = .highlights
    @State private var points: [GrowthTrendPoint] = []
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = false
    @State private var page = 0
    @State private var details = LearningExplorerPage(rows: [], total: 0)
    @State private var detailsLoading = false
    private var point: GrowthTrendPoint? { points.first { $0.id == selected } ?? points.last }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("范围", selection: $range) { ForEach(GrowthTrendRange.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("指标", selection: $metric) { ForEach([GrowthMetric.highlights,.cards,.ratings]) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text("每根柱在所属日／周／月内去重；评分次数不去重。最近一期截至当前时间。点击柱形或下方日期查看明细。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView() }
                GrowthTrendChart(points: points, metric: metric, selected: point?.id) { selected = $0; page = 0 }
                Picker("查看日期", selection: Binding(get: { point?.id ?? "" }, set: { selected = $0; page = 0 })) {
                    ForEach(points) { p in Text("\(p.window.start.formatted(date: .abbreviated, time: .omitted)) · \(p.summary[metric])").tag(p.id) }
                }
                if detailsLoading { ProgressView() }
                else {
                    if details.rows.isEmpty { Text("此期间暂无记录。").foregroundStyle(.secondary) }
                    ForEach(details.rows) { row in
                        Button { if let target = row.target { store.learningExplorer = .init(route: .document(target,"")) } } label: {
                            VStack(alignment: .leading) { Text(row.title).lineLimit(3); Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(row.target == nil).handCursor()
                    }
                    JourneyPager(page: $page, total: details.total)
                }
            }
        }
        .task(id: "\(range)|\(store.revision)|\(store.today)") {
            loading = true
            do { let result = try await store.db.growthTrend(range); try Task.checkCancellation(); points = result; if !result.contains(where:{ $0.id == selected }) { selected = result.last?.id; page = 0 }; error = nil; loading = false }
            catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id: "\(point?.id ?? "")|\(metric)|\(page)|\(store.revision)") {
            guard let point else { return }
            detailsLoading = true
            do { let result = try await store.db.growthDetails(metric: metric, start: point.window.start, end: point.window.end, offset: page*50); try Task.checkCancellation(); details = result; detailsLoading = false }
            catch is CancellationError { } catch { self.error = error.localizedDescription; detailsLoading = false }
        }
        .onChange(of: metric) { _, _ in page = 0 }
        .onChange(of: range) { _,_ in selected = nil; page = 0 }
    }
}

struct GrowthTrendChart: View {
    let points: [GrowthTrendPoint]
    let metric: GrowthMetric
    let selected: String?
    let onSelect: (String?) -> Void
    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("日期", point.window.start, unit: point.window.period.component), y: .value(metric.title, point.summary[metric]))
                .foregroundStyle(point.id == selected ? ReviewPalette.accent : ReviewPalette.accent.opacity(0.35))
                .accessibilityLabel(point.window.start.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue("\(point.summary[metric])")
        }.frame(height: 220)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let frame = geometry[plot]
                        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return }
                        onSelect(points.first { date >= $0.window.start && date < $0.window.fullEnd }?.id)
                    }
                }
            }
    }
}

struct GrowthHistoryView: View {
    @Environment(LibraryStore.self) private var store
    let onOpen: (GrowthHistoryEntry) -> Void
    private var query: String { get { store.journeyNavigation.historyQuery } nonmutating set { store.journeyNavigation.historyQuery = newValue } }
    private var filter: GrowthPeriod? { get { store.journeyNavigation.historyPeriod } nonmutating set { store.journeyNavigation.historyPeriod = newValue } }
    private var page: Int { get { store.journeyNavigation.historyPage } nonmutating set { store.journeyNavigation.historyPage = newValue } }
    @State private var result = GrowthPage<GrowthHistoryEntry>(items: [], total: 0)
    @State private var loading = false
    @State private var error: String?
    @State private var anchor: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索收获、困难、下一步（支持繁简）", text: Binding(get:{ query },set:{ query = $0 })).textFieldStyle(.roundedBorder)
                Picker("周期", selection: Binding(get:{ filter },set:{ filter = $0 })) {
                    Text("所有周期").tag(Optional<GrowthPeriod>.none)
                    ForEach(GrowthPeriod.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 180)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !loading && result.items.isEmpty { Text("还没有符合条件的复盘。可先在学习小结中写下收获与下一步。").foregroundStyle(.secondary) }
                    ForEach(result.items) { entry in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(entry.period.title) · \(entry.date.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                                Text(RichText.attributed("收获：\(entry.reflection.gains.isEmpty ? "尚未填写" : entry.reflection.gains)"))
                                Text(RichText.attributed("困难：\(entry.reflection.challenges.isEmpty ? "尚未填写" : entry.reflection.challenges)"))
                                Text(RichText.attributed("下一步：\(entry.reflection.nextSteps.isEmpty ? "尚未填写" : entry.reflection.nextSteps)"))
                                Button("打开小结／对照上期计划") { store.journeyNavigation.anchors["history"] = entry.id; onOpen(entry) }.handCursor()
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6).textSelection(.enabled)
                        }.id(entry.id)
                    }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page: Binding(get:{ page },set:{ page = $0 }), total: result.total).disabled(loading)
        }
        .onChange(of: query) { _, _ in page = 0; anchor = nil; store.journeyNavigation.anchors["history"] = nil }.onChange(of: filter) { _, _ in page = 0; anchor = nil; store.journeyNavigation.anchors["history"] = nil }
        .onChange(of: anchor) { _,value in if let value { store.journeyNavigation.anchors["history"] = value } }
        .task(id: "\(query)|\(filter?.rawValue ?? "all")|\(page)|\(store.journeyRevision)") {
            loading = true
            do { try await Task.sleep(for: .milliseconds(180)); let value = try await store.db.growthHistory(query: query, period: filter, offset: page*50); try Task.checkCancellation(); result = value; error = nil; loading = false; if anchor == nil { anchor = store.journeyNavigation.anchors["history"] }; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
        }
    }
}

struct CompletedGrowthPlans: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var page = 0
    @State private var result = GrowthPage<LearningPlan>(items: [], total: 0)
    @State private var error: String?
    var body: some View {
        GrowthBox(title: "本期完成的学习计划 · \(result.total) 项") {
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).foregroundStyle(.red) }
                if result.items.isEmpty { Text("完成的计划会按完成日期自动归入小结。").foregroundStyle(.secondary) }
                ForEach(result.items) { plan in
                    Text(RichText.attributed("✓ \(plan.title) · \(plan.completedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")")).textSelection(.enabled)
                    if let outcome = plan.outcome { PlanOutcomeSummary(outcome:outcome) }
                }
                if result.total > 50 { JourneyPager(page: $page, total: result.total) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.task(id: "\(window.key)|\(page)|\(store.journeyRevision)") {
            do { let value = try await store.db.learningPlans(completed: true, start: window.start, end: window.end, offset: page*50); try Task.checkCancellation(); result = value; error = nil; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}

struct DifficultCarePanel: View {
    @Environment(LibraryStore.self) private var store
    let cardID: Int64
    var onOpenCard: ((Int64) -> Void)? = nil
    @State private var care: DifficultCardCare?
    @State private var reason: DifficultReason = .split
    @State private var note = ""
    @State private var comparison: CardCareComparison?
    @State private var error: String?
    @State private var loaded = false
    @State private var generation = -1
    var body: some View {
        DisclosureGroup("困难卡处理与跟踪") {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("处理原因", selection: $reason) { ForEach(DifficultReason.allCases) { Text($0.title).tag($0) } }.disabled(!loaded)
                RichEditor(text:$note,placeholder:"难卡处理说明",autoHeight:true,minHeight:90,slot:"care-note").richEditorFrame().disabled(!loaded)
                Text("暂缓只作标记。需要暂停正式学习时，请在记忆卡中设置暂停。处理原因自动保存。打开原卡编辑，保存内容修改后会自动记录前后快照并开始跟踪。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存处理记录") { persist() }
                    Button(care?.adjustedAt == nil ? "已调整，开始跟踪" : "重新开始跟踪") { persist(startTracking: true) }
                    if care != nil { Button(care?.resolvedAt == nil ? "标记已解决" : "恢复观察") { persist(toggleResolved: true) } }
                }.disabled(!loaded || store.fullBackupBusy)
                if let care {
                    Text(care.resolvedAt == nil ? "状态：\(care.adjustedAt == nil ? "待调整" : "观察中")" : "状态：已解决（手动标记）").font(.caption)
                    if let adjusted = care.adjustedAt { Text("跟踪开始：\(adjusted.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                if let comparison {
                    Text("前后等长观察（最长14天，当前约\(comparison.days)天）")
                    Text("调整前：重来 \(comparison.beforeAgain) / 评分 \(comparison.beforeRatings)（\(rate(comparison.beforeAgain, comparison.beforeRatings))）；调整后：重来 \(comparison.afterAgain) / 评分 \(comparison.afterRatings)（\(rate(comparison.afterAgain, comparison.afterRatings))）")
                    Text(comparison.interpretation).font(.caption).foregroundStyle(.secondary)
                    Text("仅比较这张卡的正式评分；拆出的新卡独立统计。重新跟踪会以新的开始时间计算。").font(.caption).foregroundStyle(.secondary)
                }
                if care != nil { CareContentHistoryView(cardID:cardID,onOpenCard:onOpenCard) }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(.top, 8).disabled(store.fullBackupBusy)
            }.frame(height: 210)
        }
        .onAppear { generation = store.growthGeneration }
        .onChange(of: reason) { _,_ in saveIfChanged() }
        .onChange(of: note) { _,_ in saveIfChanged() }
        .onDisappear { saveIfChanged() }
        .task(id: "\(cardID)|\(store.revision)|\(store.journeyRevision)") {
            do {
                let value = try store.db.progressValue(DifficultCardCare.self, key: "difficult-care.\(cardID)")
                let stats = try await value.asyncComparison(db: store.db)
                try Task.checkCancellation()
                care = value; comparison = stats
                if !loaded { reason = value?.reason ?? .split; note = value?.note ?? "" }
                loaded = true; error = nil
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    private func rate(_ count: Int, _ total: Int) -> String {
        total == 0 ? "暂无评分" : String(format: "%.0f%%", Double(count) / Double(total) * 100)
    }
    private func saveIfChanged() {
        guard loaded, generation == store.growthGeneration, !store.fullBackupBusy,
              reason != (care?.reason ?? .split) || note != (care?.note ?? "") else { return }
        persist()
    }
    private func persist(startTracking: Bool = false, toggleResolved: Bool = false) {
        guard generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do {
            care = try store.db.saveCare(cardID:cardID,reason:reason,note:note,startTracking:startTracking,toggleResolved:toggleResolved)
            store.journeyRevision += 1; error = nil
        } catch { self.error = error.localizedDescription; store.errorMessage = self.error }
    }

}
private extension Optional where Wrapped == DifficultCardCare {
    func asyncComparison(db: AppDatabase) async throws -> CardCareComparison? {
        guard let value = self else { return nil }
        return try await db.cardCareComparison(value)
    }
}

struct DifficultCareHistoryView: View {
    @Environment(LibraryStore.self) private var store
    private var page: Int { get { store.journeyNavigation.carePage } nonmutating set { store.journeyNavigation.carePage = newValue } }
    @State private var records = GrowthPage<(DifficultCardCare,String)>(items: [], total: 0)
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("查看近30天难卡，开始处理") { store.learningExplorer = .init(route: .difficult) }
            Text("保存过的处理记录会一直保留，包括暂缓和已解决的卡片。观察以正式评分为准，额外练习不会计入。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if records.items.isEmpty { Text("暂无处理记录。从难卡中选择一张，展开“困难卡处理与跟踪”开始。").foregroundStyle(.secondary) }
                    ForEach(records.items, id: \.0.cardID) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Markdown.plainText(fromHTML: Card.renderHTML(item.1))).lineLimit(3)
                                Text("\(item.0.reason.title) · \(item.0.resolvedAt != nil ? "已解决" : item.0.adjustedAt == nil ? "待调整" : "观察中")").font(.caption)
                                Button("查看卡片／编辑") { store.learningExplorer = .init(route: .document(.init(kind: .card, recordID: item.0.cardID),"")) }
                                DifficultCarePanel(cardID: item.0.cardID)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                }
            }
            JourneyPager(page: Binding(get:{ page },set:{ page = $0 }), total: records.total)
        }.task(id: "\(page)|\(store.revision)|\(store.journeyRevision)") {
            do { let value = try await store.db.difficultCareList(offset: page*50); try Task.checkCancellation(); records = value; error = nil; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
