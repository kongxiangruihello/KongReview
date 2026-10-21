import SwiftUI
import KongReviewCore

// MARK: - 4.1.1：问题簿——列表、问题页、新建问题、挂到问题

extension Question.Status {
    var color: Color {
        switch self {
        case .open: ReviewPalette.pending
        case .lead: ReviewPalette.accent
        case .solved: ReviewPalette.done
        case .shelved: ReviewPalette.sub
        }
    }
}

/// 问题簿：跨专题、跨项目的全部问题；「常念」与当前项目的在前
struct QuestionBookView: View {
    @Environment(LibraryStore.self) private var store
    @State private var result = GrowthPage<QuestionSummary>(items: [], total: 0)
    @State private var drafts: [QuestionDraft] = []
    @State private var loading = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问题簿").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("把研究中的问题收在一处：一个问题可同时归入几个专题、几个项目，随时挂上摘录、札记与记忆卡。标上「常念」的十来个问题排在最前——遇到新材料时拿它们来试一试。")
                        .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { store.newQuestion() } label: { Label("记一个问题", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).handCursor()
                    TextField("搜索问题、说明与解答（繁简通搜）", text: $store.questionBookFilter.query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Picker("", selection: $store.questionBookFilter.state) {
                        ForEach(QuestionFilter.State.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                filterBar
                if !drafts.isEmpty { draftList }
                if result.items.isEmpty && !loading {
                    ContentUnavailableView(emptyTitle, systemImage: "questionmark.bubble",
                                           description: Text("在今日回顾按 Q，把当前摘录挂到问题下；也可在专题、项目页记下问题。"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(result.items) { q in QuestionRow(q: q).id(q.id) }
                }
                .scrollTargetLayout()
                if result.total > 50 { JourneyPager(page: $store.questionBookPage, total: result.total).disabled(loading) }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $store.questionBookAnchor, anchor: .top)
        .background(ReviewPalette.page)
        .navigationTitle("问题簿")
        .onChange(of: store.questionBookFilter) { _, _ in store.questionBookPage = 0; store.questionBookAnchor = nil }
        .task(id: "\(store.questionBookFilter.state)|\(store.questionBookFilter.query)|\(String(describing: store.questionBookFilter.notebookID))|\(String(describing: store.questionBookFilter.projectID))|\(store.questionBookPage)|\(store.questionRevision)|\(store.currentProjectID ?? 0)") {
            try? await Task.sleep(nanoseconds: store.questionBookFilter.query.isEmpty ? 0 : 250_000_000)
            guard !Task.isCancelled else { return }
            loading = true
            do {
                let page = try await store.db.questionPage(store.questionBookFilter, preferProjectID: store.currentProjectID, offset: store.questionBookPage * 50)
                guard !Task.isCancelled else { return }
                result = page; loading = false
                if store.questionBookPage > 0 && page.items.isEmpty { store.questionBookPage = max(0, (page.total - 1) / 50) }
            } catch is CancellationError {} catch { loading = false; store.report(error) }
            drafts = (try? store.db.questionDrafts()) ?? []
        }
    }

    private var emptyTitle: String {
        let f = store.questionBookFilter
        if !f.query.isEmpty || f.notebookID != nil || f.projectID != nil { return "没有符合条件的问题" }
        switch f.state {
        case .unsolved: return "暂时没有未解决的问题"
        case .solved: return "还没有已解决的问题"
        case .shelved: return "没有搁置的问题"
        case .all: return "还没有问题"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("全部项目") { store.questionBookFilter.projectID = nil }
                Divider()
                ForEach(store.researchProjects) { p in
                    Button { store.questionBookFilter.projectID = p.id } label: {
                        if p.id == store.questionBookFilter.projectID { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
            } label: {
                Label(store.questionBookFilter.projectID.flatMap { id in store.researchProjects.first { $0.id == id }?.title } ?? "按项目", systemImage: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("全部专题") { store.questionBookFilter.notebookID = nil }
                Divider()
                ForEach(store.notebooks) { n in
                    Button { store.questionBookFilter.notebookID = n.id } label: {
                        if n.id == store.questionBookFilter.notebookID { Label(n.title, systemImage: "checkmark") } else { Text(n.title) }
                    }
                }
            } label: {
                Label(store.questionBookFilter.notebookID.flatMap { id in store.notebooks.first { $0.id == id }?.title } ?? "按专题", systemImage: "book.closed")
            }
            .menuStyle(.borderlessButton).fixedSize()
            if store.questionBookFilter.projectID != nil || store.questionBookFilter.notebookID != nil {
                Button("清除筛选") { store.questionBookFilter.projectID = nil; store.questionBookFilter.notebookID = nil }
                    .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).font(.system(size: 12.5)).handCursor()
            }
            Spacer()
            Text("共 \(result.total) 个").font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
        }
        .font(.system(size: 12.5))
    }

    private var draftList: some View {
        DisclosureGroup("未保存的输入 · \(drafts.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(drafts) { d in QuestionDraftRow(draft: d) }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 13))
    }
}

/// 未保存的输入（问题页编辑时自动暂存；3.4 的专题问题草稿也迁到这里）
struct QuestionDraftRow: View {
    @Environment(LibraryStore.self) private var store
    let draft: QuestionDraft
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil").foregroundStyle(ReviewPalette.sub)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title.isEmpty ? "未命名问题" : draft.title).font(.system(size: 13)).lineLimit(2)
                Text((draft.questionId == nil ? "尚未保存的新问题" : "已有问题的修改") + " · 暂存于 \(draft.savedAt.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            }
            Spacer()
            Button(draft.questionId == nil ? "存为问题" : "继续编辑") { store.resumeQuestionDraft(draft) }.controlSize(.small).handCursor()
            Button("丢弃", role: .destructive) { store.discardQuestionDraft(draft) }.controlSize(.small).handCursor()
        }
    }
}

/// 问题簿的一行
struct QuestionRow: View {
    @Environment(LibraryStore.self) private var store
    let q: QuestionSummary
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { store.setQuestionPinned(q.id, !q.pinned) } label: {
                Image(systemName: q.pinned ? "star.fill" : "star").foregroundStyle(q.pinned ? Color.orange : ReviewPalette.sub)
            }
            .buttonStyle(.plain).frame(width: 18).handCursor()
            .help(q.pinned ? "取消「常念」" : "标为「常念」：常放在心里，排在最前")
            VStack(alignment: .leading, spacing: 4) {
                Text(q.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(3)
                if !q.preview.isEmpty { Text(q.preview).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).lineLimit(2) }
                HStack(spacing: 6) {
                    Label(q.status.title, systemImage: q.status.symbol).foregroundStyle(q.status.color)
                    Text("材料 \(q.materialCount)")
                    if q.hasAnswerNote { Text("解答见札记") }
                    if !q.scopes.isEmpty { Text(q.scopes).lineLimit(1) }
                    if let s = q.solvedAt { Text("解决于 \(s.formatted(.dateTime.year().month().day()))") }
                    else { Text("修改于 \(q.updatedAt.formatted(.dateTime.year().month().day()))") }
                }
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .question(q.id) }
        .handCursor()
    }
}

/// 问题页：左栏问题、解答与材料，右栏归属
struct QuestionView: View {
    @Environment(LibraryStore.self) private var store
    let questionId: Int64
    @State private var detail: QuestionDetail?
    @State private var missing = false
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftDetail = ""
    @State private var draftAnswer = ""
    @State private var checkedDraft = false
    @State private var restoredDraft = false
    @State private var picking: QuestionMaterial.Kind?
    @State private var confirmDelete = false
    @State private var reasons: [String: String] = [:]

    var body: some View {
        Group {
            if let d = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(d)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 18) {
                                main(d).frame(maxWidth: .infinity, alignment: .leading)
                                side(d).frame(width: 260)
                            }
                            .frame(minWidth: 720)
                            VStack(alignment: .leading, spacing: 18) { main(d); side(d) }
                        }
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
            } else if missing {
                ContentUnavailableView("这个问题已被删除", systemImage: "questionmark.bubble")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(detail?.question.title ?? "问题")
        .task(id: "\(questionId)|\(store.questionRevision)|\(store.ideaNoteRevision)") { await load() }
        .onChange(of: draftTitle) { _, _ in persistDraft() }
        .onChange(of: draftDetail) { _, _ in persistDraft() }
        .onChange(of: draftAnswer) { _, _ in persistDraft() }
        .onDisappear { if editing { commit(quiet: true) } }
        .sheet(item: $picking) { kind in
            HighlightPickerSheet(excluding: Set(detail?.materials.filter { $0.kind == kind }.map(\.recordId) ?? []),
                                 kind: kind == .note ? .note : (kind == .card ? .card : .highlight),
                                 title: "挂\(kind.title)", action: "挂上") { ids in
                store.addQuestionMaterial(questionId, kind: kind, recordIds: ids)
            }
            .environment(store)
        }
        .confirmationDialog("删除问题“\(detail?.question.title ?? "")”？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.deleteQuestion(questionId) }
        } message: { Text("挂着的材料本身不受影响。此操作无法撤销。") }
    }

    private var draftKey: String { QuestionDraft.prefix + QuestionDraft.id(questionId: questionId) }

    private func load() async {
        do {
            let d = try await store.db.questionDetail(id: questionId)
            detail = d; missing = false
            reasons = Dictionary(d.materials.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
            if !editing { draftTitle = d.question.title; draftDetail = d.question.detail; draftAnswer = d.question.answer }
            if !checkedDraft {
                checkedDraft = true
                // 上次编辑时暂存、还没保存的输入：恢复到编辑状态
                if let saved = try? store.db.progressValue(QuestionDraft.self, key: draftKey), saved.hasInput,
                   saved.title != d.question.title || saved.detail != d.question.detail || saved.answer != d.question.answer {
                    draftTitle = saved.title.isEmpty ? d.question.title : saved.title
                    draftDetail = saved.detail; draftAnswer = saved.answer
                    editing = true; restoredDraft = true
                }
            }
        } catch QuestionError.missing { detail = nil; missing = true }
        catch { store.report(error) }
    }

    private func persistDraft() {
        guard editing, let d = detail else { return }
        let changed = draftTitle != d.question.title || draftDetail != d.question.detail || draftAnswer != d.question.answer
        let draft = QuestionDraft(id: QuestionDraft.id(questionId: questionId), questionId: questionId,
                                  title: draftTitle, detail: draftDetail, answer: draftAnswer)
        if changed { store.saveQuestionDraft(draft) } else { try? store.db.deleteProgress(key: draftKey) }
    }

    private func commit(quiet: Bool = false) {
        guard let d = detail else { return }
        if draftTitle != d.question.title || draftDetail != d.question.detail || draftAnswer != d.question.answer {
            // 离开页面时只在能保存时保存，否则输入留在暂存里，下次打开时恢复
            if quiet {
                let answerOK = d.question.status != .solved || HTMLSourceCodec.hasContent(draftAnswer) || d.answerNote != nil
                guard !WikiLinks.normalize(draftTitle).isEmpty, answerOK else { return }
            }
            guard store.saveQuestion(id: questionId, title: draftTitle, detail: draftDetail, answer: draftAnswer) else { return }
        }
        try? store.db.deleteProgress(key: draftKey)
        editing = false; restoredDraft = false
    }

    private func discardEdits() {
        try? store.db.deleteProgress(key: draftKey)
        if let d = detail { draftTitle = d.question.title; draftDetail = d.question.detail; draftAnswer = d.question.answer }
        editing = false; restoredDraft = false
        store.questionRevision += 1
    }

    // MARK: 顶部

    private func header(_ d: QuestionDetail) -> some View {
        let q = d.question
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("问题", systemImage: "questionmark.bubble").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                Button { store.setQuestionPinned(questionId, !q.pinned) } label: {
                    Label("常念", systemImage: q.pinned ? "star.fill" : "star").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(q.pinned ? Color.orange : ReviewPalette.sub).handCursor()
                .help(q.pinned ? "取消「常念」" : "标为「常念」：常放在心里的问题，在问题簿与“挂到问题”中排在最前")
                Spacer()
                Menu {
                    ForEach(Question.Status.allCases) { s in
                        Button { store.setQuestionStatus(questionId, s) } label: {
                            if s == q.status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                        }
                    }
                } label: { Label(q.status.title, systemImage: q.status.symbol) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(q.status.color)
                    .help("待研究 → 有线索 → 已解决；另有“搁置”。挂上第一条材料时自动变为“有线索”；标为已解决前须有解答。")
                Button(editing ? "完成" : "编辑") {
                    if editing { commit() } else { draftTitle = q.title; draftDetail = q.detail; draftAnswer = q.answer; editing = true }
                }
                .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .buttonStyle(.borderedProminent).controlSize(.small).handCursor()
                .disabled(editing && WikiLinks.normalize(draftTitle).isEmpty)
                Menu {
                    if editing { Button("放弃这次修改") { discardEdits() } }
                    Button("删除问题…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if restoredDraft {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(ReviewPalette.accent)
                    Text("已恢复上次未保存的修改。点“完成”保存，或在右上角菜单中放弃。").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                }
                .padding(8).background(ReviewPalette.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            if editing {
                TextField("问题：一句话", text: $draftTitle, axis: .vertical)
                    .font(.system(size: 22, weight: .semibold, design: .serif)).textFieldStyle(.plain)
            } else {
                Text(q.title).font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(["记于 \(q.createdAt.formatted(.dateTime.year().month().day()))",
                  "修改于 \(q.updatedAt.formatted(.dateTime.year().month().day()))",
                  q.solvedAt.map { "解决于 \($0.formatted(.dateTime.year().month().day()))" },
                  "材料 \(d.materials.count)"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
        }
        .disabled(store.fullBackupBusy)
    }

    // MARK: 左栏

    @ViewBuilder private func main(_ d: QuestionDetail) -> some View {
        let q = d.question
        VStack(alignment: .leading, spacing: 18) {
            if editing {
                RichEditor(text: $draftDetail, placeholder: "补充说明：问题从何而来、已知什么、卡在哪里（可不填）", autoHeight: true, minHeight: 90, slot: "question-detail")
                    .richEditorFrame()
            } else if HTMLSourceCodec.hasContent(q.detail) {
                RichWebText(text: q.detail, style: .preview, slot: "question-detail-\(questionId)")
            }
            answerSection(d)
            materialSection(d)
        }
    }

    @ViewBuilder private func answerSection(_ d: QuestionDetail) -> some View {
        let q = d.question
        VStack(alignment: .leading, spacing: 8) {
            Text("解答").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            if let note = d.answerNote {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(ReviewPalette.accent)
                    Text("解答见札记").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                    Button("《\(note.title)》") { store.selection = .ideaNote(note.id) }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                    Spacer()
                    Button("取消指向") { store.setQuestionAnswerNote(questionId, noteId: nil) }
                        .controlSize(.small).handCursor()
                        .help(q.status == .solved && !HTMLSourceCodec.hasContent(q.answer) ? "已解决的问题须有解答：先写一段解答，或把状态改回去" : "解答不再指向这条札记；札记本身不变")
                }
                .padding(10).background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if editing {
                RichEditor(text: $draftAnswer, placeholder: d.answerNote == nil ? "答案或解释" : "（可另写几句补充）", autoHeight: true, minHeight: 120, slot: "question-answer")
                    .richEditorFrame()
                Text("⌘↩ 完成；输入自动暂存，离开后再回来可继续。").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            } else if HTMLSourceCodec.hasContent(q.answer) {
                RichWebText(text: q.answer, style: .preview, slot: "question-answer-\(questionId)")
            } else if d.answerNote == nil {
                Text("还没有解答。点“编辑”写下答案或解释，或把解答指向一条札记。").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
            if !editing {
                HStack(spacing: 14) {
                    if d.answerNote == nil {
                        Menu {
                            let notes = (try? store.db.recentIdeaNotes(limit: 40)) ?? []
                            if notes.isEmpty { Text("还没有札记") }
                            ForEach(notes) { n in Button(n.title) { store.setQuestionAnswerNote(questionId, noteId: n.id) } }
                        } label: { Label("解答指向札记…", systemImage: "lightbulb") }
                            .menuStyle(.borderlessButton).fixedSize()
                        if HTMLSourceCodec.hasContent(q.answer) {
                            Button { store.writeQuestionAsNote(questionId) } label: { Label("写成札记", systemImage: "square.and.pencil") }
                                .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                                .help("新写一条札记：问题为题、解答为正文，带上问题下的摘录；问题的解答改为指向这条札记")
                        }
                    }
                    if q.status != .solved, HTMLSourceCodec.hasContent(q.answer) || d.answerNote != nil {
                        Button { store.setQuestionStatus(questionId, .solved) } label: { Label("标为已解决", systemImage: "checkmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(ReviewPalette.done).handCursor()
                    }
                    if q.status == .solved {
                        Button { store.setQuestionStatus(questionId, .lead) } label: { Label("重新打开", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.plain).foregroundStyle(ReviewPalette.sub).handCursor()
                            .help("问题还没真正解决：改回“有线索”，解答保留，不再计入本期已解决")
                    }
                }
                .font(.system(size: 12.5))
            }
        }
    }

    @ViewBuilder private func materialSection(_ d: QuestionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("材料 · \(d.materials.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                Spacer()
                Menu {
                    Button("挂摘录…") { picking = .highlight }
                    Button("挂札记…") { picking = .note }
                    Button("挂记忆卡…") { picking = .card }
                } label: { Label("挂材料", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12.5))
            }
            if d.materials.isEmpty {
                Text("与这个问题有关的摘录、札记、记忆卡：点“挂材料”搜索添加，或在今日回顾时按 Q 把当前摘录挂上来。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(d.materials) { m in materialRow(m) }
        }
    }

    private func materialRow(_ m: QuestionMaterial) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: m.kind.symbol).font(.system(size: 12)).foregroundStyle(ReviewPalette.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title).font(.system(size: 14, design: m.kind == .note ? .default : .serif)).foregroundStyle(ReviewPalette.ink)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                Text("\(m.kind.title)\(m.context.isEmpty ? "" : " · " + m.context)").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                TextField("为什么挂在这里（回车保存）", text: Binding(get: { reasons[m.id] ?? m.reason }, set: { reasons[m.id] = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                    .onSubmit { store.setQuestionMaterialReason(questionId, m, reason: reasons[m.id] ?? m.reason) }
            }
            Spacer(minLength: 6)
            Menu {
                Button("打开") { open(m) }
                Button("不再挂在这里", role: .destructive) { store.removeQuestionMaterial(questionId, m) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func open(_ m: QuestionMaterial) {
        switch m.kind {
        case .note: store.selection = .ideaNote(m.recordId)
        case .highlight: store.openGlobalSearchResult(GlobalSearchTarget(kind: .highlight, recordID: m.recordId))
        case .card: store.openGlobalSearchResult(GlobalSearchTarget(kind: .card, recordID: m.recordId))
        case .block: if let n = m.parentId { store.selection = .notebook(n) }
        }
    }

    // MARK: 右栏

    private func side(_ d: QuestionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectPanel(title: "归属", subtitle: d.scopes.isEmpty ? "未归入" : "\(d.scopes.count) 处") {
                if d.scopes.isEmpty {
                    Text("归入专题或项目后，专题页的“问题与解答”和项目页的“未解问题”都会列出它。")
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(d.scopes) { s in
                    HStack(spacing: 6) {
                        Button {
                            store.selection = s.kind == .notebook ? .notebook(s.recordId) : .project(s.recordId)
                        } label: {
                            Label(s.title, systemImage: s.kind == .notebook ? "book.closed" : "folder").font(.system(size: 13)).lineLimit(2)
                        }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.accent).handCursor()
                        Spacer(minLength: 4)
                        Button { store.setQuestionScope(questionId, kind: s.kind, recordId: s.recordId, included: false) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(ReviewPalette.sub).handCursor().help("不再归入")
                    }
                }
                HStack(spacing: 12) {
                    scopeMenu("归入专题", kind: .notebook, items: store.notebooks.compactMap { n in n.id.map { ScopeChoice(id: $0, title: n.title) } }, current: d.scopes)
                    scopeMenu("归入项目", kind: .project, items: store.researchProjects.compactMap { p in p.id.map { ScopeChoice(id: $0, title: p.title) } }, current: d.scopes)
                }
                .font(.system(size: 12.5))
            }
            ProjectPanel(title: "状态的意思", subtitle: "") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Question.Status.allCases) { s in
                        Label(s.title + "：" + statusHint(s), systemImage: s.symbol).font(.system(size: 12)).foregroundStyle(s == d.question.status ? s.color : ReviewPalette.sub)
                    }
                }
            }
        }
    }

    private func statusHint(_ s: Question.Status) -> String {
        switch s {
        case .open: "刚记下，还没有材料"
        case .lead: "已挂上材料，正在想"
        case .solved: "有了解答；可写成札记"
        case .shelved: "暂时放下，不在未解列表中"
        }
    }

    private func scopeMenu(_ title: String, kind: QuestionScope.Kind, items: [ScopeChoice], current: [QuestionScope]) -> some View {
        let ids = Set(current.filter { $0.kind == kind }.map(\.recordId))
        return Menu {
            if items.isEmpty { Text(kind == .notebook ? "还没有专题笔记本" : "还没有在研项目") }
            ForEach(items) { item in
                Button {
                    store.setQuestionScope(questionId, kind: kind, recordId: item.id, included: !ids.contains(item.id))
                } label: {
                    if ids.contains(item.id) { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        } label: { Label(title, systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
    }
}

/// 归入菜单的一项
private struct ScopeChoice: Identifiable {
    var id: Int64
    var title: String
}

/// 新建问题：一句话的问题与补充说明；从专题、项目或“挂到问题”进来时预先归入、预先挂上材料
struct QuestionCreateSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: QuestionCreateRequest
    @State private var title = ""
    @State private var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("记一个问题").font(.title2.bold())
            if let m = request.material {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(ReviewPalette.accent.opacity(0.6)).frame(width: 3)
                    Text(m.preview + "…").font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.sub).lineLimit(2)
                }
            }
            TextField("问题：一句话（如“乾嘉学者为何讳言义理？”）", text: $title).textFieldStyle(.roundedBorder).font(.system(size: 15))
            RichEditor(text: $detail, placeholder: "补充说明（可不填）", autoHeight: true, minHeight: 100, slot: "question-create")
                .richEditorFrame()
            let scopes = [request.notebookID.flatMap { id in store.notebooks.first { $0.id == id }.map { "专题《\($0.title)》" } },
                          request.projectID.flatMap { id in store.researchProjects.first { $0.id == id }.map { "项目《\($0.title)》" } }].compactMap { $0 }
            if !scopes.isEmpty { Text("将归入 " + scopes.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("保存问题") {
                    if store.createQuestion(title: title, detail: detail, notebookID: request.notebookID, projectID: request.projectID,
                                            material: request.material, open: request.material == nil) != nil { close() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(WikiLinks.normalize(title).isEmpty || store.fullBackupBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360)
    }

    private func close() {
        store.questionCreator = nil
        dismiss()
    }
}

/// 挂到问题：选一个未解决的问题（「常念」与当前项目的在前），把当前材料挂上；也可当场新建问题
struct QuestionAttachSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: QuestionAttachRequest
    var onClose: () -> Void = {}
    @State private var query = ""
    @State private var reason = ""
    @State private var newTitle = ""
    @State private var inCurrentProject = true
    @State private var candidates: [QuestionSummary] = []

    var body: some View {
        let holding = Set((store.questionsHolding(request.kind, [request.recordId])[request.recordId] ?? []).map(\.id))
        VStack(alignment: .leading, spacing: 12) {
            Text("挂到问题").font(.title2.bold())
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(ReviewPalette.accent.opacity(0.6)).frame(width: 3)
                Text("\(request.kind.title)：" + request.preview + "…").font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.sub).lineLimit(2)
            }
            TextField("为什么挂在这里（可不填）", text: $reason).textFieldStyle(.roundedBorder)
            TextField("搜索未解决的问题", text: $query).textFieldStyle(.roundedBorder)
            List(candidates) { q in
                let already = holding.contains(q.id)
                Button {
                    store.addQuestionMaterial(q.id, kind: request.kind, recordIds: [request.recordId], reason: reason)
                    close()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: q.pinned ? "star.fill" : q.status.symbol).foregroundStyle(q.pinned ? Color.orange : q.status.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.title).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                            Text([q.status.title, "材料 \(q.materialCount)", q.scopes, already ? "已挂过（再选只更新说明）" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain).handCursor()
            }
            .frame(minHeight: 220)
            Divider()
            HStack(spacing: 8) {
                TextField("或新建一个问题并挂上", text: $newTitle).textFieldStyle(.roundedBorder)
                Button("新建并挂上") {
                    let project = inCurrentProject ? store.currentProjectID : nil
                    if store.createQuestion(title: newTitle, projectID: project, material: request, reason: reason) != nil { close() }
                }
                .disabled(WikiLinks.normalize(newTitle).isEmpty || store.fullBackupBusy)
            }
            if let p = store.currentProjectID.flatMap({ id in store.researchProjects.first { $0.id == id } }) {
                Toggle("新问题归入当前项目《\(p.title)》", isOn: $inCurrentProject).toggleStyle(.checkbox).font(.system(size: 12.5))
            }
            HStack {
                Text("挂上第一条材料时，“待研究”的问题自动变为“有线索”。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 520)
        .task(id: query) {
            try? await Task.sleep(nanoseconds: query.isEmpty ? 0 : 200_000_000)
            guard !Task.isCancelled else { return }
            var f = QuestionFilter(); f.query = query
            candidates = (try? await store.db.questionPage(f, preferProjectID: store.currentProjectID, limit: 50))?.items ?? []
        }
    }

    private func close() {
        onClose()
        dismiss()
    }
}
