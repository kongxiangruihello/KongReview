import SwiftUI
import KongReviewCore

/// 3.14：个人成长按“三部分、九节”组织，左侧为目录，右侧为当前一节；窄窗口时目录收为菜单。
struct GrowthSectionInfo: Identifiable {
    let tab: Int
    let number: String
    let title: String
    let lead: String
    var id: Int { tab }
}

struct GrowthPart: Identifiable {
    let number: String
    let title: String
    let sections: [GrowthSectionInfo]
    var id: String { number }

    static let all: [GrowthPart] = [
        GrowthPart(number: "一", title: "回顾与总结", sections: [
            .init(tab: 0, number: "1.1", title: "学习小结", lead: "按日、周、月、年汇总回顾与学习数据，与上期同期比较，并记录目标与复盘。"),
            .init(tab: 3, number: "1.2", title: "成长趋势", lead: "近 30 天、12 周或 12 个月的学习量变化；点击柱形或日期查看当期明细。"),
            .init(tab: 4, number: "1.3", title: "复盘历史", lead: "按周期查找以往的小结与复盘，打开后回到对应周期的学习小结。"),
        ]),
        GrowthPart(number: "二", title: "计划与执行", sections: [
            .init(tab: 5, number: "2.1", title: "学习计划", lead: "待办、已完成与已取消的学习计划；完成时可记录收获与成果。"),
            .init(tab: 8, number: "2.2", title: "重复安排", lead: "按星期自动生成的学习计划，可暂停或恢复。"),
            .init(tab: 6, number: "2.3", title: "难卡跟踪", lead: "反复重来的卡片的处理记录与后续观察。"),
        ]),
        GrowthPart(number: "三", title: "成果与资料", sections: [
            .init(tab: 7, number: "3.1", title: "我的成果", lead: "完成计划时留下的收获与成果，可按专题和日期筛选。"),
            .init(tab: 1, number: "3.2", title: "专题学习", lead: "以专题笔记本为单位，汇总相关摘录、卡片、出处与专题问题。"),
            .init(tab: 2, number: "3.3", title: "资料导出", lead: "按专题或出处导出原文、按语与卡片问答，生成 Markdown 或 PDF 讲义。"),
        ]),
    ]

    static func section(for tab: Int) -> (part: GrowthPart, section: GrowthSectionInfo) {
        for part in all { if let s = part.sections.first(where: { $0.tab == tab }) { return (part, s) } }
        return (all[0], all[0].sections[0])
    }
}

struct GrowthView: View {
    @Environment(LibraryStore.self) private var store
    private var period: GrowthPeriod { get { store.journeyNavigation.period } nonmutating set { store.journeyNavigation.period = newValue } }
    private var date: Date { get { store.journeyNavigation.date } nonmutating set { store.journeyNavigation.date = newValue } }
    private var tab: Int { get { store.journeyNavigation.tab } nonmutating set { store.journeyNavigation.tab = newValue } }
    private var notebookID: Int64? { get { store.journeyNavigation.selectedNotebookID } nonmutating set { store.journeyNavigation.selectedNotebookID = newValue } }

