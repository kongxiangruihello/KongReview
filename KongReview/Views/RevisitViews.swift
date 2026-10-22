import SwiftUI
import KongReviewCore

// MARK: - 5.0.0：重温——今日功课第三步
//
// 一次一张：札记先只显示题目（一句话的论断），想过理由再展开正文；常念的问题列出上次重温以来可能相关的新摘录。
// 每张只问一个问题，用 1、2、3 作答；E 打开札记或问题。札记与问题不评分。

struct RevisitView: View {
    @Environment(LibraryStore.self) private var store
    @State private var queue = RevisitQueue.empty
    @State private var loaded = false
    @State private var revealed = false
    @State private var fresh: [Highlight] = []
    @State private var picked: Set<Int64> = []
    @State private var remark = ""
    @FocusState private var remarkFocused: Bool

    private enum Item: Equatable {
        case note(RevisitNoteItem)
        case question(RevisitQuestionItem)
        var key: String {
            switch self {
            case .note(let n): "n\(n.id)"
            case .question(let q): "q\(q.id)"
            }
        }
    }

    private var current: Item? {
        if let n = queue.notes.first { return .note(n) }
        if let q = queue.questions.first { return .question(q) }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let item = current {
                    switch item {
                    case .note(let n): noteCard(n)
                    case .question(let q): questionCard(q)
                    }
                } else {
                    finished
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        // 引用、挂上材料后也重读：卡上的摘录与“新摘录”随之更新；换了一张才收起正文
        .task(id: "\(store.revisitRevision)|\(store.today)|\(store.relatedIndex == nil)") {
            let next = (try? store.db.revisitQueue()) ?? .empty
            let changed = Self.key(next) != Self.key(queue)
            queue = next
            loaded = true
            if changed { resetCard() }
            loadFresh()
        }
    }

    private static func key(_ q: RevisitQueue) -> String {
        (q.notes.first.map { "n\($0.id)" } ?? q.questions.first.map { "q\($0.id)" }) ?? ""
    }

    private func resetCard() {
        revealed = false
        picked = []
        remark = ""
        remarkFocused = false
    }

    private func loadFresh() {
        switch current {
        case .note(let n):
            let text = n.title + "\n" + Markdown.plainText(fromHTML: WikiLinks.plain(n.body))
            fresh = store.revisitNewHighlights(text: text, since: n.since, excluding: Set(n.highlights.compactMap(\.id)))
        case .question(let q):
            let text = q.title + "\n" + Markdown.plainText(fromHTML: q.detail)
            fresh = store.revisitNewHighlights(text: text, since: q.since, excluding: q.highlightIDs, limit: 5)
        case nil:
            fresh = []
        }
    }

    /// 写一句时让单键快捷键失效
    private func key(_ k: KeyEquivalent) -> KeyboardShortcut? {
        remarkFocused ? nil : KeyboardShortcut(k, modifiers: [])
    }

    // MARK: 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("重温").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if loaded && !queue.isEmpty {
                    Text("第 \(queue.done + 1) 张 · 今天还有 \(queue.total) 张")
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Button { store.selection = .ideaNotes } label: { Label("全部札记", systemImage: "note.text") }
                    .buttonStyle(.borderless).font(.system(size: 12)).handCursor()
                Button { store.openQuestionBook() } label: { Label("问题簿", systemImage: "questionmark.bubble") }
                    .buttonStyle(.borderless).font(.system(size: 12)).handCursor()
            }
            Text("今日功课第三步：久未重温的札记与「常念」的问题回到眼前。札记先看题目、想想理由再展开；每张只问一句，用 1、2、3 作答。")
                .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 札记

