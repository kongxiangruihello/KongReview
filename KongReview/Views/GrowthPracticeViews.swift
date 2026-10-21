import SwiftUI

struct WeeklySchedulesView: View {
    @Environment(LibraryStore.self) private var store
    @State private var page = 0
    @State private var result = GrowthPage<WeeklySchedule>(items:[],total:0)
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("新建学习计划时勾选“每周重复”。每个安排最多保留一项待办，漏做期间不补建多周记录；跳过本次请在待办中操作。暂停不删除当前待办，恢复后从下一个重复日期继续。").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    ForEach(result.items) { item in
                        GroupBox {
                            VStack(alignment:.leading,spacing:8) {
                                Text(RichText.attributed(item.title)).textSelection(.enabled)
                                Text("每周" + ["日","一","二","三","四","五","六"][max(0,min(6,item.weekday-1))] + (item.paused ? " · 已暂停" : " · 正在重复")).foregroundStyle(.secondary)
                                if let link = item.link { Text("关联：" + link.title).lineLimit(2) }
                                Button(item.paused ? "恢复重复" : "暂停重复") {
                                    do { try store.db.setWeeklySchedulePaused(id:item.id,paused:!item.paused); store.journeyRevision += 1 }
                                    catch { self.error = error.localizedDescription }
                                }.disabled(store.fullBackupBusy)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                        }
                    }
                    if result.items.isEmpty { Text("还没有重复安排，可从学习计划中新建。").foregroundStyle(.secondary) }
                }
            }
            JourneyPager(page:$page,total:result.total)
        }.task(id:"\(page)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.weeklySchedules(offset:page*50); try Task.checkCancellation(); result = value; error = nil; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct LearningOutcomesView: View {
    @Environment(LibraryStore.self) private var store
    @State private var result = GrowthPage<LearningPlan>(items:[],total:0)
    @State private var error: String?
    @State private var loading = false
    @State private var editing: LearningPlan?
    @State private var anchor: String?
    var body: some View {
        @Bindable var nav = store.journeyNavigation
        VStack(alignment:.leading,spacing:12) {
            Text("汇集已完成计划中填写的收获或关联成果，按完成日期排序。专题筛选采用当前资料归属；同一成果在一个专题内只计一次。").font(.caption).foregroundStyle(.secondary)
            TextField("搜索计划或收获（支持繁简）",text:$nav.outcomesQuery).textFieldStyle(.roundedBorder)
            Picker("专题",selection:$nav.outcomesNotebookID) {
                Text("全部专题").tag(Optional<Int64>.none)
                ForEach(store.notebooks) { item in Text(item.title).tag(item.id) }
            }
            Toggle("按完成日期筛选",isOn:$nav.outcomesUseDates)
            if nav.outcomesUseDates {
                HStack { DatePicker("从",selection:$nav.outcomesStart,displayedComponents:.date); DatePicker("至",selection:$nav.outcomesEnd,displayedComponents:.date) }
                if Calendar.current.startOfDay(for:nav.outcomesStart) > Calendar.current.startOfDay(for:nav.outcomesEnd) { Text("开始日期不能晚于结束日期。").foregroundStyle(.red) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(result.items) { plan in
                        GroupBox {
                            VStack(alignment:.leading,spacing:8) {
                                Text(RichText.attributed(plan.title)).font(.headline).textSelection(.enabled)
                                Text(plan.completedAt?.formatted(date:.abbreviated,time:.omitted) ?? "").font(.caption).foregroundStyle(.secondary)
                                if let outcome = plan.outcome {
                                    DisclosureGroup("阅读收获") { PlanOutcomeSummary(outcome:outcome) }
                                    Text(RichText.attributed(outcome.gains)).lineLimit(3)
                                }
                                HStack {
                                    Button("补充收获") { anchor = plan.id.uuidString; editing = plan }
                                    if let link = plan.link { Button("打开关联资料") { anchor = plan.id.uuidString; store.openLearningPlanLink(link) } }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                        }.id(plan.id.uuidString)
                    }
                    if result.items.isEmpty && !loading { Text("暂无符合条件的成果。完成计划时可记录收获，也可以给已完成计划补充收获。").foregroundStyle(.secondary) }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page:$nav.outcomesPage,total:result.total).disabled(loading)
        }.sheet(item:$editing) { plan in PlanOutcomeForm(plan:plan) { editing = nil }.environment(store) }
        .onChange(of:anchor) { _,value in nav.anchors["outcomes"] = value }
        .onChange(of:filterKey) { _,_ in nav.outcomesPage = 0; anchor = nil; nav.anchors["outcomes"] = nil }
        .task(id:"\(filterKey)|\(nav.outcomesPage)|\(store.journeyRevision)|\(store.revision)|\(store.growthGeneration)") {
            loading = true
            do {
                let start = nav.outcomesUseDates ? Calendar.current.startOfDay(for:nav.outcomesStart) : nil
                let end = nav.outcomesUseDates ? Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:nav.outcomesEnd)) : nil
                let value = try await store.db.learningOutcomes(query:nav.outcomesQuery,notebookID:nav.outcomesNotebookID,start:start,end:end,offset:nav.outcomesPage*50)
                try Task.checkCancellation(); result = value; error = nil; loading = false
                if nav.outcomesPage > 0 && value.items.isEmpty { nav.outcomesPage = max(0,(value.total-1)/50) }
                if anchor == nil { anchor = nav.anchors["outcomes"] }
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
    private var filterKey: String { let n = store.journeyNavigation; return "\(n.outcomesQuery)|\(n.outcomesNotebookID ?? -1)|\(n.outcomesUseDates)|\(n.outcomesStart)|\(n.outcomesEnd)" }
}

struct PeriodReflectionGuide: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    let summary: GrowthSummary
    @State private var facts = PeriodReviewFacts(completed:0,outcomes:0,solvedQuestions:0)
    @State private var error: String?
    var body: some View {
        GrowthBox(title: window.period == .year ? "年度复盘引导" : "月度复盘引导", quote: true) {
            VStack(alignment:.leading,spacing:10) {
                Text("本期学习 \(summary[.days]) 天，回顾 \(summary[.highlights]) 条摘录，学习 \(summary[.cards]) 张卡片；完成 \(facts.completed) 项计划，留下 \(facts.outcomes) 项成果，解决 \(facts.solvedQuestions) 个问题。")
                Text("① 哪些理解加深了？结合下方完成计划与成果，填写“收获”。\n② 哪些问题仍未解决？回看问题簿，填写“困难”。\n③ 下一阶段关注什么？填写“下一步”，再转成具体计划。").fixedSize(horizontal:false,vertical:true)
                HStack {
                    Button("查看本期成果") {
                        let n = store.journeyNavigation
                        n.outcomesUseDates = true; n.outcomesStart = window.start; n.outcomesEnd = window.end.addingTimeInterval(-1)
                        n.outcomesQuery = ""; n.outcomesNotebookID = nil; n.outcomesPage = 0; n.anchors["outcomes"] = nil; n.tab = 7
                    }
                    Button("已解决的问题") { store.openQuestionBook(QuestionFilter(state: .solved)) }
                    Button("未解决的问题") { store.openQuestionBook(QuestionFilter(state: .unsolved)) }
                }
                Text("数字来自已有记录，理解程度由你判断。问题按当前已解决状态及解决日期计入，重新打开的问题不再计入；记录删除或撤销完成后统计会相应变化。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(10)
        }.task(id:"\(window.key)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.periodReviewFacts(window:window); try Task.checkCancellation(); facts = value; error = nil }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct EvidenceChooser: View {
    @Environment(LibraryStore.self) private var store
    let select: (PlanEvidence) -> Void
    @State private var kind: PlanEvidence.Kind = .highlight
    @State private var query = ""
    @State private var page = 0
    @State private var result = GrowthPage<PlanEvidence>(items:[],total:0)
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Picker("资料类型",selection:$kind) { Text("摘录").tag(PlanEvidence.Kind.highlight); Text("文字笔记").tag(PlanEvidence.Kind.block); Text("记忆卡").tag(PlanEvidence.Kind.card) }.pickerStyle(.segmented)
            TextField("搜索关联资料",text:$query).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(result.items) { item in Button { select(item) } label: { Text(item.title).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).handCursor() }
                    if result.items.isEmpty && !loading { Text("没有匹配的资料").foregroundStyle(.secondary) }
                }
            }.frame(height:180)
            JourneyPager(page:$page,total:result.total).disabled(loading)
        }.onChange(of:kind) { _,_ in page = 0 }.onChange(of:query) { _,_ in page = 0 }
        .task(id:"\(kind)|\(query)|\(page)|\(store.growthGeneration)") {
            loading = true
            do { try await Task.sleep(for:.milliseconds(180)); let value = try await store.db.evidenceChoices(kind:kind,query:query,offset:page*50); try Task.checkCancellation(); result = value; error = nil; loading = false; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}

/// 4.1.1：专题页“问题与解答”——问题簿中归入本专题的问题（数据在问题簿，入口保留）
struct TopicQuestionsView: View {
    @Environment(LibraryStore.self) private var store
    let notebookID: Int64
    private var solved: Bool { get { store.journeyNavigation.questionSolved[notebookID] ?? false } nonmutating set { store.journeyNavigation.questionSolved[notebookID] = newValue } }
    private var query: String { get { store.journeyNavigation.questionQueries[notebookID] ?? "" } nonmutating set { store.journeyNavigation.questionQueries[notebookID] = newValue } }
    private var page: Int { get { store.journeyNavigation.questionPages[notebookID] ?? 0 } nonmutating set { store.journeyNavigation.questionPages[notebookID] = newValue } }
    @State private var anchor: Int64?
    @State private var result = GrowthPage<QuestionSummary>(items:[],total:0)
    @State private var drafts: [QuestionDraft] = []
    @State private var error: String?
    @State private var loading = false
    private var filter: QuestionFilter { QuestionFilter(state: solved ? .solved : .unsolved, query: query, notebookID: notebookID) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("状态",selection:Binding(get:{solved},set:{solved=$0})) { Text("待解决").tag(false); Text("已解决").tag(true) }.pickerStyle(.segmented)
                Button("记录问题") { store.newQuestion(notebookID:notebookID) }
                Button("在问题簿中查看") { store.openQuestionBook(QuestionFilter(state: solved ? .solved : .unsolved, notebookID: notebookID)) }
            }
            TextField("搜索问题、说明或解答",text:Binding(get:{query},set:{query=$0})).textFieldStyle(.roundedBorder)
            Text("问题收在问题簿里：一个问题可同时归入几个专题与项目，可挂多条材料。这里列出归入本专题的问题。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    if !drafts.isEmpty {
                        DisclosureGroup("未保存的输入 · \(drafts.count)") {
                            ForEach(drafts) { d in QuestionDraftRow(draft:d) }
                        }
                    }
                    ForEach(result.items) { item in QuestionRow(q:item).id(item.id) }
                    if result.items.isEmpty && !loading { Text(solved ? "还没有已解决的问题。" : "暂时没有待解决的问题。").foregroundStyle(.secondary) }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page:Binding(get:{page},set:{page=$0}),total:result.total).disabled(loading)
        }
        .onChange(of:anchor) { _,value in store.journeyNavigation.anchors["questions.\(notebookID)"] = value.map(String.init) }
        .onChange(of:solved) { _,_ in page = 0; anchor = nil; store.journeyNavigation.anchors["questions.\(notebookID)"] = nil }
        .onChange(of:query) { _,_ in page = 0; anchor = nil; store.journeyNavigation.anchors["questions.\(notebookID)"] = nil }
        .task(id:"\(notebookID)|\(solved)|\(query)|\(page)|\(store.questionRevision)|\(store.journeyRevision)|\(store.growthGeneration)") {
            loading = true
            do {
                let value = try await store.db.questionPage(filter,offset:page*50); try Task.checkCancellation()
                result = value; error = nil; loading = false
                if anchor == nil { anchor = store.journeyNavigation.anchors["questions.\(notebookID)"].flatMap { Int64($0) } }
                if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) }
                drafts = try store.db.questionDrafts(notebookID:notebookID)
            }
            catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}