    var body: some View {
        let _ = store.journeyRevision
        let _ = store.today
        GeometryReader { geometry in
            let wide = geometry.size.width >= 860
            HStack(alignment: .top, spacing: 0) {
                if wide {
                    contents.frame(width: 210)
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(compact: !wide)
                    sectionBody
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(ReviewPalette.page).navigationTitle("个人成长")
    }

    // MARK: 目录

    private var contents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("个人成长").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("目　录").font(AcademicType.note).tracking(2).foregroundStyle(ReviewPalette.sub)
                }
                ForEach(GrowthPart.all) { part in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(part.number)、\(part.title)").font(AcademicType.subsection).foregroundStyle(ReviewPalette.ink)
                            .padding(.bottom, 2)
                        ForEach(part.sections) { section in
                            Button { tab = section.tab } label: {
                                HStack(spacing: 8) {
                                    Text(section.number).monospacedDigit().foregroundStyle(ReviewPalette.sub)
                                    Text(section.title).foregroundStyle(tab == section.tab ? ReviewPalette.accent : ReviewPalette.ink)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 13, weight: tab == section.tab ? .semibold : .regular))
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .background(tab == section.tab ? ReviewPalette.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).handCursor()
                            .padding(.leading, 6)
                        }
                    }
                }
                Text("统计反映投入与记录，不替代对理解程度的判断。")
                    .font(AcademicType.note).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 18).padding(.vertical, 24)
        }
        .background(ReviewPalette.soft)
    }

    /// 窄窗口：目录收为分组菜单
    private var contentsMenu: some View {
        Picker("目录", selection: Binding(get: { tab }, set: { tab = $0 })) {
            ForEach(GrowthPart.all) { part in
                Section("\(part.number)、\(part.title)") {
                    ForEach(part.sections) { Text("\($0.number)　\($0.title)").tag($0.tab) }
                }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    // MARK: 节标题

    private func sectionHeader(compact: Bool) -> some View {
        let info = GrowthPart.section(for: tab)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("第\(info.part.number)部分　\(info.part.title)").font(AcademicType.note).tracking(1).foregroundStyle(ReviewPalette.sub)
                Spacer()
                if compact { contentsMenu }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(info.section.number).font(.system(size: 22, weight: .semibold, design: .serif)).monospacedDigit().foregroundStyle(ReviewPalette.sub)
                Text(info.section.title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
            }
            Text(info.section.lead).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(ReviewPalette.ink.opacity(0.6)).frame(height: 1).padding(.top, 6)
        }
    }

    // MARK: 各节内容

    @ViewBuilder
    private var sectionBody: some View {
        if tab == 0 {
            HStack(spacing: 12) {
                Picker("周期", selection: Binding(get: { period }, set: { period = $0 })) { ForEach(GrowthPeriod.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 360)
                DatePicker("日期", selection: Binding(get: { date }, set: { date = $0 }), in: ...Date(), displayedComponents: .date)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            let window = period.window(containing: date)
            GrowthReportView(window: window).id("\(window.key)|\(store.growthGeneration)")
        } else if tab == 1 {
            Picker("选择专题", selection: Binding(get:{ notebookID },set:{ notebookID = $0 })) {
                Text("请选择专题笔记本").tag(Optional<Int64>.none)
                ForEach(store.notebooks) { notebook in Text(notebook.title).tag(notebook.id) }
            }
            .frame(maxWidth: 420)
            if let id = notebookID { TopicLearningView(notebookID: id).id("\(id)|\(store.growthGeneration)") }
            else { ContentUnavailableView("选择一个专题开始", systemImage: "books.vertical", description: Text("专题使用已有笔记本，摘录、卡片和出处会自动关联。")) }
        } else if tab == 3 { GrowthTrendsView() }
        else if tab == 4 { GrowthHistoryView { entry in period = entry.period; date = entry.date; tab = 0 } }
        else if tab == 5 { LearningPlansView().id(store.growthGeneration) }
        else if tab == 7 { LearningOutcomesView().id(store.growthGeneration) }
        else if tab == 8 { WeeklySchedulesView().id(store.growthGeneration) }
        else if tab == 6 { DifficultCareHistoryView() }
        else { LearningMaterialExportView() }
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
    /// 3.15：学习质量与焦点进展
    @State private var quality = GrowthQuality()
    @State private var previousQuality = GrowthQuality()
    @State private var focusProgress: FocusProgress?
    /// 4.0：写作量（全库本期、上期同期）与当前项目本期的写作、阶段变化
    @State private var writingNow = WritingSummary()
    @State private var writingBefore = WritingSummary()
    @State private var projectWriting: WritingSummary?
    @State private var projectStages: [ResearchProjectStageEvent] = []
    var body: some View {
        ScrollView {
            AcademicPaper {
                HStack {
                    Spacer()
                    Menu("导出") {
                        Button("本期小结（Markdown）…") { LearningMaterialExport.saveSummary(window: window, summary: current, reflection: reflection, store: store) }
                        Button("本期札记：收藏与按语（Markdown）…") { LearningMaterialExport.saveNotebook(window: window, store: store) }
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                }
                .padding(.bottom, -18)
                AcademicTitleBlock(title: "\(window.period.title)学习小结", subtitle: periodLabel,
                                   note: window.end < window.fullEnd ? "本期尚未结束，与上一周期相同日数及时间范围比较。" : "完整周期，与上一完整周期比较。")
                if let error { Text(error).foregroundStyle(.red) }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
                overviewSection
                AcademicDivider()
                qualitySection
                AcademicDivider()
                distributionSection
                AcademicDivider()
                focusSection
                AcademicDivider()
                goalsSection
                AcademicDivider()
                reflectionSection
                AcademicDivider()
                plansSection
                AcademicDivider()
                appendixSection
            }
            .environment(\.academicEmbedded, true)
            .padding(.vertical, 8)
        }
        .task(id: store.revision) {
            do {
                async let a = store.db.growthSummary(start: window.start, end: window.end)
                async let b = store.db.growthSummary(start: window.previousStart, end: window.previousEnd)
                let (first,second) = try await (a,b)
                try Task.checkCancellation(); current = first; previous = second
                async let q1 = store.db.growthQuality(start: window.start, end: window.end)
                async let q2 = store.db.growthQuality(start: window.previousStart, end: window.previousEnd)
                let (thisQuality, lastQuality) = try await (q1, q2)
                try Task.checkCancellation(); quality = thisQuality; previousQuality = lastQuality
                async let w1 = store.db.writingSummary(start: window.start, end: window.end)
                async let w2 = store.db.writingSummary(start: window.previousStart, end: window.previousEnd)
                let (thisWriting, lastWriting) = try await (w1, w2)
                try Task.checkCancellation(); writingNow = thisWriting; writingBefore = lastWriting
                if let focus = store.learningFocus {
                    let progress = try await store.db.focusProgress(focus, start: window.start, end: window.end)
                    try Task.checkCancellation(); focusProgress = progress
                    if focus.kind == .project {
                        let w = try await store.db.projectWritingSummary(projectId: focus.id, start: window.start, end: window.end)
                        let stages = try await store.db.researchProjectStages(projectId: focus.id, start: window.start, end: window.end)
                        try Task.checkCancellation(); projectWriting = w; projectStages = stages
                    } else { projectWriting = nil; projectStages = [] }
                } else { focusProgress = nil; projectWriting = nil; projectStages = [] }
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

    // MARK: 版式各节

    private var periodLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        let t = DateFormatter(); t.locale = Locale(identifier: "zh_CN"); t.dateFormat = "yyyy年M月d日 HH:mm"
        let lastDay = window.end.addingTimeInterval(-1)
        if window.period == .day { return f.string(from: window.start) + (window.end < window.fullEnd ? "（截至 \(t.string(from: window.end).suffix(5))）" : "") }
        return f.string(from: window.start) + " — " + (window.end < window.fullEnd ? t.string(from: window.end) : f.string(from: lastDay))
    }

    private func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : (n < 0 ? "−\(-n)" : "0") }

    private func rate(_ now: Int, _ before: Int) -> String {
        guard before > 0 else { return now > 0 ? "新增" : "—" }
        let r = Double(now - before) / Double(before) * 100
        return (r > 0 ? "+" : (r < 0 ? "−" : "")) + String(format: "%.0f%%", abs(r))
    }

    /// 一、数据概览：表 1 本期与上期同期比较（点选一行，第三节与附录随之切换）
    private var overviewSection: some View {
        AcademicSection(number: "一", title: "数据概览",
                        lead: "表 1 列出本期各项学习数据及其与上期同期的比较。点选任一行，第三节“内容分布”与附录“本期明细”改为显示该项。") {
            AcademicTable(label: "表 1", title: "本期学习数据与上期同期比较",
                          note: "摘录和卡片在整个周期内分别去重；同一卡片的多次评分另计。难卡指本周期至少 3 次重来。新增数来自仍保存在库中的创建记录，永久删除后无法追溯。写作为专题笔记本中自写文字（文字、小标题、本文批注）的新增字数与项目页手记之和，中文逐字、西文按词；写作两行不可点选。“▸”为当前选中的一项。") {
                Text("指标")
                Text("本期").gridColumnAlignment(.trailing)
                Text("上期同期").gridColumnAlignment(.trailing)
                Text("增减").gridColumnAlignment(.trailing)
                Text("变化率").gridColumnAlignment(.trailing)
            } rows: {
                ForEach(GrowthMetric.allCases) { item in
                    let on = metric == item
                    GridRow {
                        HStack(spacing: 6) {
                            Text(on ? "▸" : "　").foregroundStyle(ReviewPalette.accent)
                            Text(item.title)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(current[item])").fontWeight(.semibold)
                        Text("\(previous[item])").foregroundStyle(ReviewPalette.sub)
                        Text(signed(current[item] - previous[item]))
                        Text(rate(current[item], previous[item])).foregroundStyle(ReviewPalette.sub)
                    }
                    .monospacedDigit()
                    .foregroundStyle(on ? ReviewPalette.accent : ReviewPalette.ink)
                    .academicCell()
                    .contentShape(Rectangle())
                    .onTapGesture { metric = item; page = 0 }
                    .handCursor()
                }
                writingRow("写作（字）", writingNow.added, writingBefore.added)
                writingRow("写作天数", writingNow.days, writingBefore.days)
            }
        }
    }

    private func writingRow(_ title: String, _ now: Int, _ before: Int) -> some View {
        GridRow {
            HStack(spacing: 6) { Text("　"); Text(title) }.frame(maxWidth: .infinity, alignment: .leading)
            Text("\(now)").fontWeight(.semibold)
            Text("\(before)").foregroundStyle(ReviewPalette.sub)
            Text(signed(now - before))
            Text(rate(now, before)).foregroundStyle(ReviewPalette.sub)
        }
        .monospacedDigit()
        .foregroundStyle(ReviewPalette.ink)
        .academicCell()
    }

    /// 三、内容分布：表 3 当前指标按出处、专题或牌组分布
    private var distributionSection: some View {
        AcademicSection(number: "三", title: "内容分布",
                        lead: metric == .days ? "“学习天数”按日期计数，不按出处汇总；逐日记录见附录。"
                                              : "表 3 按资料当前的归属，汇总本期“\(metric.title)”的来源，回答“本期主要学了什么”。") {
            if metric != .days {
                GrowthBreakdownView(window: window, metric: metric, total: current[metric]).id("\(window.key)|\(metric)")
            }
        }
    }

    private func percent(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

    private func percentDelta(_ now: Double?, _ before: Double?) -> String {
        guard let now, let before else { return "—" }
        let d = (now - before) * 100
        return abs(d) < 0.5 ? "0" : (d > 0 ? "+" : "−") + String(format: "%.0f", abs(d)) + " 个百分点"
    }

    /// 二、学习质量：表 2，从“做了多少”到“学得怎样”
    private var qualitySection: some View {
        AcademicSection(number: "二", title: "学习质量",
                        lead: "表 2 从记忆、筛选与转化三方面看本期学得怎样。数字只反映记录，理解程度仍需自己判断。") {
            AcademicTable(label: "表 2", title: "本期学习质量指标",
                          note: "记忆卡保留率：本期对已进入复习阶段的卡片评分中，非“重来”所占比例（新卡和学习步骤不计；旧版记录缺少评分前状态的不计）。回顾筛选率：本期回顾的摘录中，收藏、弃置或写了按语的比例（同一条只计一次，本期收藏 \(quality.favorited)、弃置 \(quality.discarded)、写按语 \(quality.noted) 条）。摘录转卡率：本期新增摘录中已做成记忆卡的比例。") {
                Text("指标")
                Text("本期").gridColumnAlignment(.trailing)
                Text("上期同期").gridColumnAlignment(.trailing)
                Text("变化").gridColumnAlignment(.trailing)
                Text("依据").gridColumnAlignment(.trailing)
            } rows: {
                qualityRow("记忆卡保留率", percent(quality.retention), percent(previousQuality.retention),
                           percentDelta(quality.retention, previousQuality.retention), "\(quality.reviewRatings) 次复习评分")
                qualityRow("反复重来的卡片", "\(current[.difficult])", "\(previous[.difficult])",
                           signed(current[.difficult] - previous[.difficult]), "≥3 次重来")
                qualityRow("回顾筛选率", percent(quality.curationRate), percent(previousQuality.curationRate),
                           percentDelta(quality.curationRate, previousQuality.curationRate),
                           "\(quality.curated) / \(quality.reviewed) 条")
                    .help("收藏 \(quality.favorited) 条、弃置 \(quality.discarded) 条、写按语 \(quality.noted) 条；同一条做了几项只计一次")
                qualityRow("摘录转卡率", percent(quality.cardingRate), percent(previousQuality.cardingRate),
                           percentDelta(quality.cardingRate, previousQuality.cardingRate), "\(quality.newHighlightsCarded) / \(quality.newHighlights) 条")
            }
        }
    }

    private func qualityRow(_ title: String, _ now: String, _ before: String, _ change: String, _ basis: String) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(now).fontWeight(.semibold)
            Text(before).foregroundStyle(ReviewPalette.sub)
            Text(change)
            Text(basis).font(AcademicType.note).foregroundStyle(ReviewPalette.sub).lineLimit(1).fixedSize()
        }
        .monospacedDigit()
        .academicCell()
    }

    /// 四、焦点进展：表 4；在这里设定或更换本期焦点
    private var focusSection: some View {
        AcademicSection(number: "四", title: "项目进展",
                        lead: "设定当前研究项目后，全库回顾会更常抽到项目材料中的摘录，记忆卡也优先出现其卡片；这一节报告本期在当前项目上的进展。",
                        trailing: AnyView(focusMenu)) {
            if let focus = store.learningFocus, let p = focusProgress {
                AcademicTable(label: "表 4", title: focus.kind == .project ? "当前\(focus.label)的进展" : "本期焦点\(focus.label)的进展",
                              note: "自 \(focus.startedAt.formatted(date: .abbreviated, time: .omitted)) 起生效。\(focus.kind == .project ? "材料为项目中全部专题笔记本与出处的摘录（去重）。" : "")回顾抽样中这些摘录的权重为平时的 \(Int(ReviewBias.focusBoost)) 倍；记忆卡在同为可学时优先其卡片，不突破每日上限。") {
                    Text("指标")
                    Text("本期").gridColumnAlignment(.trailing)
                    Text("材料总量").gridColumnAlignment(.trailing)
                    Text("覆盖").gridColumnAlignment(.trailing)
                } rows: {
                    focusRow("回顾过的摘录（条）", p.reviewedHighlights, p.totalHighlights)
                    focusRow("学习过的卡片（张）", p.studiedCards, p.totalCards)
                    focusRow("写按语（条）", p.notes, p.totalHighlights)
                    focusRow("新增摘录（条）", p.newHighlights, nil)
                    if let w = projectWriting { focusRow("写作（字）", w.added, nil) }
                }
                if focus.kind == .project {
                    Text(projectStages.isEmpty ? "本期阶段未变化。"
                         : "本期阶段变化：" + projectStages.map { "\($0.at.formatted(.dateTime.month().day())) 进入“\($0.stage.title)”" }.joined(separator: "；") + "。")
                        .font(AcademicType.body).foregroundStyle(ReviewPalette.ink)
                }
            } else {
                Text(store.researchProjects.isEmpty ? "还没有研究项目。点右上角菜单新建一个，再把专题笔记本和出处归进来。" : "尚未设定当前项目。点右上角菜单，从在研项目中选一个。")
                    .font(AcademicType.body).foregroundStyle(ReviewPalette.sub)
            }
        }
    }

    private func focusRow(_ title: String, _ value: Int, _ total: Int?) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(value)").fontWeight(.semibold)
            Text(total.map(String.init) ?? "—").foregroundStyle(ReviewPalette.sub)
            Text(total.flatMap { $0 > 0 ? String(format: "%.0f%%", Double(value) / Double($0) * 100) : nil } ?? "—")
        }
        .monospacedDigit()
        .academicCell()
    }

    private var focusMenu: some View {
        Menu(store.learningFocus == nil ? "设为当前项目…" : "更换当前项目…") {
            Section("在研项目") {
                ForEach(store.researchProjects) { p in
                    Button { store.setCurrentProject(p) } label: {
                        if p.id == store.currentProjectID { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
            }
            Divider()
            Button("新建项目…") { store.newResearchProject() }
            if let id = store.currentProjectID { Button("打开当前项目") { store.selection = .project(id) } }
            if store.learningFocus != nil {
                Button("取消当前项目") { store.setLearningFocus(nil) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(store.fullBackupBusy)
    }

    /// 五、目标与达成：表 5
    private var goalsSection: some View {
        AcademicSection(number: "五", title: "目标与达成",
                        lead: "为本期设定回顾与学习的数量目标；目标为 0 表示暂不设定。各周期独立设定，不改变学习排程。") {
            AcademicTable(label: "表 5", title: "本期目标与实际完成") {
                Text("项目")
                Text("目标").gridColumnAlignment(.trailing)
                Text("实际").gridColumnAlignment(.trailing)
                Text("达成").gridColumnAlignment(.trailing)
                Text("进度")
            } rows: {
                goalRow("回顾摘录（条）", goal: $reflection.goalHighlights, actual: current[.highlights])
                goalRow("学习记忆卡（张）", goal: $reflection.goalCards, actual: current[.cards])
            }
            .disabled(!loaded)
        }
    }

    private func goalRow(_ title: String, goal: Binding<Int>, actual: Int) -> some View {
        let g = goal.wrappedValue
        return GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            TextField("0", value: goal, format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 80)
            Text("\(actual)").fontWeight(.semibold)
            Text(g > 0 ? "\(Int((Double(actual) / Double(g) * 100).rounded()))%" : "未设定").foregroundStyle(g > 0 ? ReviewPalette.ink : ReviewPalette.sub)
            DonePendingBar(done: g > 0 ? min(actual, g) : 0, pending: g > 0 ? max(0, g - actual) : 0, height: 5)
                .frame(minWidth: 120, maxWidth: 200)
        }
        .monospacedDigit()
        .academicCell()
    }

    /// 四、复盘：收获、困难、下一步
    private var reflectionSection: some View {
        AcademicSection(number: "六", title: "复盘", lead: "依次写下本期的收获、困难与下一步，内容自动保存。下一阶段想重点读的专题或书，可在第四节设为焦点。") {
            VStack(alignment: .leading, spacing: 18) {
                if window.period == .month || window.period == .year { PeriodReflectionGuide(window: window, summary: current) }
                VStack(alignment: .leading, spacing: 8) {
                    AcademicSubheading(number: "6.1", title: "本期收获", hint: "哪些理解加深了")
                    RichEditor(text:$reflection.gains,placeholder:"本期收获",autoHeight:true,minHeight:90,slot:"growth-gains").richEditorFrame()
                }
                VStack(alignment: .leading, spacing: 8) {
                    AcademicSubheading(number: "6.2", title: "遇到的困难", hint: "哪些问题仍未解决")
                    RichEditor(text:$reflection.challenges,placeholder:"遇到的困难",autoHeight:true,minHeight:90,slot:"growth-challenges").richEditorFrame()
                }
                VStack(alignment: .leading, spacing: 8) {
                    AcademicSubheading(number: "6.3", title: "下一步", hint: "下一阶段关注什么")
                    if let previousReflection, !previousReflection.nextSteps.isEmpty {
                        AcademicQuote(label: "对照：上期写下的“下一步”") {
                            Text(RichText.attributed(previousReflection.nextSteps)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    RichEditor(text:$reflection.nextSteps,placeholder:"下一步",autoHeight:true,minHeight:90,slot:"growth-next").richEditorFrame()
                    Button("把下一步转为学习计划…") {
                        save()
                        planDraft = LearningPlan(title: reflection.nextSteps, originKey: window.key)
                    }.disabled(reflection.nextSteps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || planDraft != nil)
                    if let planDraft { LearningPlanForm(plan: planDraft) { self.planDraft = nil }.id(planDraft.id) }
                }
                if let saveError { Text(saveError).foregroundStyle(.red); Button("重试保存") { save() } }
            }
            .disabled(!loaded)
        }
    }

    /// 五、计划执行
    private var plansSection: some View {
        AcademicSection(number: "七", title: "计划执行",
                        lead: window.period == .week ? "本期完成的学习计划，以及每周复盘中对未完成计划的决定。" : "本期完成的学习计划，按完成日期归入。") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    AcademicSubheading(number: "7.1", title: "本期完成的学习计划")
                    CompletedGrowthPlans(window: window)
                }
                if window.period == .week {
                    VStack(alignment: .leading, spacing: 8) {
                        AcademicSubheading(number: "7.2", title: "每周复盘：决定下一步")
                        WeeklyReviewView(window: window).id(window.key)
                    }
                }
            }
        }
    }

    /// 附录：当前指标的逐条明细
    private var appendixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("附录　本期明细：\(metric.title)").font(AcademicType.section).foregroundStyle(ReviewPalette.ink)
                Spacer()
                Text("共 \(details.total) 项").font(AcademicType.note).foregroundStyle(ReviewPalette.sub).monospacedDigit()
            }
            if detailsLoading { ProgressView() }
            else if details.rows.isEmpty { Text("本期暂无这类记录。").font(AcademicType.body).foregroundStyle(ReviewPalette.sub) }
            else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(details.rows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            if let target = row.target { store.learningExplorer = .init(route: .document(target,"")) }
                            else if metric == .days {
                                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
                                if let day = formatter.date(from: row.title) { store.learningExplorer = .init(route: .day(day)) }
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(page * 50 + index + 1).").font(AcademicType.table).monospacedDigit()
                                    .foregroundStyle(ReviewPalette.sub).frame(width: 34, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title).font(AcademicType.body).foregroundStyle(ReviewPalette.ink).lineLimit(3)
                                    Text(row.detail).font(AcademicType.note).foregroundStyle(ReviewPalette.sub)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(row.target == nil && metric != .days).handCursor()
                        Rectangle().fill(ReviewPalette.hair).frame(height: 1)
                    }
                }
            }
            HStack {
                Text("第 \(page+1) / \(max(1,(details.total+49)/50)) 页").font(AcademicType.note).foregroundStyle(ReviewPalette.sub)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0 || detailsLoading)
                Button("下一页") { page += 1 }.disabled((page+1)*50 >= details.total || detailsLoading)
            }
            .controlSize(.small)
        }
    }

    private func save() {
        guard loaded, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do { try store.db.saveProgress(reflection, key: window.key); saveError = nil; store.journeyRevision += 1 }
        catch { saveError = "复盘尚未保存：" + error.localizedDescription; store.errorMessage = saveError }
    }
}
