import SwiftUI
import Charts
import KongReviewCore

// MARK: - 4.0：研究项目——列表、项目页、编辑面板、“归入项目”菜单

/// 全部项目：在研与已归档
struct ResearchProjectListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var all: [ResearchProject] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("研究项目").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("一个项目就是一件要交出去的成果：论文、著作、讲座与讲稿、课程。项目把专题笔记本、出处、学习计划与专题问题归到一起。")
                        .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { store.newResearchProject() } label: { Label("新建项目", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).handCursor()
                    Spacer()
                }
                let active = all.filter { !$0.isArchived }, archived = all.filter(\.isArchived)
                if all.isEmpty {
                    ContentUnavailableView("还没有研究项目", systemImage: "folder.badge.plus",
                                           description: Text("新建一个项目，再把相关的专题笔记本和出处归进来。"))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                if !active.isEmpty { group("在研 · \(active.count)", active) }
                if !archived.isEmpty { group("已归档 · \(archived.count)", archived) }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("研究项目")
        .task(id: store.researchProjectRevision) { all = (try? store.db.researchProjects(includeArchived: true)) ?? [] }
    }

    private func group(_ title: String, _ items: [ResearchProject]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.sub)
            ForEach(items) { p in
                Button { if let id = p.id { store.selection = .project(id) } } label: { ResearchProjectRow(project: p, isCurrent: p.id == store.currentProjectID) }
                    .buttonStyle(.plain).handCursor()
            }
        }
    }
}

