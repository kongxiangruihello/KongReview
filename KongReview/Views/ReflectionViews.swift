import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 5.0.1：复盘——按步骤回看这一周（月、年）
//
// 每周五步：看数字、看新材料、看自己的想法、过一遍常念问题、写三句话；年度在写三句话前加“观点的变化”。
// 任何一步都可跳过；做完点“完成复盘”。三句话与学习小结的“复盘”是同一份。

struct ReflectionView: View {
    @Environment(LibraryStore.self) private var store
    @State private var progress = ReflectionProgress()

    private var window: GrowthWindow { store.reflectionPeriod.window(containing: store.reflectionDate) }
    private var steps: [ReflectionStep] { ReflectionStep.steps(for: store.reflectionPeriod) }

    var body: some View {
        let w = window
        let current = min(progress.step, steps.count - 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(w)
                stepBar(current: current, window: w)
                Group {
                    switch steps[current] {
                    case .numbers: ReflectionNumbersStep(window: w)
                    case .materials: ReflectionMaterialsStep(window: w)
                    case .thoughts: ReflectionThoughtsStep(window: w)
                    case .questions: ReflectionQuestionsStep(window: w)
                    case .views: ReflectionViewsStep(window: w)
                    case .sentences: ReflectionSentencesStep(window: w)
                    }
                }
                .id("\(w.key)|\(current)")
                footer(current: current, window: w)
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("复盘")
        .task(id: "\(w.key)|\(store.reflectionRevision)") {
            var p = (try? store.db.reflectionProgress(w)) ?? ReflectionProgress()
            p.step = min(max(0, p.step), steps.count - 1)
            if !p.visited.contains(p.step) { p.visited.append(p.step) }
            progress = p
        }
    }

    // MARK: 页头

    private func header(_ w: GrowthWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(w.period.title)复盘").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Picker("", selection: Binding(get: { store.reflectionPeriod }, set: { p in
                    store.reflectionPeriod = p
                    store.reflectionDate = p == .week ? store.db.reflectionTargetWeek().start : Date()
                })) {
                    Text("每周").tag(GrowthPeriod.week)
                    Text("每月").tag(GrowthPeriod.month)
                    Text("每年").tag(GrowthPeriod.year)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button { store.journeyNavigation.period = w.period; store.journeyNavigation.date = w.start; store.journeyNavigation.tab = 0; store.selection = .growth } label: {
                    Label("学习小结", systemImage: "doc.text")
                }
                .buttonStyle(.borderless).font(.system(size: 12)).handCursor()
            }
            HStack(spacing: 8) {
                Button { store.reflectionDate = w.previousStart } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).handCursor().help("上一期")
                Text(rangeLabel(w)).font(.system(size: 13).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
                Button { store.reflectionDate = w.fullEnd } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).handCursor().help("下一期")
                    .disabled(w.fullEnd > Date())
                if let done = progress.completedAt {
                    Label("已于 \(Self.day(done)) 完成复盘", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ReviewPalette.done)
                } else {
                    Text(w.period == .week ? "约十分钟，任何一步都可跳过。" : "按步骤回看这一期，任何一步都可跳过。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                }
            }
        }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    private func rangeLabel(_ w: GrowthWindow) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        switch w.period {
        case .year: f.dateFormat = "yyyy年"; return f.string(from: w.start)
        case .month: f.dateFormat = "yyyy年M月"; return f.string(from: w.start)
        default:
            f.dateFormat = "yyyy年M月d日"
            let end = w.fullEnd.addingTimeInterval(-1)
            return f.string(from: w.start) + " — " + Self.day(end)
        }
    }

    // MARK: 步骤条

    private func stepBar(current: Int, window w: GrowthWindow) -> some View {
        // 窄窗口：其余各步只显示序号，当前一步显示名称
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { stepButtons(current: current, window: w, compact: false) }
            HStack(spacing: 6) { stepButtons(current: current, window: w, compact: true) }
        }
    }

    @ViewBuilder
    private func stepButtons(current: Int, window w: GrowthWindow, compact: Bool) -> some View {
        ForEach(steps.indices, id: \.self) { i in
            let on = i == current
            let seen = progress.visited.contains(i) || progress.completedAt != nil
            Button { go(to: i, window: w) } label: {
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(on ? ReviewPalette.accent : (seen ? ReviewPalette.done : ReviewPalette.sub.opacity(0.5)), in: Circle())
                    if on || !compact {
                        Text(steps[i].title).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? ReviewPalette.accent : ReviewPalette.ink)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? ReviewPalette.accentSoft : ReviewPalette.card, in: Capsule())
                .overlay(Capsule().stroke(ReviewPalette.hair))
            }
            .buttonStyle(.plain).handCursor().fixedSize()
            .help("第 \(i + 1) 步：\(steps[i].title)")
        }
    }

    private func go(to i: Int, window w: GrowthWindow) {
        progress.step = i
        if !progress.visited.contains(i) { progress.visited.append(i) }
        store.saveReflectionStep(progress, window: w)
    }

    // MARK: 页脚

    private func footer(current: Int, window w: GrowthWindow) -> some View {
        HStack(spacing: 10) {
            if current > 0 {
                PillButton(icon: "chevron.left", title: "上一步") { go(to: current - 1, window: w) }
            }
            Spacer()
            if current < steps.count - 1 {
                PillButton(title: "跳过这一步", style: .ghost) { go(to: current + 1, window: w) }
                PillButton(icon: "chevron.right", title: "下一步：\(steps[current + 1].title)", style: .primary) { go(to: current + 1, window: w) }
            } else {
                PillButton(icon: "checkmark.seal", title: progress.completedAt == nil ? "完成\(w.period.title)复盘" : "再次标为完成", style: .primary) {
                    store.completeReflection(w)
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 共用

private struct ReflectionPanel<Content: View>: View {
    let title: String
    var lead: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        ReviewCardContainer(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if !lead.isEmpty {
                    Text(lead).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
        }
    }
}

private struct ReflectionEmpty: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub) }
}

private func plainPreview(_ html: String, limit: Int = 140) -> String {
    let plain = Markdown.plainText(fromHTML: Markdown.richHTML(html))
        .split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return plain.count > limit ? String(plain.prefix(limit - 1)) + "…" : plain
}

// MARK: - ① 看数字

struct ReflectionNumbersStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var rows: [ReflectionNumber] = []
    @State private var error: String?

    var body: some View {
        ReflectionPanel(title: "① 看数字", lead: "本期与上期同期比较，只看不填。完整的数字、质量指标与明细在学习小结里。") {
            if let error { Text(error).foregroundStyle(.red) }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("指标"); Text("本期").gridColumnAlignment(.trailing); Text("上期同期").gridColumnAlignment(.trailing); Text("增减").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                Divider().gridCellColumns(4)
                ForEach(rows) { r in
                    GridRow {
                        Text(r.title).foregroundStyle(ReviewPalette.ink)
                        Text("\(r.now)").fontWeight(.semibold)
                        Text("\(r.before)").foregroundStyle(ReviewPalette.sub)
                        Text(r.now == r.before ? "0" : (r.now > r.before ? "+\(r.now - r.before)" : "−\(r.before - r.now)"))
                            .foregroundStyle(r.now > r.before ? ReviewPalette.done : ReviewPalette.ink)
                    }
                    .font(.system(size: 13.5).monospacedDigit())
                }
            }
        }
        .task(id: "\(window.key)|\(store.revision)|\(store.revisitRevision)|\(store.questionRevision)") {
            do { rows = try await store.db.reflectionNumbers(window); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - ② 看新材料

struct ReflectionMaterialsStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var entries: [NotebookEntry] = []
    @State private var shown = 30

    var body: some View {
        ReflectionPanel(title: "② 看新材料", lead: "本期收藏与写了按语的摘录，按出处列出。值得展开的记成札记，与某个问题有关的挂上去。") {
            if entries.isEmpty { ReflectionEmpty(text: "本期还没有收藏或写过按语的摘录。") }
            ForEach(Array(entries.prefix(shown).enumerated()), id: \.offset) { i, e in
                if i == 0 || entries[i - 1].sourceTitle != e.sourceTitle {
                    Text(e.sourceTitle.map { "《\($0)》" } ?? "未归类").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                        .padding(.top, i == 0 ? 0 : 6)
                }
                row(e)
            }
            if entries.count > shown {
                Button("再显示 30 条（共 \(entries.count) 条）") { shown += 30 }.buttonStyle(.link).handCursor()
            }
        }
        .task(id: "\(window.key)|\(store.revision)") { entries = (try? store.db.notebookEntries(start: window.start, end: window.end)) ?? [] }
    }

    private func row(_ e: NotebookEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plainPreview(e.highlight.text)).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if e.favorited { Label("收藏", systemImage: "star.fill").foregroundStyle(Color.orange) }
                    if e.noted { Label("按语", systemImage: "text.bubble") }
                    if let loc = e.highlight.location, !loc.isEmpty { Text(loc) }
                }
                .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                if let n = e.highlight.note, !plainPreview(n).isEmpty {
                    let note = plainPreview(n, limit: 100)
                    Text(note.hasPrefix("按") ? note : "按：" + note).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("记札记") { store.composeIdeaNote(highlight: e.highlight) }
                Button("挂到问题") {
                    if let id = e.highlight.id {
                        store.questionAttach = QuestionAttachRequest(kind: .highlight, recordId: id, preview: String(plainPreview(e.highlight.text).prefix(60)))
                    }
                }
            }
            .controlSize(.small).handCursor()
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
    }
}

