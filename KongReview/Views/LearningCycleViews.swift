import SwiftUI

struct DailyArrangementView: View {
    @Environment(LibraryStore.self) private var store
    @State private var highlights = 0
    @State private var cards = 0
    @State private var progress = GrowthSummary()
    @State private var ready = false
    @State private var generation = -1
    @State private var error: String?
    private var day: GrowthWindow { GrowthPeriod.day.window(containing:Date()) }
    var body: some View {
        GroupBox("今日学习安排") {
            VStack(alignment:.leading,spacing:12) {
                ViewThatFits(in:.horizontal) {
                    HStack { goalFields }
                    VStack(alignment:.leading) { goalFields }
                }.textFieldStyle(.roundedBorder).disabled(!ready || store.fullBackupBusy)
                Text("0 表示不设目标。按今日去重记录统计完成量；数量目标仅作提醒，记忆卡仍按原排程学习。").font(.caption).foregroundStyle(.secondary)
                if highlights > 0 { ProgressView("回顾摘录 \(progress[.highlights]) / \(highlights) 条",value:Double(min(progress[.highlights],highlights)),total:Double(highlights)) }
                if cards > 0 { ProgressView("学习记忆卡 \(progress[.cards]) / \(cards) 张",value:Double(min(progress[.cards],cards)),total:Double(cards)) }
                HStack {
                    Button("去今日回顾 · \(store.homeLearningSummary.reviewPendingCount)") { store.openTodayReview() }
                    Button("去学习记忆卡 · \(store.homeLearningSummary.cardsDueCount)") { store.openCardsHome() }
                }.handCursor()
                if let error { Text(error).foregroundStyle(.red); Button("重试保存") { save() } }
            }.padding(10)
        }
        .task(id:"\(day.key)|\(store.revision)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do {
                let value = try await store.db.growthSummary(start:day.start,end:Date()); try Task.checkCancellation()
                let saved = try store.db.progressValue(GrowthReflection.self,key:day.key) ?? .init()
                if !ready { highlights = saved.goalHighlights; cards = saved.goalCards }; progress = value
                generation = store.growthGeneration; ready = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    @ViewBuilder private var goalFields: some View {
        HStack { Text("今天想回顾"); TextField("条数",value:$highlights,format:.number).frame(width:70).accessibilityLabel("今日摘录目标"); Text("条摘录") }
        HStack { Text("想学习"); TextField("张数",value:$cards,format:.number).frame(width:70).accessibilityLabel("今日记忆卡目标"); Text("张记忆卡") }
        Button("保存今日安排") { save() }
    }
    private func save() {
        guard ready, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do { try store.db.saveDailyArrangement(date:Date(),highlights:highlights,cards:cards); highlights = min(100000,max(0,highlights)); cards = min(100000,max(0,cards)); error = nil; store.journeyRevision += 1 }
        catch { self.error = error.localizedDescription }
    }
}

struct PlanOutcomeForm: View {
    @Environment(LibraryStore.self) private var store
    let plan: LearningPlan
    let onClose: () -> Void
    @State private var draft: PlanOutcomeDraft?
    @State private var ready = false
    @State private var closed = false
    @State private var generation = -1
    @State private var choosing = false
    @State private var kind: PlanEvidence.Kind = .highlight
    @State private var query = ""
    @State private var page = 0
    @State private var choices = GrowthPage<PlanEvidence>(items:[],total:0)
    @State private var error: String?
    @State private var discard = false
    private var outcome: Binding<PlanOutcome> { Binding(get:{ draft?.outcome ?? .init() },set:{ draft?.outcome = $0; persist() }) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text(plan.completedAt == nil ? "完成计划 · 记录收获" : "补充计划收获").font(.title2.bold())
                Text(RichText.attributed(plan.title)).textSelection(.enabled)
                RichEditor(text:outcome.gains,placeholder:"收获（选填）",autoHeight:true,minHeight:120,slot:"plan-outcome").richEditorFrame()
                if let evidence = draft?.outcome.evidence {
                    HStack { Text("关联：\(evidence.title)").lineLimit(3); Button("移除") { draft?.outcome.evidence = nil; persist() } }
                }
                Button(choosing ? "收起资料选择" : "关联摘录、笔记或记忆卡…") { choosing.toggle() }
                if choosing {
                    Picker("资料类型",selection:$kind) { Text("摘录").tag(PlanEvidence.Kind.highlight); Text("文字笔记").tag(PlanEvidence.Kind.block); Text("记忆卡").tag(PlanEvidence.Kind.card) }.pickerStyle(.segmented)
                    TextField("搜索资料",text:$query).textFieldStyle(.roundedBorder)
                    ForEach(choices.items) { evidence in
                        Button { draft?.outcome.evidence = evidence; choosing = false; persist() } label: { Text(evidence.title).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).handCursor()
                    }
                    if choices.items.isEmpty { Text("暂无匹配资料").foregroundStyle(.secondary) }
                    JourneyPager(page:$page,total:choices.total)
                }
                Text("收获可以留空；输入自动暂存。暂存后可在计划页再次点“标为完成”或“补充收获”继续。").font(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("保留输入，重新读取计划状态") {
                        do {
                            guard let latest = try store.db.progressValue(LearningPlan.self,key:plan.key), latest.cancelledAt == nil else { throw JourneyError.changedPlan }
                            draft?.original = latest; persist(); self.error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
                HStack {
                    Button(plan.completedAt == nil ? "确认完成" : "保存收获") { finish() }.buttonStyle(.borderedProminent)
                    Button("暂存并关闭") { persist(); if error == nil { closed = true; onClose() } }
                    Button("丢弃本次输入",role:.destructive) { discard = true }
                }
            }.padding(24).disabled(!ready || store.fullBackupBusy || generation != store.growthGeneration)
        }.frame(minWidth:480,idealWidth:620,minHeight:420,idealHeight:600)
        .confirmationDialog("丢弃未保存的收获？计划状态和已保存收获不变。",isPresented:$discard) {
            Button("丢弃本次输入",role:.destructive) {
                do { try store.db.deleteProgress(key:"plan-outcome-draft.\(plan.id.uuidString)"); closed = true; onClose() }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear {
            generation = store.growthGeneration
            do { draft = try store.db.progressValue(PlanOutcomeDraft.self,key:"plan-outcome-draft.\(plan.id.uuidString)") ?? .init(original:plan,outcome:plan.outcome ?? .init()); ready = true }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { persist() }
        .onChange(of:kind) { _,_ in page = 0 }.onChange(of:query) { _,_ in page = 0 }
        .task(id:"\(choosing)|\(kind)|\(query)|\(page)|\(store.growthGeneration)") {
            guard choosing else { return }
            do { try await Task.sleep(for:.milliseconds(180)); let value = try await store.db.evidenceChoices(kind:kind,query:query,offset:page*50); try Task.checkCancellation(); choices = value; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func persist() {
        guard ready, !closed, let draft, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do { try store.db.saveProgress(draft,key:draft.key); error = nil }
        catch { self.error = "收获草稿未能保存：" + error.localizedDescription }
    }
    private func finish() {
        guard let draft, ready, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do { try store.db.finishPlan(draft); closed = true; store.journeyRevision += 1; onClose() }
        catch { self.error = error.localizedDescription }
    }
}

struct PlanOutcomeSummary: View {
    @Environment(LibraryStore.self) private var store
    let outcome: PlanOutcome
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            if !outcome.gains.isEmpty { Text(RichText.attributed("收获：" + outcome.gains)).textSelection(.enabled) }
            if let evidence = outcome.evidence {
                Button("查看成果：\(evidence.title)") { store.openPlanEvidence(evidence) }.lineLimit(3)
            }
        }
    }
}

struct WeeklyReviewView: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var filter: WeeklyPlanFilter = .delayed
    @State private var page = 0
    @State private var result = GrowthPage<LearningPlan>(items:[],total:0)
    @State private var prior = ""
    @State private var adjusting: LearningPlan?
    @State private var nextDate = Date()
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        GroupBox("每周复盘 · 决定下一步") {
            VStack(alignment:.leading,spacing:12) {
                Text("① 回看上周承诺　② 查看本周完成与取消　③ 决定继续、调整日期或放下").font(.callout)
                if !prior.isEmpty { Text("上周的下一步：\n" + prior).textSelection(.enabled) }
                else { Text("上周还没有填写下一步。").foregroundStyle(.secondary) }
                Text("按计划当前状态整理；已结束周展示当周完成／取消记录及目前仍待处理的到期计划，不还原过去的待办状态。").font(.caption).foregroundStyle(.secondary)
                Picker("计划",selection:$filter) { ForEach(WeeklyPlanFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView() }
                ForEach(result.items) { plan in
                    VStack(alignment:.leading,spacing:8) {
                        Text(RichText.attributed(plan.title)).textSelection(.enabled)
                        Text("计划日期 \(plan.dueDate.formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary)
                        if let outcome = plan.outcome, plan.completedAt != nil { PlanOutcomeSummary(outcome:outcome) }
                        if plan.completedAt == nil {
                            HStack {
                                Button("继续 · 安排下一步") { decide(plan,.continued,due:max(Calendar.current.startOfDay(for:Date()),window.fullEnd)) }
                                Button("调整日期…") { adjusting = plan; nextDate = max(Date(),plan.dueDate) }
                                if plan.cancelledAt == nil { Button("放下这项计划") { decide(plan,.dropped,due:plan.dueDate) } }
                            }.disabled(store.fullBackupBusy || loading)
                            if adjusting?.id == plan.id {
                                HStack { DatePicker("新日期",selection:$nextDate,displayedComponents:.date); Button("确认调整") { decide(plan,.adjusted,due:nextDate) }; Button("取消") { adjusting = nil } }
                            }
                        }
                        Divider()
                    }
                }
                if !loading && result.items.isEmpty { Text("这一组暂无计划。").foregroundStyle(.secondary) }
                JourneyPager(page:$page,total:result.total).disabled(loading)
                WeeklyDecisionsView(window:window)
            }.padding(10)
        }.onChange(of:filter) { _,_ in page = 0; adjusting = nil }
        .task(id:"\(window.key)|\(filter)|\(page)|\(store.journeyRevision)|\(store.growthGeneration)") {
            loading = true
            do {
                let value = try await store.db.weeklyPlans(window:window,filter:filter,offset:page*50); try Task.checkCancellation()
                prior = try store.db.progressValue(GrowthReflection.self,key:GrowthPeriod.week.window(containing:window.previousStart).key)?.nextSteps ?? ""
                result = value; error = nil; loading = false
                if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) }
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
    private func decide(_ plan: LearningPlan, _ decision: WeeklyDecision, due: Date) {
        guard !store.fullBackupBusy, !loading else { return }
        do { try store.db.reviewPlan(plan,window:window,decision:decision,due:due); adjusting = nil; store.journeyRevision += 1 }
        catch { self.error = error.localizedDescription }
    }
}

struct TopicTimelineView: View {
    @Environment(LibraryStore.self) private var store
    let notebookID: Int64
    @State private var result = GrowthPage<TopicTimelineEntry>(items:[],total:0)
    @State private var error: String?
    @State private var anchor: String?
    private var page: Binding<Int> { Binding(get:{store.journeyNavigation.topicPages[notebookID] ?? 0},set:{store.journeyNavigation.topicPages[notebookID] = $0}) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("摘录按当前专题归属；笔记／按语显示最近修改时间。卡片修改从3.3起记录修改时的专题归属，删除原卡后仍保留轨迹。旧版未保存的修改过程无法追补。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(result.items) { item in
                        VStack(alignment:.leading,spacing:6) {
                            Text("\(item.at.formatted(date:.abbreviated,time:.shortened)) · \(item.kind)").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup {
                                Text(item.title).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                            } label: { Text(item.title).lineLimit(3) }
                            if let target = item.target { Button("打开原条目") { anchor = item.id; store.learningExplorer = .init(route:.document(target,"")) } }
                            Divider()
                        }.id(item.id)
                    }
                    if result.items.isEmpty { Text("本专题暂无成长记录。").foregroundStyle(.secondary) }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page:page,total:result.total)
        }
        .onChange(of:anchor) { _,value in store.journeyNavigation.anchors["topic.\(notebookID)"] = value }
        .task(id:"\(notebookID)|\(page.wrappedValue)|\(store.revision)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.topicTimeline(notebookID:notebookID,offset:page.wrappedValue*50); try Task.checkCancellation(); result = value; error = nil; if page.wrappedValue > 0 && value.items.isEmpty { page.wrappedValue = max(0,(value.total-1)/50) }; if anchor == nil { anchor = store.journeyNavigation.anchors["topic.\(notebookID)"] } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct WeeklyDecisionsView: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var page = 0
    @State private var result = GrowthPage<PlanReviewDecision>(items:[],total:0)
    @State private var error: String?
    var body: some View {
        DisclosureGroup("本周已作的安排 · \(result.total)") {
            VStack(alignment:.leading,spacing:8) {
                if let error { Text(error).foregroundStyle(.red) }
                Text("继续会安排到所选周的下一周；复盘旧周时，最早安排到今天。每项保留本周最近一次决定。").font(.caption).foregroundStyle(.secondary)
                ForEach(result.items,id:\.planID) { item in
                    Text(item.title + " · " + (item.decision == .dropped ? "已放下" : item.decision == .continued ? "继续" : "已调整") + (item.nextDue.map { " · " + $0.formatted(date:.abbreviated,time:.omitted) } ?? "")).textSelection(.enabled)
                }
                if result.total > 50 { JourneyPager(page:$page,total:result.total) }
            }
        }.task(id:"\(window.key)|\(page)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.weeklyDecisions(window:window,offset:page*50); try Task.checkCancellation(); result = value; error = nil; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