struct ResearchProjectRow: View {
    let project: ResearchProject
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: project.kind.icon).font(.system(size: 18)).foregroundStyle(ReviewPalette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                    if isCurrent {
                        Text("当前项目").font(.system(size: 11, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(ReviewPalette.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text(ResearchProjectText.meta(project)).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(ReviewPalette.sub)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        .opacity(project.isArchived ? 0.7 : 1)
    }
}

enum ResearchProjectText {
    /// “论文 · 初稿 · 截止 12 月 31 日 · 还剩 71 天”
    static func meta(_ p: ResearchProject, now: Date = Date()) -> String {
        var parts = [p.kind.title, p.stage.title]
        if let due = p.dueDate {
            parts.append("截止 " + due.formatted(.dateTime.year().month().day()))
            if let left = p.daysLeft(now: now), !p.isArchived, p.stage != .done {
                parts.append(left > 0 ? "还剩 \(left) 天" : (left == 0 ? "今天截止" : "已过 \(-left) 天"))
            }
        }
        if p.isArchived { parts.append("已归档") }
        return parts.joined(separator: " · ")
    }
}

/// 项目页：阶段条、下一步、未解问题、材料、阶段记录
struct ResearchProjectView: View {
    @Environment(LibraryStore.self) private var store
    let projectId: Int64
    @State private var overview: ResearchProjectOverview?
    @State private var writing: ProjectWriting?
    @State private var writingSheet = false
    @State private var missing = false
    @State private var planDraft: LearningPlan?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let o = overview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(o.project)
                        stageBar(o.project)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 16) { nextSteps(o); questions(o) }.frame(maxWidth: .infinity)
                                VStack(spacing: 16) { materials(o); writingPanel(o); stageHistory(o) }.frame(maxWidth: .infinity)
                            }
                            .frame(minWidth: 700)
                            VStack(spacing: 16) { nextSteps(o); questions(o); materials(o); writingPanel(o); stageHistory(o) }
                        }
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
            } else if missing {
                ContentUnavailableView("这个项目已删除", systemImage: "folder.badge.minus")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(overview?.project.title ?? "研究项目")
        .task(id: "\(projectId)|\(store.researchProjectRevision)|\(store.journeyRevision)|\(store.revision)") { await load() }
        .sheet(item: Binding(get: { planDraft.map { IdentifiedPlan(plan: $0) } }, set: { planDraft = $0?.plan })) { item in
            LearningPlanForm(plan: item.plan) { planDraft = nil }.environment(store).padding().frame(minWidth: 520, minHeight: 480)
        }
        .sheet(isPresented: $writingSheet) {
            if let p = overview?.project { ManualWritingSheet(project: p, hasExternalTotal: writing?.external != nil).environment(store) }
        }
        .confirmationDialog("删除项目“\(overview?.project.title ?? "")”？", isPresented: $confirmDelete) {
            Button("删除项目", role: .destructive) { if let p = overview?.project { store.deleteResearchProject(p) } }
        } message: {
            Text("只删除项目本身与阶段记录；其中的专题笔记本、出处、摘录、计划和问题都保留。若只是做完或暂停，建议用“归档”。")
        }
    }

    private func load() async {
        do {
            overview = try await store.db.researchProjectOverview(id: projectId); missing = false
            writing = try await store.db.projectWriting(projectId: projectId)
        }
        catch ResearchProjectError.missing { overview = nil; missing = true }
        catch { store.report(error) }
    }

    // MARK: 顶部

    private func header(_ p: ResearchProject) -> some View {
        let isCurrent = store.currentProjectID == p.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: p.kind.icon).foregroundStyle(ReviewPalette.accent)
                Text(p.title).font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if isCurrent {
                    Label("当前项目", systemImage: "scope").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                        .help("全库回顾更常抽到本项目材料中的摘录，记忆卡也优先其卡片")
                } else if !p.isArchived {
                    Button { store.setCurrentProject(p) } label: { Label("设为当前项目", systemImage: "scope") }
                        .controlSize(.small).handCursor()
                        .help("全库回顾更常抽到本项目材料中的摘录（权重 ×\(Int(ReviewBias.focusBoost))），记忆卡优先其卡片；同一时间只有一个当前项目")
                }
                Button { store.editResearchProject(p) } label: { Label("编辑", systemImage: "square.and.pencil") }
                    .controlSize(.small).handCursor()
                Menu {
                    if isCurrent { Button("取消当前项目") { store.setCurrentProject(nil) } }
                    Button(p.isArchived ? "恢复为在研" : "归档（完成或放下）") { store.setResearchProjectArchived(p, !p.isArchived) }
                    Divider()
                    Button("删除项目…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Text(ResearchProjectText.meta(p)).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            if !p.question.isEmpty {
                Text("研究问题：" + p.question).font(.system(size: 14, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.isArchived {
                Text("已归档：不在侧栏与首页显示，材料与记录都保留；可从右上角菜单恢复。")
                    .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .disabled(store.fullBackupBusy)
    }

    private func stageBar(_ p: ResearchProject) -> some View {
        let current = p.stage == .paused ? -1 : p.stage.order
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(ResearchProject.Stage.flow) { s in
                    let done = current >= 0 && s.order < current, now = s == p.stage
                    Button { store.setResearchProjectStage(p, s) } label: {
                        Text(s.title)
                            .font(.system(size: 13, weight: now ? .semibold : .regular))
                            .foregroundStyle(now || done ? ReviewPalette.ink : ReviewPalette.sub)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(now ? ReviewPalette.accent.opacity(0.12) : (done ? ReviewPalette.doneSoft : Color.clear),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(now ? ReviewPalette.accent : ReviewPalette.hair, lineWidth: now ? 2 : 1))
                    }
                    .buttonStyle(.plain).handCursor().help(s.hint)
                }
                Button { store.setResearchProjectStage(p, p.stage == .paused ? .material : .paused) } label: {
                    Text(p.stage == .paused ? "搁置中" : "搁置").font(.system(size: 12))
                        .foregroundStyle(p.stage == .paused ? ReviewPalette.ink : ReviewPalette.sub)
                        .padding(.horizontal, 10).frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ReviewPalette.hair, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain).handCursor()
                .help(p.stage == .paused ? "点一下回到“资料”，或直接点上面任一阶段" : ResearchProject.Stage.paused.hint)
            }
            Text("点阶段即可推进或退回；每次改动都记下日期，进入学习小结。")
                .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
        }
        .disabled(store.fullBackupBusy || p.isArchived)
    }

    // MARK: 四块

    private func nextSteps(_ o: ResearchProjectOverview) -> some View {
        ProjectPanel(title: "下一步", subtitle: "关联到本项目、尚未完成的学习计划") {
            if o.pendingPlans.isEmpty {
                Text("还没有计划。把接下来要做的一两件事写成计划，到期会出现在首页的今日待办里。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(o.pendingPlans.prefix(8)) { plan in
                Button { store.openLearningPlans() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(ReviewPalette.sub)
                        Text(Markdown.plainText(fromHTML: plan.title)).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(plan.dueDate.formatted(.dateTime.month().day())).font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Calendar.current.startOfDay(for: plan.dueDate) <= Calendar.current.startOfDay(for: Date()) ? ReviewPalette.pending : ReviewPalette.sub)
                    }
                }
                .buttonStyle(.plain).handCursor().help("在“学习计划”中完成、改期或编辑")
            }
            if o.pendingPlans.count > 8 { Text("另有 \(o.pendingPlans.count - 8) 项，见学习计划").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
            addButton("新建计划") {
                planDraft = LearningPlan(link: LearningPlanLink(kind: .project, recordID: projectId, title: o.project.title))
            }
            .disabled(o.project.isArchived)
        }
    }

    private func questions(_ o: ResearchProjectOverview) -> some View {
        let notebooks = o.links.filter { $0.kind == .notebook }
        return ProjectPanel(title: "未解问题", subtitle: notebooks.isEmpty ? "问题簿中归入本项目的" : "含 \(notebooks.count) 本专题中的") {
            if o.openQuestions.isEmpty {
                Text("暂无未解问题。记下研究中遇到的问题，或在问题簿里把已有问题归入本项目。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(o.openQuestions.prefix(8)) { q in
                Button { store.selection = .question(q.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: q.pinned ? "star.fill" : q.status.symbol).font(.system(size: 11))
                            .foregroundStyle(q.pinned ? Color.orange : q.status.color)
                        Text(q.title).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain).handCursor().help("打开问题：挂材料、写解答、标为解决")
            }
            HStack(spacing: 14) {
                addButton("记一个问题") { store.newQuestion(projectID: projectId) }
                    .disabled(o.project.isArchived)
                Button(o.openQuestions.count > 8 ? "另有 \(o.openQuestions.count - 8) 个，在问题簿中查看" : "在问题簿中查看") {
                    store.openQuestionBook(QuestionFilter(state: .unsolved, projectID: projectId))
                }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.accent).handCursor()
            }
        }
    }

    private func materials(_ o: ResearchProjectOverview) -> some View {
        ProjectPanel(title: "材料", subtitle: "摘录 \(o.highlightCount) 条 · 记忆卡 \(o.cardCount) 张（去重）") {
            if o.links.isEmpty {
                Text("把相关的专题笔记本和出处归进来：它们的摘录会进入当前项目的回顾加权与卡片优先。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(o.links) { link in
                HStack(spacing: 8) {
                    Button {
                        switch link.kind {
                        case .notebook: store.selection = .notebook(link.recordId)
                        case .source: store.selection = .source(link.recordId)
                        case .note: store.selection = .ideaNote(link.recordId)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: link.kind == .notebook ? "text.book.closed" : (link.kind == .note ? "lightbulb" : "book")).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).frame(width: 16)
                            Text(link.title.isEmpty ? "（已删除）" : link.title).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(link.highlightCount) 条").font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                        }
                    }
                    .buttonStyle(.plain).handCursor()
                    Button { store.unlinkFromResearchProject(o.project, kind: link.kind, recordId: link.recordId) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    }
                    .buttonStyle(.plain).handCursor().help("移出项目（笔记本或出处本身不动）")
                }
            }
            materialMenu(o)
        }
    }

    private func materialMenu(_ o: ResearchProjectOverview) -> some View {
        let linked = Set(o.links.map(\.id))
        let notebooks = store.notebooks.filter { n in n.id.map { !linked.contains("notebook.\($0)") } ?? false }
        let sources = store.sources
            .filter { s in s.id.map { !linked.contains("source.\($0)") && (store.highlightCounts[$0] ?? 0) > 0 } ?? false }
            .sorted { (store.highlightCounts[$0.id ?? 0] ?? 0) > (store.highlightCounts[$1.id ?? 0] ?? 0) }
        return Menu {
            Section("专题笔记本") {
                ForEach(notebooks) { n in Button(n.title) { if let id = n.id { store.linkToResearchProject(o.project, kind: .notebook, recordId: id) } } }
            }
            Section("札记（最近修改的 40 条）") {
                ForEach(((try? store.db.recentIdeaNotes(limit: 40)) ?? []).filter { !linked.contains("note.\($0.id)") }) { n in
                    Button(n.title) { store.linkToResearchProject(o.project, kind: .note, recordId: n.id) }
                }
            }
            Section("出处（按摘录数，前 60 种；也可在出处页的“项目”菜单归入）") {
                ForEach(sources.prefix(60)) { s in Button(s.title) { if let id = s.id { store.linkToResearchProject(o.project, kind: .source, recordId: id) } } }
            }
        } label: { Label("归入笔记本、札记或出处", systemImage: "plus").font(.system(size: 12.5)) }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(store.fullBackupBusy || o.project.isArchived)
    }

    private func writingPanel(_ o: ResearchProjectOverview) -> some View {
        let w = writing ?? ProjectWriting()
        let target = o.project.targetWords
        return ProjectPanel(title: "写作", subtitle: "近 12 周新增 \(w.recent.added.formatted()) 字 · 写作 \(w.recent.days) 天") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("稿件现有").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                Text("\(w.manuscriptWords.formatted()) 字").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
                if let target { Text("/ 目标 \(target.formatted()) 字").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub) }
                Spacer(minLength: 6)
                Button { writingSheet = true } label: { Label("记一笔", systemImage: "plus").font(.system(size: 12.5)) }
                    .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                    .disabled(store.fullBackupBusy || o.project.isArchived)
                    .help("登记在 Word 等处写的字数")
            }
            if let target, target > 0 {
                ProgressView(value: min(1, Double(w.manuscriptWords) / Double(target))).tint(ReviewPalette.accent)
            }
            Text("稿件字数＝所归专题笔记本中自己写的字（文字、小标题、本文批注）\(w.external.map { "＋外部稿件全文 \($0.total.formatted()) 字（\($0.at.formatted(.dateTime.month().day())) 登记）" } ?? "")。")
                .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            Chart(w.weeks) { week in
                BarMark(x: .value("周", week.start, unit: .weekOfYear), y: .value("新增字数", week.added))
                    .foregroundStyle(ReviewPalette.accent.opacity(0.7))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
            .accessibilityLabel("近 12 周每周新增字数")
            if !w.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(w.entries) { e in
                        HStack(spacing: 8) {
                            Text(e.day).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub).frame(width: 78, alignment: .leading)
                            Text(e.manual ? (e.note.isEmpty ? "手记" : e.note) : (e.ideaNoteTitle.map { "札记《\($0)》" } ?? "笔记本《\(e.notebookTitle ?? "已删除")》"))
                                .font(.system(size: 12)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("+\(e.added)" + (e.removed > 0 ? " / −\(e.removed)" : "")).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                            if e.manual {
                                Button { store.deleteWritingEntry(e.id) } label: { Image(systemName: "xmark.circle").font(.system(size: 11)) }
                                    .buttonStyle(.plain).foregroundStyle(ReviewPalette.sub).handCursor().help("删除这条手记")
                            }
                        }
                    }
                }
            }
            Text("只记录实际节奏，不设每日任务与连续天数。").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
        }
    }

    private func stageHistory(_ o: ResearchProjectOverview) -> some View {
        ProjectPanel(title: "阶段记录", subtitle: "建于 \(o.project.createdAt.formatted(.dateTime.year().month().day()))") {
            if o.stages.isEmpty { Text("尚无阶段变化").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub) }
            ForEach(o.stages.prefix(10)) { e in
                HStack(spacing: 10) {
                    Text(e.at.formatted(.dateTime.year().month().day())).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                        .frame(width: 104, alignment: .leading)
                    Text("进入“\(e.stage.title)”").font(.system(size: 13)).foregroundStyle(ReviewPalette.ink)
                    if !e.note.isEmpty { Text(e.note).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "plus").font(.system(size: 12.5)) }
            .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
            .disabled(store.fullBackupBusy)
    }
}