// MARK: - ③ 看自己的想法

struct ReflectionThoughtsStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var t = ReflectionThoughts()

    var body: some View {
        ReflectionPanel(title: "③ 看自己的想法", lead: "本期新写、修订的札记，以及重温时说“要修订”却还没改的。看看这一段想通了什么、改了哪些看法。") {
            group("本期新写（\(t.created.count)）", t.created.map { ($0.id, $0.title, "") }, empty: "本期没有新写札记。")
            group("本期修订（\(t.revised.count)）", t.revised.map { ($0.ref.id, $0.ref.title, "改过 \($0.times) 次") }, empty: "本期没有修订札记。")
            group("待修订（\(t.pendingRevision.count)）", t.pendingRevision.map { ($0.id, $0.title, "重温时说要修订") }, empty: "没有待修订的札记。")
            Button { store.composeIdeaNote() } label: { Label("写一条新札记", systemImage: "square.and.pencil") }
                .controlSize(.small).handCursor()
        }
        .task(id: "\(window.key)|\(store.ideaNoteRevision)|\(store.revisitRevision)") {
            t = (try? store.db.reflectionThoughts(start: window.start, end: window.end)) ?? ReflectionThoughts()
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [(Int64, String, String)], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            if items.isEmpty { ReflectionEmpty(text: empty) }
            ForEach(items, id: \.0) { item in
                HStack(spacing: 8) {
                    Button { store.selection = .ideaNote(item.0) } label: {
                        Text(item.1).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.accent).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain).handCursor()
                    if !item.2.isEmpty { Text(item.2).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub) }
                }
            }
        }
    }
}

