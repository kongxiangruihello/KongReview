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
    @State private var turn = 0
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
    @FocusState private var typing: Bool

    var body: some View {
        let state = store.dailyCheck
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(state)
                CheckinStatusStrip()
                StreakBreakPrompt()
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let q = current {
                    questionView(q).id(q.key)
                } else {
                    finished(state)
                }
                if loaded && (current == nil || store.examHandedIn) {
                    reportCard
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("今日试卷")
        .task(id: "\(store.today)|\(reload)") { load() }
        .task(id: "\(store.dailyCheckRevision)|\(store.revisitRevision)") {
            tally = (try? store.db.examTally()) ?? MasteryTally()
            organize = (try? store.db.blocksToOrganize()) ?? []
        }
    }

    // MARK: 组卷

    private func load() {
        paper = store.examPaper()
        if let pick = ExamRotation.next(turn: turn, available: paper.available) {
            current = paper.question(pick.kind, day: Date())
            turn = pick.turn
        } else {
            current = nil
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
                Text("今日试卷").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text(DailyCheckView.dateLine()).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                Spacer()
                if s.due > 0 {
                    Text("已答 \(s.done) / \(s.due) 题")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.left == 0 ? ReviewPalette.done : ReviewPalette.ink)
                }
            }
            if let c = s.completion {
                ProgressView(value: c).tint(s.left == 0 ? ReviewPalette.done : ReviewPalette.accent)
            }
            HStack(spacing: 14) {
                ForEach(s.rows) { row in
                    Label("\(row.group.title) \(min(row.done, row.due))/\(row.due)", systemImage: row.group.symbol)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(row.due > 0 && row.done >= row.due ? ReviewPalette.done : ReviewPalette.sub)
                }
                Spacer()
                if current != nil && !store.examHandedIn {
                    Button("先交卷，看成绩单") { store.examHandedIn = true }
                        .buttonStyle(.link).font(.system(size: 12)).handCursor()
                        .help("还没答的题仍留在卷子上，随时可以接着答")
                }
            }
            Text("一律先想、再展开对照、再判分：先提取后对照，比重读记得牢。题目按各自的到期日出，卷面上交错排列；中途离开，回来接着答。")
                .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
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
        }
    }

    private func badge(_ kind: ExamKind, _ title: String, _ detail: String = "") -> some View {
        HStack(spacing: 8) {
            Label(kind.title + " · " + title, systemImage: kind.symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
            Spacer()
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
                    .frame(height: revealed ? 360 : 240)
                    .padding(.top, 10)
                if !revealed {
                    TextField("我的回答（可不写）", text: $myAnswer, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($typing)
                        .padding(.top, 10)
                    revealButton("显示答案")
                } else if !myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("我的回答：" + myAnswer).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
            if revealed {
                HStack(spacing: 10) {
                    ForEach(CardAnswer.allCases, id: \.self) { a in
                        PillButton(title: a.label, key: "\(a.rawValue)", style: a == .good ? .primary : .normal) {
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

    private func highlightQuestion(_ h: Highlight, _ mode: ExamHighlightMode) -> some View {
        let text = plain(h.text)
        let note = plain(h.note ?? "")
        return VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                badge(.highlight, mode.title, h.isFavorite ? "已收藏" : "")
                VStack(alignment: .leading, spacing: 12) {
                    switch mode {
                    case .source:
                        Text(text).font(.system(size: 18, design: .serif)).foregroundStyle(ReviewPalette.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("这段话出自哪本书？作者是谁？大致在什么位置？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    case .gist:
                        Text(cite(h)).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        if !note.isEmpty {
                            Text("按语：" + note).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("这一处原文说了什么？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    case .opening:
                        let opening = text.replacingOccurrences(of: "\n", with: " ")
                        Text("开头：" + (opening.count > 10 ? String(opening.prefix(10)) + "……" : opening))
                            .font(.system(size: 18, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        if !note.isEmpty {
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
                } else {
                    revealButton()
                }
            }
            if revealed {
                VStack(alignment: .leading, spacing: 8) {
                    gradeButtons { r in store.examAnswerHighlight(h, mode: mode, result: r); next() }
                    HStack(spacing: 14) {
                        Button("记得，并收藏") { store.examAnswerHighlight(h, mode: mode, result: .remembered, action: .favorite); next() }
                            .keyboardShortcut(key("f"))
                        KeyCap(text: "F")
                        Button("记得，以后不再出（弃置）") { store.examAnswerHighlight(h, mode: mode, result: .remembered, action: .discard); next() }
                            .keyboardShortcut(key("d"))
                        KeyCap(text: "D")
                        Spacer()
                        Button("做成记忆卡") { store.makeCard(from: h) }.handCursor()
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                    Text("忘了的两天后起回到卷子上补考；记得的，隔得越来越久才再出。")
                        .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
            }
        }
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
                badge(.note, "论证题", n.lastReviewedAt == nil ? "第一次考" : "")
                Text(n.title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                if revealed {
                    VStack(alignment: .leading, spacing: 12) {
                        if plain(n.body).isEmpty {
                            Text("（还没有正文）").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                        } else {
                            RichWebText(text: WikiLinks.plain(n.body), style: .preview, slot: "exam-note")
                        }
                        if !n.highlights.isEmpty {
                            Text("引用的摘录 \(n.highlights.count) 条").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                            ForEach(n.highlights.prefix(5), id: \.id) { h in quoteRow(h) }
                        }
                    }
                    .padding(.top, 16)
                } else {
                    think("为什么这么看？依据是哪些材料？想好了再展开正文对照。")
                    revealButton()
                }
            }
            if revealed {
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
                        gradeButtons { r in noteGrade = r }
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
                    RichWebText(text: Markdown.richHTML(k.text), style: .preview, slot: "exam-block").padding(.top, 16)
                } else {
                    Text("这一段开头：" + k.opening).font(.system(size: 14, design: .serif)).foregroundStyle(ReviewPalette.sub).padding(.top, 10)
                    think("先合上想一想：这一段说了什么？要点是哪几条？想好了再展开对照。")
                    revealButton("展开这一段")
                }
            }
            if revealed {
                choices([
                    ("1", "已吸收", "checkmark", "能说出要点；下次在 \(AppDatabase.nextNoteInterval(after: k.intervalDays)) 天后", { store.revisitBlock(k.id, .absorbed); next() }),
                    ("2", "需重读", "arrow.uturn.backward", "说不出或说错；\(AppDatabase.blockRereadDays) 天后再来", { store.revisitBlock(k.id, .reread); next() }),
                    ("3", "待整理", "tray.full", "内容还乱；一周后再来，列入成绩单下的“待整理”", { store.revisitBlock(k.id, .organize); next() }),
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
                Text(s.done > 0 ? "今天的卷子答完了" : "今天的卷子上没有题")
                    .font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if s.done > 0 {
                    Text(summaryLine(s)).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(s.done > 0 ? "在下面写一句日评，就算打卡。忘了的摘录两天后补考；记忆卡、札记、笔记按各自的间隔回来。"
                     : "记忆卡、札记、笔记还没到期，摘录也都答过了。可以去题库加几道题：录一条摘录、写一条札记或做几张卡。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryLine(_ s: DailyCheckState) -> String {
        var parts = s.rows.filter { $0.done > 0 }.map { "\($0.group.title) \($0.done) 题" }
        if tally.total > 0 { parts.append("摘录与札记：记得 \(tally.good)、大致 \(tally.mid)、忘了 \(tally.bad)") }
        return parts.joined(separator: "；") + "。"
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("成绩单").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
                if current != nil && store.examHandedIn {
                    Button("收起，接着答") { store.examHandedIn = false }.buttonStyle(.link).font(.system(size: 12)).handCursor()
                }
            }
            DailyScoreSection()
            CheckinSection()
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