private struct IdentifiedPlan: Identifiable {
    var plan: LearningPlan
    var id: UUID { plan.id }
}

/// 项目页的一块：标题、说明与内容
struct ProjectPanel<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                Spacer(minLength: 8)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }
}

/// 记一笔：本次新写的字数，或外部稿件当前全文字数
struct ManualWritingSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: ResearchProject
    let hasExternalTotal: Bool
    @State private var byTotal = false
    @State private var words = 1_000
    @State private var day = Date()
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("记一笔写作").font(.title2.bold())
            Text("项目《\(project.title)》").foregroundStyle(.secondary)
            Picker("方式", selection: $byTotal) {
                Text("本次新写的字数").tag(false)
                Text("外部稿件当前全文字数").tag(true)
            }
            .pickerStyle(.segmented)
            Form {
                HStack {
                    Text(byTotal ? "全文字数" : "新写字数")
                    TextField("", value: $words, format: .number).frame(width: 110).multilineTextAlignment(.trailing)
                    Stepper("", value: $words, in: 0...2_000_000, step: 100).labelsHidden()
                }
                DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date)
                TextField("备注（可空）", text: $note, prompt: Text("如：第二节初稿"))
            }
            .formStyle(.grouped)
            Text(byTotal
                 ? (hasExternalTotal ? "应用按与上次登记的差计入新增（减少时记为删减）。Word 的字数见“工具 → 字数统计”。"
                                     : "第一次登记全文字数只作为起点，不计新增；以后再登记时按差计入。")
                 : "专题笔记本里写的字会自动记录，这里只登记在别处写的。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("记下") {
                    if store.recordWriting(project, words: words, byTotal: byTotal, day: day, note: note) { dismiss() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(words <= 0 && !byTotal)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 480)
    }
}