// MARK: - ④ 过一遍常念问题

struct ReflectionQuestionsStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var q = ReflectionQuestions()

    var body: some View {
        ReflectionPanel(title: "④ 过一遍常念问题",
                        lead: "每个常念的问题本期新挂了几条材料？可改状态、取消常念，或把新的疑问标为常念。") {
            if window.period == .year {
                Text("一年的问题：新记 \(q.created) 个，解决 \(q.solvedCount) 个，今年新记而仍在心上的 \(q.stillOpen) 个。")
                    .font(.system(size: 13.5)).foregroundStyle(ReviewPalette.ink)
                Button("导出“一年的问题”（Markdown）…") { exportYear() }.controlSize(.small).handCursor()
            }
            if !q.solved.isEmpty {
                Text("本期解决的问题（\(q.solved.count)）").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                ForEach(q.solved) { r in questionLink(r, note: "已解决") }
            }
            Text("常念的问题（\(q.pinned.count)）").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            if q.pinned.count > ReflectionQuestions.pinnedLimit {
                Label("常念的问题已有 \(q.pinned.count) 个，超过 \(ReflectionQuestions.pinnedLimit) 个，可以取消几个，留下最放不下的。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5)).foregroundStyle(Color.orange)
            }
            if q.pinned.isEmpty { ReflectionEmpty(text: "还没有常念的问题。可以从下面挑几个标上。") }
            ForEach(q.pinned) { p in
                HStack(spacing: 10) {
                    questionLink(p.ref, note: p.newMaterials > 0 ? "本期新挂 \(p.newMaterials) 条材料" : "本期没有新材料")
                    Spacer(minLength: 8)
                    Menu("状态") {
                        ForEach([Question.Status.open, .lead, .shelved], id: \.self) { s in
                            Button { store.setQuestionStatus(p.ref.id, s) } label: {
                                if s == p.ref.status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                            }
                        }
                        Divider()
                        Button("写解答、标为已解决…") { store.selection = .question(p.ref.id) }
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    Button("取消常念") { store.setQuestionPinned(p.ref.id, false) }.controlSize(.small).handCursor()
                }
            }
            if !q.candidates.isEmpty {
                Text("最近的其他问题").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink).padding(.top, 4)
                ForEach(q.candidates) { r in
                    HStack(spacing: 10) {
                        questionLink(r, note: r.status.title)
                        Spacer(minLength: 8)
                        Button("标为常念") { store.setQuestionPinned(r.id, true) }.controlSize(.small).handCursor()
                    }
                }
            }
            Button { store.newQuestion() } label: { Label("记一个问题", systemImage: "plus.bubble") }.controlSize(.small).handCursor()
        }
        .task(id: "\(window.key)|\(store.questionRevision)") {
            q = (try? store.db.reflectionQuestions(start: window.start, end: window.end)) ?? ReflectionQuestions()
        }
    }

    private func questionLink(_ r: QuestionRef, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.pinned ? "star.fill" : r.status.symbol).font(.system(size: 11))
                .foregroundStyle(r.pinned ? Color.orange : r.status.color)
            Button { store.selection = .question(r.id) } label: {
                Text(r.title).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.accent).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).handCursor()
            Text(note).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
        }
    }

    private func exportYear() {
        do {
            let md = try store.db.questionsYearMarkdown(window)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(Calendar.current.component(.year, from: window.start))年的问题.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch { store.report(error) }
    }
}

