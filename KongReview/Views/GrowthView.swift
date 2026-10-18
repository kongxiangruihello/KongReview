import SwiftUI
import KongReviewCore

struct GrowthView: View {
    @Environment(LibraryStore.self) private var store
    private var period: GrowthPeriod { get { store.journeyNavigation.period } nonmutating set { store.journeyNavigation.period = newValue } }
    private var date: Date { get { store.journeyNavigation.date } nonmutating set { store.journeyNavigation.date = newValue } }
    private var tab: Int { get { store.journeyNavigation.tab } nonmutating set { store.journeyNavigation.tab = newValue } }
    private var notebookID: Int64? { get { store.journeyNavigation.selectedNotebookID } nonmutating set { store.journeyNavigation.selectedNotebookID = newValue } }
    var body: some View {
        let _ = store.journeyRevision
        let _ = store.today
        VStack(alignment: .leading, spacing: 16) {
            Text("个人成长").font(.largeTitle.bold())
            Text("回看学习记录，整理收获，安排下一步。统计反映投入与记录，不替代对理解程度的判断。")
                .font(.callout).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                sectionPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                sectionPicker.pickerStyle(.menu)
            }
            if tab == 0 {
                HStack {
                    Picker("周期", selection: Binding(get: { period }, set: { period = $0 })) { ForEach(GrowthPeriod.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    DatePicker("日期", selection: Binding(get: { date }, set: { date = $0 }), in: ...Date(), displayedComponents: .date)
                }
                let window = period.window(containing: date)
                GrowthReportView(window: window).id("\(window.key)|\(store.growthGeneration)")
            } else if tab == 1 {
                Picker("选择专题", selection: Binding(get:{ notebookID },set:{ notebookID = $0 })) {
                    Text("请选择专题笔记本").tag(Optional<Int64>.none)
                    ForEach(store.notebooks) { notebook in Text(notebook.title).tag(notebook.id) }
                }
                if let id = notebookID { TopicLearningView(notebookID: id).id("\(id)|\(store.growthGeneration)") }
                else { ContentUnavailableView("选择一个专题开始", systemImage: "books.vertical", description: Text("专题使用已有笔记本，摘录、卡片和出处会自动关联。")) }
            } else if tab == 3 { GrowthTrendsView() }
            else if tab == 4 { GrowthHistoryView { entry in period = entry.period; date = entry.date; tab = 0 } }
            else if tab == 5 { LearningPlansView().id(store.growthGeneration) }
            else if tab == 7 { LearningOutcomesView().id(store.growthGeneration) }
            else if tab == 8 { WeeklySchedulesView().id(store.growthGeneration) }
            else if tab == 6 { DifficultCareHistoryView() }
            else { LearningMaterialExportView() }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ReviewPalette.page).navigationTitle("个人成长")
    }
    private var sectionPicker: some View {
        Picker("内容", selection: Binding(get: { tab }, set: { tab = $0 })) {
            Text("学习小结").tag(0); Text("成长趋势").tag(3); Text("复盘历史").tag(4)
            Text("学习计划").tag(5); Text("重复安排").tag(8); Text("我的成果").tag(7); Text("难卡跟踪").tag(6); Text("专题学习").tag(1); Text("资料导出").tag(2)
        }
    }
}

struct GrowthReportView: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var current = GrowthSummary()
    @State private var previous = GrowthSummary()
    @State private var reflection = GrowthReflection()
    @State private var loaded = false
    @State private var generation = -1
    @State private var error: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var metric: GrowthMetric = .highlights
    @State private var page = 0
    @State private var details = LearningExplorerPage(rows: [], total: 0)
    @State private var detailsLoading = false
    @State private var previousReflection: GrowthReflection?
    @State private var planDraft: LearningPlan?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(window.period.title)学习小结 · \(window.start.formatted(date: .abbreviated, time: .omitted)) — \(window.end.formatted(date: .abbreviated, time: .shortened))").font(.headline)
                Text(window.end < window.fullEnd ? "本期尚未结束，与上一周期相同日数及时间范围比较。" : "完整周期，与上一完整周期比较。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if !loaded { ProgressView() }
                GrowthMetricGrid(current: current, previous: previous, selected: metric) { metric = $0; page = 0 }
                Text("摘录和卡片在整个周期内分别去重；同一卡片的多次评分另计。难卡指本周期至少3次重来。新增数来自仍保存在库中的创建记录，永久删除后无法追溯。")
                    .font(.caption).foregroundStyle(.secondary)
                GrowthBreakdownView(window: window, metric: metric).id("\(window.key)|\(metric)")
                if window.period == .month || window.period == .year { PeriodReflectionGuide(window:window,summary:current) }
                GroupBox("本期目标与复盘（自动保存）") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("摘录目标（条）"); TextField("0", value: $reflection.goalHighlights, format: .number).frame(width: 90)
                            Text("记忆卡目标（张）"); TextField("0", value: $reflection.goalCards, format: .number).frame(width: 90)
                        }
                        if reflection.goalHighlights > 0 { ProgressView("摘录：\(current[.highlights]) / \(reflection.goalHighlights)", value: Double(min(current[.highlights],reflection.goalHighlights)), total: Double(reflection.goalHighlights)) }
                        if reflection.goalCards > 0 { ProgressView("记忆卡：\(current[.cards]) / \(reflection.goalCards)", value: Double(min(current[.cards],reflection.goalCards)), total: Double(reflection.goalCards)) }
                        Text("目标为0表示暂不设定；各周期独立设定，不改变学习排程。").font(.caption).foregroundStyle(.secondary)
                        RichEditor(text:$reflection.gains,placeholder:"本期收获",autoHeight:true,minHeight:90,slot:"growth-gains").richEditorFrame()
                        RichEditor(text:$reflection.challenges,placeholder:"遇到的困难",autoHeight:true,minHeight:90,slot:"growth-challenges").richEditorFrame()
                        RichEditor(text:$reflection.nextSteps,placeholder:"下一步",autoHeight:true,minHeight:90,slot:"growth-next").richEditorFrame()
                        Button("把下一步转为学习计划…") {
                            save()
                            planDraft = LearningPlan(title: reflection.nextSteps, originKey: window.key)
                        }.disabled(reflection.nextSteps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || planDraft != nil)
                        if let saveError { Text(saveError).foregroundStyle(.red); Button("重试保存") { save() } }
                    }.padding(8).textFieldStyle(.roundedBorder).disabled(!loaded)
                }
                if let planDraft { LearningPlanForm(plan: planDraft) { self.planDraft = nil }.id(planDraft.id) }
                if let previousReflection, !previousReflection.nextSteps.isEmpty {
                    GroupBox("对照上期的下一步") {
                        Text(RichText.attributed(previousReflection.nextSteps)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if window.period == .week { WeeklyReviewView(window:window).id(window.key) }
                CompletedGrowthPlans(window: window)
                HStack {
                    Text("\(metric.title) · \(details.total) 项明细").font(.headline)
                    Spacer()
                    Button("导出本期小结 Markdown…") { LearningMaterialExport.saveSummary(window: window, summary: current, reflection: reflection, store: store) }
                }
                if detailsLoading { ProgressView() }
                else if details.rows.isEmpty { Text("本期暂无这类记录。").foregroundStyle(.secondary) }
                else {
                    ForEach(details.rows) { row in
                        Button {
                            if let target = row.target { store.learningExplorer = .init(route: .document(target,"")) }
                            else if metric == .days {
                                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
                                if let day = formatter.date(from: row.title) { store.learningExplorer = .init(route: .day(day)) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).lineLimit(3)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(row.target == nil && metric != .days).handCursor()
                    }
                }
                HStack {
                    Text("第 \(page+1) / \(max(1,(details.total+49)/50)) 页")
                    Spacer()
                    Button("上一页") { page -= 1 }.disabled(page == 0 || detailsLoading)
                    Button("下一页") { page += 1 }.disabled((page+1)*50 >= details.total || detailsLoading)
                }
            }
        }
        .task(id: store.revision) {
            do {
                async let a = store.db.growthSummary(start: window.start, end: window.end)
                async let b = store.db.growthSummary(start: window.previousStart, end: window.previousEnd)
                let (first,second) = try await (a,b)
                try Task.checkCancellation(); current = first; previous = second
                if !loaded { reflection = try store.db.progressValue(GrowthReflection.self, key: window.key) ?? .init() }
                previousReflection = try store.db.progressValue(GrowthReflection.self, key: window.period.window(containing: window.previousStart).key)
                loaded = true; error = nil
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .task(id: "\(metric)|\(page)|\(store.revision)") {
            detailsLoading = true
            do {
                let result = try await store.db.growthDetails(metric: metric, start: window.start, end: window.end, offset: page*50)
                try Task.checkCancellation(); details = result; detailsLoading = false; if page > 0 && result.rows.isEmpty { page = max(0,(result.total-1)/50) }
            } catch is CancellationError { } catch { self.error = error.localizedDescription; detailsLoading = false }
        }
        .onChange(of: reflection) { _, _ in
            guard loaded else { return }
            reflection.goalHighlights = min(100000,max(0,reflection.goalHighlights))
            reflection.goalCards = min(100000,max(0,reflection.goalCards))
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(400)); save() } catch { }
            }
        }
        .onChange(of: metric) { _,value in store.journeyNavigation.reportMetrics[window.key] = value }
        .onChange(of: page) { _,value in store.journeyNavigation.reportPages[window.key] = value }
        .onAppear {
            metric = store.journeyNavigation.reportMetrics[window.key] ?? .highlights
            page = store.journeyNavigation.reportPages[window.key] ?? 0
            generation = store.growthGeneration
            store.growthFlushKey = window.key
            store.flushGrowthReflection = { if loaded, generation == store.growthGeneration { try store.db.saveProgress(reflection, key: window.key) } }
        }
        .onDisappear { saveTask?.cancel(); save(); if store.growthFlushKey == window.key { store.flushGrowthReflection = nil; store.growthFlushKey = nil } }
    }
    private func save() {
        guard loaded, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do { try store.db.saveProgress(reflection, key: window.key); saveError = nil; store.journeyRevision += 1 }
        catch { saveError = "复盘尚未保存：" + error.localizedDescription; store.errorMessage = saveError }
    }
}

struct GrowthMetricGrid: View {
    let current: GrowthSummary
    let previous: GrowthSummary
    let selected: GrowthMetric
    let onSelect: (GrowthMetric) -> Void
    var body: some View {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    ForEach(GrowthMetric.allCases) { item in
                        Button { onSelect(item) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item.title).font(.callout)
                                Text("\(current[item])").font(.title.bold()).monospacedDigit()
                                Text("上期同期 \(previous[item]) · \(current[item]-previous[item] >= 0 ? "+" : "")\(current[item]-previous[item])")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(selected == item ? ReviewPalette.accentSoft : ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).handCursor()
                    }
                }
    }
}