/// 新建或编辑项目
struct ResearchProjectEditor: View {
    @Environment(LibraryStore.self) private var store
    @State var project: ResearchProject
    @State private var hasDue = false
    @State private var due = Date()
    @State private var hasTarget = false
    @State private var target = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.id == nil ? "新建研究项目" : "编辑研究项目").font(.title2.bold())
            Form {
                TextField("题目", text: $project.title, prompt: Text("如：晚明讲学与士风（论文）"))
                Picker("类型", selection: $project.kind) { ForEach(ResearchProject.Kind.allCases) { Text($0.title).tag($0) } }
                Picker("阶段", selection: $project.stage) {
                    ForEach(ResearchProject.Stage.allCases) { Text($0.title).tag($0) }
                }
                TextField("研究问题", text: $project.question, prompt: Text("一句话：这项研究要回答什么"), axis: .vertical)
                    .lineLimit(2...4)
                Toggle("有截止日期（交稿、会议、开课）", isOn: $hasDue)
                if hasDue { DatePicker("截止日期", selection: $due, displayedComponents: .date) }
                Toggle("设目标字数（只用于显示进度）", isOn: $hasTarget)
                if hasTarget {
                    Stepper(value: $target, in: 1_000...2_000_000, step: 1_000) {
                        HStack { Text("目标字数"); TextField("", value: $target, format: .number).frame(width: 100).multilineTextAlignment(.trailing) }
                    }
                }
            }
            .formStyle(.grouped)
            if store.researchProjectPendingLink != nil {
                Text("保存后会把当前的专题笔记本或出处归入这个项目。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.researchProjectPendingLink = nil; store.researchProjectEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    project.dueDate = hasDue ? Calendar.current.startOfDay(for: due) : nil
                    project.targetWords = hasTarget ? target : nil
                    if store.saveResearchProject(project) != nil { store.researchProjectEditor = nil }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.fullBackupBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 440)
        .onAppear {
            if let d = project.dueDate { hasDue = true; due = d }
            if let t = project.targetWords { hasTarget = true; target = t }
        }
    }
}

