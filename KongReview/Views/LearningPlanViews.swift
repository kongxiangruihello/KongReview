import SwiftUI

struct LearningPlanForm: View {
    @Environment(LibraryStore.self) private var store
    @State var plan: LearningPlan
    var recovered: LearningPlanDraft? = nil
    let onClose: () -> Void
    @State private var original: LearningPlan?
    @State private var splitLines = false
    @State private var repeatWeekly = false
    @State private var generation = -1
    @State private var ready = false
    @State private var closed = false
    @State private var confirmDiscard = false
    @State private var choosing = false
    @State private var kind: LearningPlanLinkKind = .notebook
    @State private var query = ""
    @State private var page = 0
    @State private var choices = GrowthPage<LearningPlanLink>(items: [], total: 0)
    @State private var error: String?
    @State private var loading = false
    private var draft: LearningPlanDraft { .init(plan: plan, splitLines: splitLines, original: original, repeatWeekly:repeatWeekly) }
    var body: some View {
        GroupBox("学习计划 · 保存后加入待办") {
            VStack(alignment: .leading, spacing: 12) {
                RichEditor(text:$plan.title,placeholder:"学习计划，多条请用独立段落",autoHeight:true,minHeight:90,slot:"plan-title").richEditorFrame()
                if original == nil {
                    Toggle("逐行拆分为独立计划", isOn: $splitLines)
                    if splitLines { Text("将创建 \(LearningPlanDraft.lines(plan.title).count) 条计划，共用以下日期与关联资料；保存后可以分别调整。").font(.caption).foregroundStyle(.secondary) }
                }
                DatePicker("计划日期", selection: $plan.dueDate, displayedComponents: .date)
                if original == nil {
                    Toggle("每周按计划日期的星期重复",isOn:$repeatWeekly)
                    if repeatWeekly { Text("每个安排最多保留一项待办；漏做多周不会逐周补建。可在“重复安排”中暂停后续重复。").font(.caption).foregroundStyle(.secondary) }
                } else if plan.recurrenceID != nil { Text("这是重复安排的一次任务；本次编辑不改变后续安排，可在“重复安排”中暂停。").font(.caption).foregroundStyle(.secondary) }
                if let link = plan.link {
                    HStack { Text("关联\(link.kind.title)：\(link.title)").lineLimit(3); Button("移除关联") { plan.link = nil } }
                }
                Button(choosing ? "收起关联选择" : "关联笔记本、出处或记忆卡…") { choosing.toggle() }
                if choosing {
                    Picker("关联类型", selection: $kind) { ForEach(LearningPlanLinkKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    TextField("搜索名称或卡片正面", text: $query).textFieldStyle(.roundedBorder)
                    if loading { ProgressView() }
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(choices.items) { link in Button { plan.link = link; choosing = false } label: { Text(link.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(5) }.buttonStyle(.plain).handCursor() }
                            if !loading && choices.items.isEmpty { Text("没有符合条件的内容").foregroundStyle(.secondary) }
                        }
                    }.frame(height: 160)
                    JourneyPager(page: $page, total: choices.total).disabled(loading)
                }
                Text("未保存的输入会暂存。切换页面或重启后，可在“学习计划 → 未保存草稿”继续编辑。").font(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red)
                    HStack {
                        Button("重试暂存") { persistDraft() }
                        Button("保留输入，采用最新计划状态") {
                            do {
                                original = try store.db.progressValue(LearningPlan.self,key:plan.key)
                                plan.completedAt = original?.completedAt; plan.cancelledAt = original?.cancelledAt; plan.outcome = original?.outcome
                                persistDraft()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                HStack {
                    Button(splitLines ? "保存这些计划" : "保存计划") {
                        guard generation == store.growthGeneration, !store.fullBackupBusy else { return }; do { try store.db.commitPlanDraft(draft); closed = true; store.journeyRevision += 1; onClose() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!ready || plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.fullBackupBusy)
                    Button("结束编辑") { persistDraft(); if error == nil { closed = true; onClose() } }
                    Button("丢弃草稿") { confirmDiscard = true }
                }.disabled(!ready)
            }.padding(8).disabled(!ready || store.fullBackupBusy)
        }
        .confirmationDialog("丢弃未保存的输入？已保存的原计划不会改变。", isPresented: $confirmDiscard) {
            Button("丢弃草稿", role: .destructive) {
                do { try store.db.deleteProgress(key: draft.key); closed = true; store.journeyRevision += 1; onClose() }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear {
            guard !ready else { return }
            generation = store.growthGeneration
            do {
                let saved = try recovered ?? store.db.progressValue(LearningPlanDraft.self, key: draft.key)
                if let saved { plan = saved.plan; splitLines = saved.splitLines; original = saved.original; repeatWeekly = saved.repeatWeekly ?? false }
                else { original = try store.db.progressValue(LearningPlan.self, key: plan.key) }
                ready = true; persistDraft()
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: plan) { _,_ in persistDraft() }
        .onChange(of: repeatWeekly) { _,_ in persistDraft() }
        .onChange(of: splitLines) { _,_ in persistDraft() }
        .onDisappear { persistDraft() }
        .onChange(of: kind) { _, _ in page = 0 }.onChange(of: query) { _, _ in page = 0 }
        .task(id: "\(choosing)|\(kind)|\(query)|\(page)|\(store.revision)") {
            guard choosing else { return }; loading = true
            do { try await Task.sleep(for: .milliseconds(180)); let value = try await store.db.planLinkChoices(kind: kind, query: query, offset: page*50); try Task.checkCancellation(); choices = value; loading = false }
            catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
        }
    }
    private func persistDraft() {
        guard ready, !closed, generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do {
            if draft.isDirty && !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try store.db.saveProgress(draft, key: draft.key) }
            else { try store.db.deleteProgress(key: draft.key) }
            error = nil; store.journeyRevision += 1
        } catch { self.error = "草稿未能暂存：" + error.localizedDescription; store.errorMessage = self.error }
    }
}

struct LearningPlansView: View {
    @Environment(LibraryStore.self) private var store
    @State private var completing: LearningPlan?
    @State private var result = GrowthPage<LearningPlan>(items: [], total: 0)
    @State private var drafts = GrowthPage<LearningPlanDraft>(items: [], total: 0)
    @State private var draftPage = 0
    @State private var editing: LearningPlanDraft?
    @State private var error: String?
    @State private var loading = false
    @State private var anchor: String?
    private var status: PlanStatus { store.journeyNavigation.planStatus }
    private var page: Int { store.journeyNavigation.planPage }
    var body: some View {
        @Bindable var navigation = store.journeyNavigation
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("状态", selection: $navigation.planStatus) { ForEach(PlanStatus.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Button("重复安排") { store.journeyNavigation.tab = 8 }
                Button("新建计划") { editing = .init(plan: LearningPlan()) }.disabled(editing != nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let editing { LearningPlanForm(plan: editing.plan, recovered: editing) { self.editing = nil }.id(editing.id) }
                    if drafts.total > 0 && editing == nil {
                        DisclosureGroup("未保存草稿 · \(drafts.total)") {
                            ForEach(drafts.items) { draft in
                                Button { editing = draft } label: { Text(RichText.attributed(draft.plan.title)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading).padding(6) }.buttonStyle(.plain).handCursor()
                            }
                            JourneyPager(page:$draftPage,total:drafts.total)
                        }
                    }
                    if !loading && result.items.isEmpty { Text("暂无\(status.title)的计划。").foregroundStyle(.secondary) }
                    ForEach(result.items) { plan in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(RichText.attributed(plan.title)).textSelection(.enabled)
                                Text("计划日期：\(plan.dueDate.formatted(date: .abbreviated, time: .omitted))" + (status == .pending && Calendar.current.startOfDay(for: plan.dueDate) < Calendar.current.startOfDay(for: Date()) ? " · 已逾期" : "")).font(.caption).foregroundStyle(.secondary)
                                if let outcome = plan.outcome, plan.completedAt != nil { PlanOutcomeSummary(outcome:outcome) }
                                if let at = plan.completedAt { Text("完成于 \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                if let at = plan.cancelledAt { Text("取消于 \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                if let link = plan.link { Button("打开\(link.kind.title)：\(link.title)") { anchor = plan.id.uuidString; store.openLearningPlanLink(link) }.lineLimit(2) }
                                HStack {
                                    Button(status == .pending ? "标为完成" : "恢复为待办") { if status == .pending { completing = plan } else { change(plan,to:.pending) } }
                                    if status == .completed { Button("补充收获") { completing = plan } }
                                    if status != .cancelled { Button(plan.recurrenceID != nil && status == .pending ? "跳过本次" : "取消计划") { change(plan,to:.cancelled) } }
                                    Button("编辑／改期") {
                                        do { editing = try store.db.progressValue(LearningPlanDraft.self,key:"plan-draft.\(plan.id.uuidString)") ?? .init(plan:plan,original:plan) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.disabled(editing != nil || store.fullBackupBusy)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }.id(plan.id.uuidString)
                    }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page: $navigation.planPage, total: result.total).disabled(loading)
        }
        .sheet(item:$completing) { plan in PlanOutcomeForm(plan:plan) { completing = nil }.environment(store) }
        .onChange(of: anchor) { _, value in if let value { store.journeyNavigation.anchors["plans"] = value } }
        .onChange(of: status) { _, _ in navigation.planPage = 0; anchor = nil; navigation.anchors["plans"] = nil }
        .task(id: "\(status)|\(page)|\(store.journeyRevision)|\(store.growthGeneration)|\(store.today)") {
            store.refreshWeeklyPlans()
            loading = true
            do {
                let value = try await store.db.planPage(status:status,offset:page*50); try Task.checkCancellation()
                result = value; error = nil; loading = false
                if page > 0 && value.items.isEmpty { navigation.planPage = max(0,(value.total-1)/50) }
                if anchor == nil { anchor = navigation.anchors["plans"] }
            } catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id:"\(draftPage)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.planDrafts(offset:draftPage*50); try Task.checkCancellation(); drafts = value; if draftPage > 0 && value.items.isEmpty { draftPage = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    private func change(_ plan: LearningPlan, to status: PlanStatus) {
        do { try store.db.changePlanStatus(id:plan.id,status:status); store.journeyRevision += 1 }
        catch { self.error = error.localizedDescription }
    }
}

struct HomeTodayPlans: View {
    @Environment(LibraryStore.self) private var store
    @State private var completing: LearningPlan?
    @State private var summary = TodayPlanSummary(today:0,overdue:0,page:.init(items:[],total:0))
    @State private var page = 0
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text("今日待办 \(summary.today) · 逾期 \(summary.overdue)").font(.headline); Spacer(); Button("全部学习计划") { store.openLearningPlans() } }
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView() }
                if summary.page.items.isEmpty && !loading { Text("今天没有待完成的学习计划。").foregroundStyle(.secondary) }
                ForEach(summary.page.items) { plan in
                    HStack(alignment:.top) {
                        Button { completing = plan } label: { Image(systemName:"circle") }.help("标为完成").accessibilityLabel("完成计划：\(plan.title)").disabled(store.fullBackupBusy)
                        VStack(alignment:.leading,spacing:4) {
                            Button { if let link = plan.link { store.openLearningPlanLink(link) } else { store.openLearningPlans() } } label: { Text(RichText.attributed(plan.title)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).handCursor()
                            Text(plan.dueDate.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if summary.page.total > 5 { JourneyPager(page:$page,total:summary.page.total,pageSize:5).disabled(loading) }
            }.padding(10)
        }.sheet(item:$completing) { plan in PlanOutcomeForm(plan:plan) { completing = nil }.environment(store) }
        .task(id:"\(page)|\(store.journeyRevision)|\(store.today)|\(store.growthGeneration)") {
            store.refreshWeeklyPlans()
            loading = true
            do { let value = try await store.db.todayPlans(offset:page*5,limit:5); try Task.checkCancellation(); summary = value; loading = false; error = nil; if page > 0 && value.page.items.isEmpty { page = max(0,(value.page.total-1)/5) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
        }
    }
}
