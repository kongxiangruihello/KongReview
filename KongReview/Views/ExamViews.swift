import SwiftUI
import KongReviewCore

// MARK: - 6.0.3：今日试卷
//
// 一张卷子、一个入口：记忆卡、摘录、札记、笔记、问题交错出题，一律先想、再展开对照、再判分。
// 卷面上方是进度与打卡；答完（或提前交卷）在下方出成绩单：日评、打卡、一年的打卡图。

struct ExamView: View {
    @Environment(LibraryStore.self) private var store
    @State private var paper = ExamPaperState()
    @State private var current: ExamQuestion?
    /// 6.0.7：这一道是卷尾再考
    @State private var relearnItem: ExamRelearnItem?
    @State private var turn = 0
    /// 6.3.4：还在等的补考与新录
    @State private var backlog: (retests: Int, fresh: Int) = (0, 0)
    @State private var loaded = false
    @State private var reload = 0
    @State private var revealed = false
    @State private var myAnswer = ""
    @State private var noteGrade: SelfTestResult?
    @State private var fresh: [Highlight] = []
    @State private var picked: Set<Int64> = []
    @State private var remark = ""
    @State private var tally = MasteryTally()
    @State private var organize: [OrganizeBlockItem] = []
    /// 6.2：答题时编辑这道题
    @State private var editRequest: ExamEditRequest?
    @FocusState private var typing: Bool