    private func noteCard(_ n: RevisitNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                HStack(spacing: 8) {
                    Label("札记", systemImage: "note.text").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                    Text(noteByline(n)).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    Spacer()
                }
                Text(n.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                if revealed {
                    VStack(alignment: .leading, spacing: 12) {
                        if Markdown.plainText(fromHTML: n.body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("（还没有正文）").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                        } else {
                            RichWebText(text: WikiLinks.plain(n.body), style: .preview, slot: "revisit-note")
                        }
                        if !n.highlights.isEmpty {
                            Text("引用的摘录 \(n.highlights.count) 条").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                            ForEach(n.highlights.prefix(5), id: \.id) { h in quoteRow(h) }
                        }
                    }
                    .padding(.top, 16)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb").foregroundStyle(ReviewPalette.sub)
                        Text("先想一想：为什么这么看？依据是哪些材料？想好了再展开正文对照。")
                            .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 18)
                    PillButton(icon: "chevron.down", title: "展开正文", key: "空格") { revealed = true }
                        .keyboardShortcut(key(.space))
                        .padding(.top, 14)
                }
            }
            if revealed { freshSection(note: n) }
            choices([
                ("1", "仍然这么看", "checkmark", "下次在 \(AppDatabase.nextNoteInterval(after: n.intervalDays)) 天后", { store.revisitNote(n.id, .agree) }),
                ("2", "要修订", "pencil", "打开札记修改，间隔从头算", { store.revisitNote(n.id, .revise) }),
                ("3", "以后再说", "clock", "一周后再来", { store.revisitNote(n.id, .later) }),
            ], openTitle: "打开札记", open: { store.selection = .ideaNote(n.id) })
        }
    }

    private func noteByline(_ n: RevisitNoteItem) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        var parts = ["写于 " + f.string(from: n.createdAt)]
        if let last = n.lastReviewedAt { parts.append("上次重温 " + f.string(from: last)) } else { parts.append("第一次重温") }
        return parts.joined(separator: " · ")
    }

    private func quoteRow(_ h: Highlight) -> some View {
        let src = store.source(for: h)
        let plain = Markdown.plainText(fromHTML: Markdown.richHTML(h.text)).replacingOccurrences(of: "\n", with: " ")
        return VStack(alignment: .leading, spacing: 3) {
            Text(plain.count > 140 ? String(plain.prefix(138)) + "…" : plain)
                .font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            let cite = [src?.author ?? "", src.map { "《\($0.title)》" } ?? "", h.location ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            if !cite.isEmpty { Text(cite).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub) }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
    }

    /// 旧观点与新材料相遇：上次重温以来新录、用词相近的摘录，可一键引用
    private func freshSection(note n: RevisitNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("上次重温以来新录、可能相关的摘录").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
            if fresh.isEmpty {
                Text(store.relatedIndex == nil ? "正在建立相关摘录索引…" : "没有找到用词相近的新摘录。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
            ForEach(fresh, id: \.id) { h in
                HStack(alignment: .top, spacing: 12) {
                    quoteRow(h)
                    Spacer(minLength: 8)
                    Button {
                        if let id = h.id { store.addHighlights([id], toIdeaNote: n.id) }
                    } label: { Label("引用", systemImage: "text.quote") }
                        .controlSize(.small).handCursor()
                        .help("把这条摘录引用到札记《\(n.title)》")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }

    // MARK: 常念的问题

    private func questionCard(_ q: RevisitQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                HStack(spacing: 8) {
                    Label("常念的问题", systemImage: "star.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.orange)
                    Label(q.status.title, systemImage: q.status.symbol).font(.system(size: 12)).foregroundStyle(q.status.color)
                    Text("挂着 \(q.materialCount) 条材料").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    Spacer()
                }
                Text(q.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                let detail = Markdown.plainText(fromHTML: q.detail).trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    Text(detail.count > 400 ? String(detail.prefix(398)) + "…" : detail)
                        .font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                Text("有新线索吗？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink).padding(.top, 16)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("上次重温以来新录、可能相关的摘录（勾选后选“有新线索”即挂上）")
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
                TextField("记一句（可不填）：写进问题说明末尾，带上日期", text: $remark)
                    .textFieldStyle(.roundedBorder)
                    .focused($remarkFocused)
                    .onSubmit { remarkFocused = false }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
            choices([
                ("1", "有新线索", "magnifyingglass", picked.isEmpty ? "可先勾选材料或记一句" : "挂上 \(picked.count) 条材料", {
                    store.revisitQuestion(q.id, .lead, highlightIDs: Array(picked), remark: remark)
                }),
                ("2", "写解答", "checkmark.circle", "打开问题写解答", { store.revisitQuestion(q.id, .answer) }),
                ("3", "还没有", "clock", "下周再来", { store.revisitQuestion(q.id, .notyet) }),
            ], openTitle: "打开问题", open: { store.selection = .question(q.id) })
        }
    }

    // MARK: 选择与完成

    private func choices(_ items: [(String, String, String, String, () -> Void)], openTitle: String, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { choiceButtons(items) }
                VStack(alignment: .leading, spacing: 8) { choiceButtons(items) }
            }
            HStack(spacing: 6) {
                Button(action: open) { Text(openTitle) }.buttonStyle(.link).keyboardShortcut(key("e")).handCursor()
                KeyCap(text: "E")
                Spacer()
            }
            .font(.system(size: 12))
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

    private var finished: some View {
        ReviewCardContainer(padding: 30) {
            VStack(alignment: .leading, spacing: 10) {
                Text(queue.done > 0 ? "今日重温已完成" : "今天没有要重温的札记与问题")
                    .font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text(queue.done > 0
                     ? "今天重温了 \(queue.done) 张。札记按 7、21、60、180、365 天的间隔回来，改过的从头算；「常念」的问题约每周一次。"
                     : "新写的札记 7 天后第一次回来，之后间隔逐渐加长；在问题簿里标为「常念」的问题约每周回来一次。每天至多 \(RevisitLimits.saved().notes) 条札记、\(RevisitLimits.saved().questions) 个问题，可在设置的“回顾”页修改。")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    PillButton(icon: "house", title: "回到首页", style: .primary) { store.selection = .home }
                    PillButton(icon: "note.text", title: "全部札记") { store.selection = .ideaNotes }
                }
                .padding(.top, 6)
            }
        }
    }
}