/// 专题笔记本、出处页工具栏的“项目”菜单：归入或移出项目，或新建项目并归入
struct ResearchProjectLinkMenu: View {
    @Environment(LibraryStore.self) private var store
    let kind: ResearchProjectLink.Kind
    let recordId: Int64

    var body: some View {
        let member = store.researchProjects(containing: kind, recordId: recordId)
        let memberIDs = Set(member.compactMap(\.id))
        Menu {
            if store.researchProjects.isEmpty { Text("还没有在研项目") }
            ForEach(store.researchProjects) { p in
                Button {
                    if let id = p.id, memberIDs.contains(id) { store.unlinkFromResearchProject(p, kind: kind, recordId: recordId) }
                    else { store.linkToResearchProject(p, kind: kind, recordId: recordId) }
                } label: {
                    if let id = p.id, memberIDs.contains(id) { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
            Divider()
            Button("新建项目并归入…") { store.newResearchProject(linking: ResearchProjectPendingLink(kind: kind, recordId: recordId)) }
            if let first = member.first(where: { !$0.isArchived }), let id = first.id {
                Button("打开项目“\(first.title)”") { store.selection = .project(id) }
            }
        } label: {
            Label(member.isEmpty ? "项目" : "项目 · \(member.count)", systemImage: "folder")
        }
        .help(member.isEmpty ? "归入研究项目：项目把相关的笔记本、出处、计划与问题归到一起" : "所属项目：" + member.map(\.title).joined(separator: "、"))
        .disabled(store.fullBackupBusy)
    }
}

/// 4.0：首页“当前项目”卡——题目、阶段、截止前剩余天数、第一条下一步、未解问题、本周写作
struct CurrentProjectCard: View {
    @Environment(LibraryStore.self) private var store
    @State private var overview: ResearchProjectOverview?
    @State private var weekWriting = WritingSummary()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("当前项目", systemImage: "scope").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.accent)
                Spacer(minLength: 8)
                if !store.researchProjects.isEmpty {
                    Button("全部项目") { store.selection = .projects }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).handCursor()
                }
            }
            if let project = store.currentProject {
                currentBody(project)
            } else if store.researchProjects.isEmpty {
                Text("把一篇论文、一部书稿、一门课或一组讲座建成研究项目，归入相关的专题笔记本与出处；回顾与记忆卡会侧重它的材料，学习小结报告它的进展。")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                Button { store.newResearchProject() } label: { Label("新建研究项目", systemImage: "plus") }
                    .handCursor()
            } else {
                Text("尚未设定当前项目。选一个，回顾与记忆卡会侧重它的材料。")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                HStack(spacing: 8) {
                    ForEach(store.researchProjects.prefix(3)) { p in
                        Button(p.title) { store.setCurrentProject(p) }.lineLimit(1).handCursor()
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        .task(id: "\(store.currentProjectID ?? 0)|\(store.researchProjectRevision)|\(store.journeyRevision)|\(store.revision)") { await load() }
    }

    private func load() async {
        guard let id = store.currentProjectID else { overview = nil; weekWriting = .init(); return }
        let week = GrowthPeriod.week.window(containing: Date())
        overview = try? await store.db.researchProjectOverview(id: id)
        weekWriting = (try? await store.db.projectWritingSummary(projectId: id, start: week.start, end: week.end)) ?? .init()
    }

    @ViewBuilder private func currentBody(_ p: ResearchProject) -> some View {
        Button { if let id = p.id { store.selection = .project(id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(ResearchProjectText.meta(p)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .buttonStyle(.plain).handCursor().help("打开项目页")
        let overdue = p.daysLeft().map { $0 < 0 } ?? false
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) { facts(p, overdue: overdue) }
            VStack(alignment: .leading, spacing: 8) { facts(p, overdue: overdue) }
        }
    }

    @ViewBuilder private func facts(_ p: ResearchProject, overdue: Bool) -> some View {
        fact("下一步") {
            if let plan = overview?.pendingPlans.first {
                let late = Calendar.current.startOfDay(for: plan.dueDate) <= Calendar.current.startOfDay(for: Date())
                Text(Markdown.plainText(fromHTML: plan.title)).lineLimit(1).foregroundStyle(ReviewPalette.ink)
                Text(plan.dueDate.formatted(.dateTime.month().day())).foregroundStyle(late ? ReviewPalette.pending : ReviewPalette.sub)
            } else {
                Text("还没有计划").foregroundStyle(ReviewPalette.sub)
            }
        }
        fact("未解问题") {
            let n = overview?.openQuestions.count ?? 0
            Text("\(n) 个").foregroundStyle(n > 0 ? ReviewPalette.pending : ReviewPalette.sub)
        }
        fact("本周写作") {
            Text("\(weekWriting.added.formatted()) 字").foregroundStyle(ReviewPalette.ink)
            if weekWriting.days > 0 { Text("\(weekWriting.days) 天").foregroundStyle(ReviewPalette.sub) }
        }
        if overdue {
            fact("截止") { Text("已过截止日期").foregroundStyle(ReviewPalette.pending) }
        }
    }

    private func fact<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            HStack(spacing: 6) { content() }.font(.system(size: 13).monospacedDigit())
        }
    }
}

/// 4.0：侧栏改为六组后，首页显示一次说明
struct SidebarRegroupNotice: View {
    @AppStorage("sidebar.v5.noticeDismissed") private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sidebar.left").foregroundStyle(ReviewPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("侧栏已按“个人学术回顾”改为四组").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                    Text("回顾（首页、今日回顾、记忆卡、重温、自测、复盘、个人成长、回顾统计）、思考（札记、问题簿）、材料（摘录、收藏、出处、网页存档、已存搜索、标签）、研究与写作（研究项目、专题笔记本，默认折叠，可在设置“回顾”页隐藏）。原有入口一个不少；最近删除与使用说明仍在最后。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("知道了") { dismissed = true }.controlSize(.small).handCursor()
            }
            .padding(14)
            .background(ReviewPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