// MARK: - 年度：观点的变化

struct ReflectionViewsStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var changes: [ViewChange] = []

    var body: some View {
        ReflectionPanel(title: "观点的变化", lead: "今年修订过的札记：左边是年初（今年才写的取初写时）的样子，右边是现在。看法变了的，值得在“收获”里写一句为什么。") {
            if changes.isEmpty { ReflectionEmpty(text: "今年还没有修订过札记。（修订历史从 5.0 起保存。）") }
            ForEach(changes) { c in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { store.selection = .ideaNote(c.id) } label: {
                            Text(c.nowTitle).font(.system(size: 14.5, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.accent)
                        }
                        .buttonStyle(.plain).handCursor()
                        Text("改过 \(c.revisions) 次").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        side("年初", title: c.beforeTitle, body: c.beforeBody)
                        side("现在", title: c.nowTitle, body: c.nowBody)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .task(id: "\(window.key)|\(store.ideaNoteRevision)") {
            changes = (try? store.db.viewChanges(start: window.start, end: window.end)) ?? []
        }
    }

    private func side(_ label: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            Text(plainPreview(WikiLinks.plain(body), limit: 400)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 写三句话

struct ReflectionSentencesStep: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var reflection = GrowthReflection()
    @State private var previousNext = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var planDraft: LearningPlan?

    var body: some View {
        ReflectionPanel(title: "写三句话", lead: "收获、困难、下一步各写一句就够。与学习小结里的“复盘”是同一份，自动保存。") {
            VStack(alignment: .leading, spacing: 8) {
                Text("收获：哪些理解加深了、想通了什么").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                RichEditor(text: $reflection.gains, placeholder: "收获", autoHeight: true, minHeight: 70, slot: "reflection-gains").richEditorFrame()
                Button { save(); store.composeIdeaNote(body: reflection.gains) } label: { Label("写成札记", systemImage: "note.text.badge.plus") }
                    .controlSize(.small).handCursor().disabled(isBlank(reflection.gains))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("困难：哪些问题仍未解决").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                RichEditor(text: $reflection.challenges, placeholder: "困难", autoHeight: true, minHeight: 70, slot: "reflection-challenges").richEditorFrame()
                Button { save(); store.newQuestion(title: firstSentence(reflection.challenges)) } label: { Label("记为问题", systemImage: "questionmark.bubble") }
                    .controlSize(.small).handCursor().disabled(isBlank(reflection.challenges))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("下一步：下一阶段关注什么").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                if !isBlank(previousNext) {
                    Text("对照：上期写下的下一步——" + plainPreview(previousNext, limit: 120)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                }
                RichEditor(text: $reflection.nextSteps, placeholder: "下一步", autoHeight: true, minHeight: 70, slot: "reflection-next").richEditorFrame()
                Button { save(); planDraft = LearningPlan(title: reflection.nextSteps, originKey: window.key) } label: { Label("转为学习计划…", systemImage: "calendar.badge.plus") }
                    .controlSize(.small).handCursor().disabled(isBlank(reflection.nextSteps) || planDraft != nil)
                if let planDraft { LearningPlanForm(plan: planDraft) { self.planDraft = nil }.id(planDraft.id) }
            }
        }
        .disabled(!loaded)
        .task(id: window.key) {
            reflection = (try? store.db.progressValue(GrowthReflection.self, key: window.key)) ?? GrowthReflection()
            previousNext = (try? store.db.progressValue(GrowthReflection.self, key: window.period.window(containing: window.previousStart).key))?.nextSteps ?? ""
            loaded = true
        }
        .onChange(of: reflection) { _, _ in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(400)); save() } catch { }
            }
        }
        .onDisappear { saveTask?.cancel(); save() }
    }

    private func isBlank(_ html: String) -> Bool {
        Markdown.plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 困难的第一句（至多 60 字）作问题的题目
    private func firstSentence(_ html: String) -> String {
        let plain = Markdown.plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = plain.split(whereSeparator: { "。？！?!\n".contains($0) }).first.map(String.init) ?? plain
        return String(first.prefix(60))
    }

    private func save() {
        guard loaded, !store.fullBackupBusy else { return }
        do { try store.db.saveProgress(reflection, key: window.key); store.journeyRevision += 1 } catch { store.report(error) }
    }
}

// MARK: - 首页“本周复盘”

struct ReflectionHomeCard: View {
    @Environment(LibraryStore.self) private var store
    @State private var target: GrowthWindow?
    @State private var done: Date?
    @State private var sentences = GrowthReflection()
    @State private var last: Date?

    var body: some View {
        let isPrevious = target.map { $0.fullEnd <= Date() } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(isPrevious ? "上周复盘" : "本周复盘").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if let done {
                    Label("已于 \(ReflectionView.day(done)) 完成", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.done)
                } else {
                    Text(last.map { "上次复盘：\(ReflectionView.day($0))" } ?? "还没有做过复盘").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Button { store.openReflection(period: .week, date: target?.start) } label: {
                    HStack(spacing: 6) {
                        Text(done == nil ? "去复盘" : "查看").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(done == nil ? Color.white : ReviewPalette.ink)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(done == nil ? ReviewPalette.accent : ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).handCursor()
            }
            if done != nil {
                VStack(alignment: .leading, spacing: 4) {
                    line("收获", sentences.gains)
                    line("困难", sentences.challenges)
                    line("下一步", sentences.nextSteps)
                }
            } else {
                Text("约十分钟：看数字、看新材料、看自己的想法、过一遍常念问题，写下收获、困难与下一步。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        .task(id: "\(store.reflectionRevision)|\(store.journeyRevision)|\(store.today)") {
            let w = store.db.reflectionTargetWeek()
            target = w
            done = (try? store.db.reflectionProgress(w))?.completedAt
            sentences = (try? store.db.progressValue(GrowthReflection.self, key: w.key)) ?? GrowthReflection()
            last = try? store.db.lastReflection(period: .week)
        }
    }

    @ViewBuilder
    private func line(_ label: String, _ html: String) -> some View {
        let text = plainPreview(html, limit: 80)
        if !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub).frame(width: 42, alignment: .leading)
                Text(text).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
            }
        }
    }
}