    var body: some View {
        let state = store.dailyCheck
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(state)
                MakeupCard()   // 6.3.5
                CheckinStatusStrip()
                StreakBreakPrompt()
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let q = current {
                    questionView(q).id(q.key)
                } else {
                    finished(state)
                }
                if loaded { jotBar }
                AnnotateSection()
                if loaded && (current == nil || store.examHandedIn) {
                    reportCard
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
            .sheet(item: $editRequest) { r in
                ExamEditSheet(request: r) { updated in current = updated }.environment(store)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle("今日日课")
        .sheet(item: Bindable(store).annotating) { AnnotateSheet(request: $0) }
        .task(id: "\(store.today)|\(reload)") { load() }
        // 6.3.2：在原来的编辑窗口里改了记忆卡、摘录，保存后卷面换成改过的内容
        .onChange(of: store.revision) {
            if let q = current, let fresh = store.examRefreshed(q), fresh != q { current = fresh }
        }
        .task(id: "\(store.dailyCheckRevision)|\(store.revisitRevision)") {
            tally = (try? store.db.examTally()) ?? MasteryTally()
            backlog = store.examBacklog()
            organize = (try? store.db.blocksToOrganize()) ?? []
        }
    }

    // MARK: 组卷

    private func load() {
        paper = store.examPaper()
        if let pick = ExamRotation.next(turn: turn, available: paper.available) {
            current = paper.question(pick.kind, day: Date())
            turn = pick.turn
            relearnItem = nil
        } else if let pair = store.examRelearnNext() {
            // 6.0.7：常规的题答完了，忘了的再考一次
            current = pair.1
            relearnItem = pair.0
        } else {
            current = nil
            relearnItem = nil
        }
        revealed = false
        myAnswer = ""
        noteGrade = nil
        picked = []
        remark = ""
        typing = false
        loadFresh()
        loaded = true
    }

    private func next() {
        reload += 1
    }

    private func loadFresh() {
        switch current {
        case .question(let q):
            let text = q.title + "\n" + Markdown.plainText(fromHTML: q.detail)
            fresh = store.revisitNewHighlights(text: text, since: q.since, excluding: q.highlightIDs, limit: 5)
        default:
            fresh = []
        }
    }

    /// 在输入框里打字时，单键快捷键失效
    private func key(_ k: KeyEquivalent) -> KeyboardShortcut? {
        typing ? nil : KeyboardShortcut(k, modifiers: [])
    }

    // MARK: 页头

    private func header(_ s: DailyCheckState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日日课").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text(ExamDate.line()).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                Spacer()
                if s.due > 0 {
                    Text("已做 \(s.done) / \(s.due)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.left == 0 ? ReviewPalette.done : ReviewPalette.ink)
                }
            }
            if let c = s.completion {
                ProgressView(value: c).tint(s.left == 0 ? ReviewPalette.done : ReviewPalette.accent)
            }
            // 6.1.0：窄时各组进度一行、卷尾再考与“先交卷”另起一行，不再把字挤成两行
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { headerRows(s); Spacer(minLength: 8); headerActions }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) { headerRows(s) }
                    HStack(spacing: 14) { headerActions; Spacer() }
                }
            }
            // 6.3.4：补考与新录还排着多少，免得积压了看不见
            if backlog.retests + backlog.fresh > 0 {
                Label(([backlog.retests > 0 ? "待补考 \(backlog.retests) 条" : nil, backlog.fresh > 0 ? "新录待考 \(backlog.fresh) 条" : nil] as [String?])
                    .compactMap { $0 }.joined(separator: " · "), systemImage: "tray.full")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                    .help("含今天日课上还没答的。忘了的摘录两天后起补考，先忘的在前，每天至多 \(AppDatabase.examRetestPerDay) 条，补考过才不再排；新录的摘录 30 天内考两次，先录的在前，每天的条数在设置里改。两类与卡片屡错的摘录合计至多占每天摘录题的一半。")
            }
            Text("一律先想、再展开对照、再判分：先提取后对照，比重读记得牢。题目按各自的到期日出，日课上交错排列；中途离开，回来接着答。")
                .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func headerRows(_ s: DailyCheckState) -> some View {
        ForEach(s.rows) { row in
            Label("\(row.group.title) \(min(row.done, row.due))/\(row.due)", systemImage: row.group.symbol)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(row.due > 0 && row.done >= row.due ? ReviewPalette.done : ReviewPalette.sub)
                .lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        let relearn = store.examRelearn
        if !relearn.items.isEmpty || relearn.passed + relearn.failed > 0 {
            Label("课末再练 \(relearn.items.count) 道" + (relearn.passed > 0 ? " · 已过关 \(relearn.passed)" : ""), systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(relearn.items.isEmpty ? ReviewPalette.done : ReviewPalette.pending)
                .lineLimit(1).fixedSize()
                .help("今天答“忘了”的摘录题、论证题、解答题与“需重读”的复述题，在常规的题答完后再练一次，答对才算过关；每道至多再练两轮。课末再练不记入掌握度。")
        }
        if current != nil && !store.examHandedIn {
            Button("先收工，看今日小结") { store.examHandedIn = true }
                .buttonStyle(.link).font(.system(size: 12)).handCursor()
                .lineLimit(1).fixedSize()
                .help("还没答的题仍留在日课上，随时可以接着答")
        }
    }

    // MARK: 题

    @ViewBuilder
    private func questionView(_ q: ExamQuestion) -> some View {
        switch q {
        case .card(let c): cardQuestion(c)
        case .highlight(let h, let mode): highlightQuestion(h, mode)
        case .note(let n): noteQuestion(n)
        case .block(let k): blockQuestion(k)
        case .question(let item): progressQuestion(item)
        case .answer(let item): answerQuestion(item)
        }
    }

    private func badge(_ kind: ExamKind, _ title: String, _ detail: String = "") -> some View {
        HStack(spacing: 8) {
            if let r = relearnItem {
                Label("课末再练 · 第 \(r.rounds + 1) 轮", systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.pending)
            }
            Label(kind.title + " · " + title, systemImage: kind.symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
            Spacer()
            // 6.3.2：记忆卡、摘录用原来的编辑窗口（与记忆卡学习页的“编辑这张卡”、摘录列表的编辑相同）；
            // 札记、笔记、问题仍用 6.2 的“编辑这道题”。改完回到日课，展开与否、“我的回答”不动
            if let q = current {
                switch q {
                case .card(let c):
                    Button { store.editCard(c) } label: { Label("编辑这张卡", systemImage: "square.and.pencil") }
                        .buttonStyle(.link).font(.system(size: 12)).handCursor()
                        .keyboardShortcut("e", modifiers: .command)
                        .help("打开记忆卡的编辑窗口（与学习页的“编辑这张卡”相同），改完回到日课（⌘E）")
                case .highlight(let h, _):
                    Button { store.edit(h) } label: { Label("编辑这条摘录", systemImage: "square.and.pencil") }
                        .buttonStyle(.link).font(.system(size: 12)).handCursor()
                        .keyboardShortcut("e", modifiers: .command)
                        .help("打开摘录的编辑窗口（与摘录列表里的编辑相同），改完回到日课（⌘E）")
                default:
                    Button { editRequest = store.examEditRequest(q) } label: { Label("编辑这道题", systemImage: "square.and.pencil") }
                        .buttonStyle(.link).font(.system(size: 12)).handCursor()
                        .keyboardShortcut("e", modifiers: .command)
                        .help("改这道题的内容（HTML 源码，即时预览），改完回到日课；展开与否、“我的回答”不动（⌘E）")
                }
            }
        }
    }

    private func revealButton(_ title: String = "想好了，展开对照") -> some View {
        PillButton(icon: "chevron.down", title: title, key: "空格", style: .primary) { revealed = true; typing = false }
            .keyboardShortcut(key(.space))
            .padding(.top, 14)
    }

    private func think(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(ReviewPalette.sub)
            Text(text).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
    }

    // 记忆卡：作答题

    private func cardQuestion(_ c: Card) -> some View {
        let f = store.faces(of: c)
        return VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 24) {
                badge(.card, "作答题", "牌组 " + c.deck)
                CardWebView(front: f.front, back: revealed ? f.back : nil, store: store, css: store.cardCSS(for: c))
                    .frame(height: revealed ? 260 : 190)
                    .padding(.top, 10)
                if !revealed {
                    TextField("我的回答（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($typing)
                        .padding(.top, 10)
                    revealButton("显示答案")
                } else if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    // 6.2.2：记忆卡也对照要点（以背面为准）
                    if let m = cardMatch(c) { ideaUnitsPanel(m) }
                }
            }
            if revealed {
                HStack(spacing: 10) {
                    ForEach(CardAnswer.allCases, id: \.self) { a in
                        PillButton(title: a.label, key: "\(a.rawValue)", style: a == .good ? .primary : .normal) {
                            calibrate(.card, c.id, cardMatch(c), SelfTestResult(card: a))
                            store.examAnswerCard(c, a); next()
                        }
                        .keyboardShortcut(key(KeyEquivalent(Character("\(a.rawValue)"))))
                    }
                    Spacer()
                }
            }
        }
    }

    // 摘录：要点题、出处题

    private func plain(_ html: String) -> String {
        Markdown.plainText(fromHTML: Markdown.richHTML(html)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cite(_ h: Highlight) -> String {
        let s = store.source(for: h)
        return [s?.author ?? "", s.map { "《\($0.title)》" } ?? "", h.location ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 6.3.6：译文与按语，排版同回顾（译文 16px 次要色；按语 14px、左侧色条），保留原格式
    @ViewBuilder private func highlightExtras(_ h: Highlight) -> some View {
        if let t = h.translation, !plain(t).isEmpty {
            RichWebText(text: t, style: .translation, slot: "exam-highlight-translation")
                .padding(.top, 16)
        }
        if let n = h.note, !plain(n).isEmpty {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.7)).frame(width: 3)
                RichWebText(text: n, style: .note, slot: "exam-highlight-note")
            }
            .padding(.top, 18)
        }
    }

    private func highlightQuestion(_ h: Highlight, _ mode: ExamHighlightMode) -> some View {
        let text = plain(h.text)
        let note = plain(h.note ?? "")
        return VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                // 6.0.8：新录的标出第几次
                badge(.highlight, mode.title, [store.examFreshRound(h.id).map { "新录 · 第 \($0) 次" }, h.isFavorite ? "已收藏" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                VStack(alignment: .leading, spacing: 12) {
                    switch mode {
                    case .source:
                        // 6.3.4：题面的原文与回顾、展开后的原文同一套排版（宋体 22px、行高 1.75、段间留白）
                        RichWebText(text: h.text, style: .highlight, slot: "exam-highlight-question")
                        Text("这段话出自哪本书？作者是谁？大致在什么位置？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    case .gist:
                        Text(cite(h)).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        if !note.isEmpty, !revealed {
                            Text("按语：" + note).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("这一处原文说了什么？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    case .opening:
                        let opening = text.replacingOccurrences(of: "\n", with: " ")
                        Text("开头：" + (opening.count > 10 ? String(opening.prefix(10)) + "……" : opening))
                            .font(.system(size: 18, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        if !note.isEmpty, !revealed {
                            Text("按语：" + note).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        if !h.tags.isEmpty {
                            Text(h.tags.map { "#" + $0 }.joined(separator: " ")).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                        }
                        Text("这条摘录说了什么？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    }
                }
                .padding(.top, 14)
                if revealed {
                    Divider().padding(.vertical, 14)
                    if mode == .source {
                        Text(cite(h).isEmpty ? "（没有出处信息）" : cite(h))
                            .font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.accent)
                    } else {
                        RichWebText(text: h.text, style: .highlight, slot: "exam-highlight")
                        if !cite(h).isEmpty { Text("——" + cite(h)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).padding(.top, 6) }
                    }
                    // 6.3.6：展开后译文、按语也照回顾里的样子显示（此前日课上不显示译文，出处题不显示按语）
                    highlightExtras(h)
                    if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                    if relearnItem == nil, let m = highlightMatch(h, mode) { ideaUnitsPanel(m) }
                } else {
                    // 6.0.7：先写下来再对照（可不写）
                    TextField(mode == .source ? "我的回答：书名、作者、大致位置（可不写）" : "我的回答：这一处说了什么（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($typing)
                        .padding(.top, 12)
                    revealButton()
                }
            }
            if revealed, let item = relearnItem {
                VStack(alignment: .leading, spacing: 8) {
                    gradeButtons { r in store.examRelearnAnswer(item, passed: r == .remembered); next() }
                    Text("课末再练：答“记得”才算过关；没过的排到后面再练一轮。这一次不记入掌握度。")
                        .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
            } else if revealed {
                VStack(alignment: .leading, spacing: 8) {
                    gradeButtons { r in calibrate(.highlight, h.id, highlightMatch(h, mode), r); store.examAnswerHighlight(h, mode: mode, result: r); next() }
                    HStack(spacing: 14) {
                        Button("记得，并收藏") {
                            calibrate(.highlight, h.id, highlightMatch(h, mode), .remembered)
                            store.examAnswerHighlight(h, mode: mode, result: .remembered, action: .favorite); next()
                        }
                            .keyboardShortcut(key("f"))
                        KeyCap(text: "F")
                        Button("记得，以后不再出（弃置）") {
                            calibrate(.highlight, h.id, highlightMatch(h, mode), .remembered)
                            store.examAnswerHighlight(h, mode: mode, result: .remembered, action: .discard); next()
                        }
                            .keyboardShortcut(key("d"))
                        KeyCap(text: "D")
                        Spacer()
                        Button("做成记忆卡") { store.makeCard(from: h) }.handCursor()
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                    Text("忘了的今天课末再练一次，两天后起回到日课上补练；记得的，隔得越来越久才再出。")
                        .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
            }
        }
    }

    // MARK: 6.2：做题时随手记

    /// 不离开卷子：摘录用快速录入浮窗（出处沿用这道题的），札记用随手札记浮窗（挂上这道题的摘录）
    private var jotBar: some View {
        let ctx = store.examCaptureContext(current)
        return HStack(spacing: 12) {
            Image(systemName: "square.and.pencil").foregroundStyle(ReviewPalette.sub)
            Text("随手记").font(.system(size: 12.5, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            Button { store.examCaptureHighlight(ctx) } label: { Label("记一条摘录", systemImage: "text.quote") }
                .help(ctx.source.map { "快速录入浮窗；出处先填《\($0.title)》，剪贴板里新复制的文字自动填入正文" } ?? "快速录入浮窗；剪贴板里新复制的文字自动填入正文")
            Button { QuickNoteController.shared.show(LibraryStore.examNoteComposer(ctx)) } label: { Label("写一条札记", systemImage: "lightbulb") }
                .help(ctx.highlight != nil ? "随手札记浮窗；挂上这道题的摘录，也可改为加入已有札记" : "随手札记浮窗")
            Spacer()
            Text("浮窗写完收起，日课照旧；别处也可按 \(HotKeyPreset.current.label) 记摘录" + (HotKeyPreset.note == .off ? "" : "、\(HotKeyPreset.note.label) 写札记"))
                .font(.system(size: 11)).foregroundStyle(ReviewPalette.sub).lineLimit(1).truncationMode(.tail)
        }
        .buttonStyle(.link).font(.system(size: 12.5)).handCursor()
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReviewPalette.hair))
    }

    // MARK: 6.2：对照要点

    private var writtenAnswer: String? {
        let t = myAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 摘录题：出处题对照作者、书名、位置；要点题、开头题对照原文（有加粗、标记的以标出的为要点）
    private func highlightMatch(_ h: Highlight, _ mode: ExamHighlightMode) -> IdeaUnitMatch? {
        guard let answer = writtenAnswer else { return nil }
        if mode == .source {
            let s = store.source(for: h)
            let units = [s?.author ?? "", s?.title ?? "", h.location ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return units.isEmpty ? nil : IdeaUnits.match(answer: answer, units: units)
        }
        let text = ExamHighlightMode.withoutImages(h.text)
        let m = IdeaUnits.match(answer: answer, standard: Markdown.plainText(fromHTML: Markdown.richHTML(text)), marked: IdeaUnits.markedSpans(in: text))
        return m.total > 0 ? m : nil
    }

    /// 解答题：对照解答；解答为空而指向札记的，对照札记正文
    private func answerMatch(_ a: RevisitAnswerItem) -> IdeaUnitMatch? {
        guard let answer = writtenAnswer else { return nil }
        let source = plain(a.answer).isEmpty ? (a.noteBody ?? "") : a.answer
        let text = WikiLinks.plain(source)
        let m = IdeaUnits.match(answer: answer, standard: Markdown.plainText(fromHTML: Markdown.richHTML(text)), marked: IdeaUnits.markedSpans(in: text))
        return m.total > 0 ? m : nil
    }

    /// 6.2.2：记忆卡以背面为准（模板卡取背面的字段；原文里加粗、标记的为要点）
    private func cardMatch(_ c: Card) -> IdeaUnitMatch? {
        guard let answer = writtenAnswer else { return nil }
        var standard = c.back
        if let t = c.noteType.flatMap({ store.noteTemplates[$0] }), !c.fields.isEmpty {
            standard = t.back.filter { $0 < c.fields.count }.map { c.fields[$0] }.joined(separator: "\n")
        }
        return Self.match(answer, standard)
    }

    /// 6.2.2：论证题以札记正文为准
    private func noteMatch(_ n: RevisitNoteItem) -> IdeaUnitMatch? {
        guard let answer = writtenAnswer else { return nil }
        return Self.match(answer, WikiLinks.plain(n.body))
    }

    /// 6.2.2：复述题以这一段为准
    private func blockMatch(_ k: RevisitBlockItem) -> IdeaUnitMatch? {
        guard let answer = writtenAnswer else { return nil }
        return Self.match(answer, k.text)
    }

    private static func match(_ answer: String, _ source: String) -> IdeaUnitMatch? {
        let m = IdeaUnits.match(answer: answer, standard: Markdown.plainText(fromHTML: Markdown.richHTML(source)),
                                marked: IdeaUnits.markedSpans(in: source))
        return m.total > 0 ? m : nil
    }

    private func calibrate(_ kind: CalibrationKind, _ id: Int64?, _ match: IdeaUnitMatch?, _ r: SelfTestResult) {
        guard let id, let match else { return }
        store.examRecordCalibration(kind, recordId: id, match: match, result: r)
    }

    /// 写出了几处要点；只作对照，分数仍由自己判
    private func ideaUnitsPanel(_ m: IdeaUnitMatch) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(ReviewPalette.sub)
                Text("要点对照：写出 \(m.hits) / \(m.total) 处").font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
            }
            ForEach(Array(m.units.enumerated()), id: \.offset) { _, u in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: u.hit ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(u.hit ? ReviewPalette.done : ReviewPalette.sub)
                    Text(u.text).font(.system(size: 12.5)).foregroundStyle(u.hit ? ReviewPalette.ink : ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("按标点把答案分成几处（原文里加粗、标记的以标出的为准），每处的字有一半以上出现在回答里算写出。只作对照，分数仍由你判；判“记得”而写出不到一半的，成绩册记为自评偏高。")
                .font(.system(size: 11)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 10)
    }

    private func gradeButtons(_ grade: @escaping (SelfTestResult) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach([SelfTestResult.remembered, .partly, .forgot], id: \.rawValue) { r in
                PillButton(title: r.title, key: "\(r.rawValue)", style: r == .remembered ? .primary : .normal) { grade(r) }
                    .keyboardShortcut(key(KeyEquivalent(Character("\(r.rawValue)"))))
            }
            Spacer()
        }
    }

    // 札记：论证题

    private func noteQuestion(_ n: RevisitNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                badge(.note, "论证题", n.lastReviewedAt == nil ? "第一次做" : "")
                Text(n.title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                if revealed {
                    VStack(alignment: .leading, spacing: 12) {
                        if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if plain(n.body).isEmpty {
                            Text("（还没有正文）").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                        } else {
                            RichWebText(text: WikiLinks.plain(n.body), style: .preview, slot: "exam-note")
                        }
                        if !n.highlights.isEmpty {
                            Text("引用的摘录 \(n.highlights.count) 条").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                            ForEach(n.highlights.prefix(5), id: \.id) { h in quoteRow(h) }
                        }
                        if relearnItem == nil, let m = noteMatch(n) { ideaUnitsPanel(m) }
                    }
                    .padding(.top, 16)
                } else {
                    think("为什么这么看？依据是哪些材料？想好了再展开正文对照。")
                    // 6.2.2：先写下来再对照（可不写）
                    TextField("我的回答：理由与依据（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($typing).padding(.top, 12)
                    revealButton()
                }
            }
            if revealed, let item = relearnItem {
                VStack(alignment: .leading, spacing: 6) {
                    Text("课末再练：理由与依据这回想起来了吗？").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    gradeButtons { r in store.examRelearnAnswer(item, passed: r == .remembered); next() }
                }
            } else if revealed {
                if let g = noteGrade {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已记：\(g.title)。还这么看吗？").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                        choices([
                            ("1", "仍然这么看", "checkmark", "下次在 \(AppDatabase.nextNoteInterval(after: n.intervalDays)) 天后", { store.examAnswerNote(n, result: g, outcome: .agree); next() }),
                            ("2", "要修订", "pencil", "打开札记修改，间隔从头算", { store.examAnswerNote(n, result: g, outcome: .revise) }),
                            ("3", "以后再说", "clock", "一周后再来", { store.examAnswerNote(n, result: g, outcome: .later); next() }),
                        ])
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("理由与依据想起来多少？").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                        gradeButtons { r in calibrate(.note, n.id, noteMatch(n), r); noteGrade = r }
                    }
                }
            }
        }
    }

    private func quoteRow(_ h: Highlight) -> some View {
        let text = plain(h.text).replacingOccurrences(of: "\n", with: " ")
        return VStack(alignment: .leading, spacing: 3) {
            Text(text.count > 140 ? String(text.prefix(138)) + "…" : text)
                .font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !cite(h).isEmpty { Text(cite(h)).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub) }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
    }

    // 笔记：复述题

    private func blockQuestion(_ k: RevisitBlockItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                badge(.block, "复述题")
                Text("《\(k.notebookTitle)》" + (k.heading.map { " · " + $0 } ?? ""))
                    .font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                if revealed {
                    if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    }
                    RichWebText(text: Markdown.richHTML(k.text), style: .preview, slot: "exam-block").padding(.top, 16)
                    if relearnItem == nil, let m = blockMatch(k) { ideaUnitsPanel(m) }
                } else {
                    Text("这一段开头：" + k.opening).font(.system(size: 14, design: .serif)).foregroundStyle(ReviewPalette.sub).padding(.top, 10)
                    think("先合上想一想：这一段说了什么？要点是哪几条？想好了再展开对照。")
                    // 6.2.2：先写下来再对照（可不写）
                    TextField("我的回答：这一段的要点（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($typing).padding(.top, 12)
                    revealButton("展开这一段")
                }
            }
            if revealed, let item = relearnItem {
                choices([
                    ("1", "记起来了", "checkmark", "过关", { store.examRelearnAnswer(item, passed: true); next() }),
                    ("2", "还是想不起", "arrow.uturn.backward", "排到后面再练一轮；明天以后按“需重读”的间隔回来", { store.examRelearnAnswer(item, passed: false); next() }),
                ])
            } else if revealed {
                choices([
                    ("1", "已吸收", "checkmark", "能说出要点；下次在 \(AppDatabase.nextNoteInterval(after: k.intervalDays)) 天后", { calibrate(.block, k.id, blockMatch(k), SelfTestResult(block: .absorbed)); store.examAnswerBlock(k, .absorbed); next() }),
                    ("2", "需重读", "arrow.uturn.backward", "说不出或说错；\(AppDatabase.blockRereadDays) 天后再来", { calibrate(.block, k.id, blockMatch(k), SelfTestResult(block: .reread)); store.examAnswerBlock(k, .reread); next() }),
                    ("3", "待整理", "tray.full", "内容还乱；一周后再来，列入今日小结下的“待整理”", { calibrate(.block, k.id, blockMatch(k), SelfTestResult(block: .organize)); store.examAnswerBlock(k, .organize); next() }),
                ])
            }
        }
    }

    // 问题：进展题

    private func progressQuestion(_ q: RevisitQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                badge(.question, "进展题", "\(q.status.title) · 挂着 \(q.materialCount) 条材料")
                Text(q.title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                let detail = plain(q.detail)
                if !detail.isEmpty {
                    Text(detail.count > 400 ? String(detail.prefix(398)) + "…" : detail)
                        .font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }
                TextField("先写一句：现在的答案或线索（会记进问题说明末尾，带上日期；可不写）", text: $remark, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($typing).padding(.top, 14)
                if !revealed { revealButton("看看新材料") }
            }
            if revealed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("上次以来新录、可能相关的摘录（勾选后选“有新线索”即挂上）")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                    if fresh.isEmpty {
                        Text(store.relatedIndex == nil ? "正在建立相关摘录索引…" : "没有找到用词相近的新摘录。")
                            .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                    }
                    ForEach(fresh, id: \.id) { h in
                        Toggle(isOn: Binding(get: { h.id.map(picked.contains) ?? false },
                                             set: { on in if let id = h.id { if on { picked.insert(id) } else { picked.remove(id) } } })) {
                            quoteRow(h)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
                choices([
                    ("1", "有新线索", "magnifyingglass", picked.isEmpty ? "可先勾选材料或写一句" : "挂上 \(picked.count) 条材料", {
                        store.revisitQuestion(q.id, .lead, highlightIDs: Array(picked), remark: remark); next()
                    }),
                    ("2", "写解答", "checkmark.circle", "打开问题写解答", { store.revisitQuestion(q.id, .answer) }),
                    ("3", "还没有", "clock", "下周再来", { store.revisitQuestion(q.id, .notyet, remark: remark); next() }),
                ])
            }
        }
    }

    // 6.0.9：问题簿·解答题（已解决的问题：给问题，想答案）

    private func answerQuestion(_ a: RevisitAnswerItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                badge(.question, "解答题", a.reviewCount == 0 ? "第一次做" : "")
                Text(a.title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                if !revealed {
                    think("这个问题当初是怎么解决的？答案是什么、依据是哪些材料？想好了再展开对照。")
                    TextField("我的回答（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($typing).padding(.top, 12)
                    revealButton("展开我的解答")
                } else {
                    if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    }
                    Divider().padding(.vertical, 14)
                    VStack(alignment: .leading, spacing: 12) {
                        if !plain(a.answer).isEmpty {
                            RichWebText(text: WikiLinks.plain(a.answer), style: .preview, slot: "exam-answer")
                        }
                        if let title = a.noteTitle {
                            Text("解答见札记《\(title)》").font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                            if let body = a.noteBody, !plain(body).isEmpty {
                                RichWebText(text: WikiLinks.plain(body), style: .preview, slot: "exam-answer-note")
                            }
                        }
                    }
                    if relearnItem == nil, let m = answerMatch(a) { ideaUnitsPanel(m) }
                }
            }
            if revealed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("答案想起来多少？").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    if let item = relearnItem {
                        gradeButtons { r in store.examRelearnAnswer(item, passed: r == .remembered); next() }
                    } else {
                        gradeButtons { r in calibrate(.answer, a.id, answerMatch(a), r); store.examAnswerQuestionAnswer(a, result: r); next() }
                        Text("记得的隔得越来越久再练（\(AppDatabase.nextNoteInterval(after: a.intervalDays)) 天后）；忘了的收工前在课末再练，两天后再来。")
                            .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                    }
                    HStack {
                        Button("打开这个问题") { store.selection = .question(a.id) }.buttonStyle(.link).font(.system(size: 12)).handCursor()
                        Spacer()
                    }
                }
            }
        }
    }

    private func choices(_ items: [(String, String, String, String, () -> Void)]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { choiceButtons(items) }
            VStack(alignment: .leading, spacing: 8) { choiceButtons(items) }
        }
    }

    @ViewBuilder
    private func choiceButtons(_ items: [(String, String, String, String, () -> Void)]) -> some View {
        ForEach(items.indices, id: \.self) { i in
            let item = items[i]
            VStack(alignment: .leading, spacing: 4) {
                PillButton(icon: item.2, title: item.1, key: item.0, style: i == 0 ? .primary : .normal, action: item.4)
                    .keyboardShortcut(key(KeyEquivalent(Character(item.0))))
                Text(item.3).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub).padding(.leading, 4)
            }
        }
    }

    // MARK: 交卷

    private func finished(_ s: DailyCheckState) -> some View {
        ReviewCardContainer(padding: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(s.done > 0 ? (store.annotate.left > 0 ? "今天的题答完了，还有文章要标" : "今天的日课做完了") : "今天的日课上没有题")
                    .font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if s.done > 0 {
                    Text(summaryLine(s)).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(s.done > 0 ? "在下面写一句日评，就算打卡。忘了的摘录两天后补练；记忆卡、札记、笔记按各自的间隔回来。"
                     : "记忆卡、札记、笔记还没到期，摘录也都答过了。可以去题库加几道题：录一条摘录、写一条札记或做几张卡。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                let relearn = store.examRelearn
                if relearn.passed + relearn.failed > 0 {
                    Text("课末再练：过关 \(relearn.passed) 道" + (relearn.failed > 0 ? "，两轮仍没想起 \(relearn.failed) 道（照常补练）" : "") + "。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                }
                // 6.0.7：设了每天的时长，超出的顺延到明天
                if paper.deferred > 0, let b = store.examBudget() {
                    HStack(spacing: 10) {
                        Text("今天约定的 \(b.minutes) 分钟已经答完，另有 \(paper.deferred) 题顺延到明天。")
                            .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        PillButton(icon: "plus", title: "再做 10 分钟", style: .ghost) {
                            store.examExtendBudget()
                            next()
                        }
                    }
                }
            }
        }
    }

    private func summaryLine(_ s: DailyCheckState) -> String {
        var parts = s.rows.filter { $0.done > 0 }.map { "\($0.group.title) \($0.done) \($0.group.unit)" }
        if tally.total > 0 { parts.append("摘录与札记：记得 \(tally.good)、大致 \(tally.mid)、忘了 \(tally.bad)") }
        return parts.joined(separator: "；") + "。"
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("今日小结").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
                if current != nil && store.examHandedIn {
                    Button("收起，接着答") { store.examHandedIn = false }.buttonStyle(.link).font(.system(size: 12)).handCursor()
                }
            }
            DailyScoreSection()
            // 6.0.5：打卡热力图、补签、走势与常错的题移到成绩册
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(ReviewPalette.accent)
                Text("一年的打卡图、补签、每天的成绩、掌握度走势与常错的题都在成绩册里。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                PillButton(icon: "chart.line.uptrend.xyaxis", title: "打开成绩册", style: .ghost) { store.openGradebook() }
            }
            .padding(14)
            .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !organize.isEmpty { organizeSection }
        }
    }

    private var organizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("待整理的笔记 \(organize.count) 段", systemImage: "tray.full")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            Text("复述题里标为“待整理”的段落；在笔记本里改过这一段，就从这里移除。")
                .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            ForEach(organize) { item in
                Button { store.selection = .notebook(item.notebookId) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("《\(item.notebookTitle)》" + (item.heading.map { " · " + $0 } ?? ""))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                        Text(item.opening).font(.system(size: 12.5, design: .serif)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }
}
