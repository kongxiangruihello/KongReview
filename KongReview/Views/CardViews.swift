import SwiftUI
import WebKit
import AppKit
import KongReviewCore

// MARK: - 卡片渲染（WKWebView：支持 Markdown/HTML、图片、Anki 填空）

struct CardWebView: NSViewRepresentable {
    /// 卡片正面/背面原文（Markdown 或 HTML）
    let front: String
    let back: String?
    let store: LibraryStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        LocalSchemeHandler.register(on: config, store: store)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = Self.page(front: front, back: back)
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        wv.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }

    static func page(front: String, back: String?) -> String {
        var body = "<div class=\"face\">" + Card.renderHTML(front) + "</div>"
        if let back {
            body += "<hr id=\"answer\"><div class=\"face back\">" + Card.renderHTML(back) + "</div>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        html, body { background: transparent; }
        body { font: 20px/1.7 -apple-system, "PingFang SC", "Songti SC", serif; color: #1d1d1f;
               max-width: 720px; margin: 24px auto; padding: 0 24px; text-align: center; }
        .face { text-align: left; }
        .back { font-size: 17px; color: #3a3a3c; }
        img { max-width: 100%; height: auto; }
        hr#answer { border: none; border-top: 1px solid rgba(128,128,128,.35); margin: 24px 0; }
        .cloze { font-weight: 600; color: #2f6fe4; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(128,128,128,.4); color: #555; }
        code, pre { font: 14px ui-monospace, Menlo, monospace; background: rgba(128,128,128,.12); border-radius: 4px; }
        pre { padding: 8px 10px; overflow-x: auto; }
        table { border-collapse: collapse; } td, th { border: 1px solid rgba(128,128,128,.35); padding: 4px 8px; }
        @media (prefers-color-scheme: dark) {
          body { color: #f2f2f7; } .back { color: #d1d1d6; } .cloze { color: #6ea8ff; } blockquote { color: #bbb; }
        }
        </style></head><body>\(body)
        <script>var a=document.getElementById('answer'); if(a){a.scrollIntoView({block:'start'});}</script>
        </body></html>
        """
    }
}

// MARK: - 记忆卡首页：牌组列表 / 学习 / 浏览

struct CardsHomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if store.study.deck != nil {
            StudyView()
        } else if let deck = store.study.browsingDeck {
            CardBrowseView(deck: deck)
        } else {
            deckList
        }
    }

    private var summaries: [DeckSummary] {
        _ = store.revision
        return (try? store.db.deckSummaries(now: Date(), newPerDay: CardSettings.newPerDay,
                                            reviewsPerDay: CardSettings.reviewsPerDay)) ?? []
    }

    private var deckList: some View {
        let decks = summaries
        return VStack(spacing: 0) {
            if decks.isEmpty {
                ContentUnavailableView {
                    Label("还没有记忆卡", systemImage: "brain")
                } description: {
                    Text("在摘录上右键选“做成记忆卡”，或在回顾时按 M；也可以导入 Anki 牌组（.apkg 或纯文本）。")
                } actions: {
                    HStack {
                        Button("新建卡片") { store.newCard(deck: nil) }
                        Button("导入 Anki…") { ExportService.importAnki(store: store) }
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(decks) { d in
                            deckRow(d)
                        }
                    } header: {
                        HStack {
                            Text("牌组").frame(maxWidth: .infinity, alignment: .leading)
                            Text("新").frame(width: 48).foregroundStyle(.blue)
                            Text("学习中").frame(width: 48).foregroundStyle(.red)
                            Text("待复习").frame(width: 48).foregroundStyle(.green)
                            Text("").frame(width: 150)
                        }
                    } footer: {
                        Text("每天最多学 \(CardSettings.newPerDay) 张新卡、复习 \(CardSettings.reviewsPerDay) 张（在“设置 → 记忆卡”修改）。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("记忆卡")
        .toolbar {
            ToolbarItemGroup {
                Button { store.newCard(deck: nil) } label: { Label("新建卡片", systemImage: "plus.rectangle.on.rectangle") }
                    .help("新建记忆卡")
                Button { ExportService.importAnki(store: store) } label: { Label("导入 Anki", systemImage: "square.and.arrow.down") }
                    .help("导入 Anki 牌组（.apkg，或“纯文本笔记”导出的 .txt）")
            }
        }
        .alert("重命名牌组", isPresented: Binding(
            get: { store.study.renamingDeck != nil },
            set: { if !$0 { store.study.renamingDeck = nil } }
        )) {
            TextField("牌组名", text: Bindable(store.study).renameText)
            Button("取消", role: .cancel) { store.study.renamingDeck = nil }
            Button("重命名") {
                if let old = store.study.renamingDeck { store.renameDeck(old, to: store.study.renameText) }
                store.study.renamingDeck = nil
            }
        } message: {
            Text("用 :: 分隔可表示子牌组，如“汉语::成语”。")
        }
    }

    private func deckRow(_ d: DeckSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.headline)
                Text("共 \(d.total) 张").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            count(d.counts.new, .blue)
            count(d.counts.learning, .red)
            count(d.counts.review, .green)
            HStack {
                Button("浏览") {
                    store.study.browseSelection = []
                    store.study.browsingDeck = d.name
                }
                Button("学习") { store.startStudy(deck: d.name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(d.counts.total == 0)
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("在此牌组新建卡片") { store.newCard(deck: d.name) }
            Button("重命名牌组…") {
                store.study.renameText = d.name
                store.study.renamingDeck = d.name
            }
        }
    }

    private func count(_ n: Int, _ color: Color) -> some View {
        Text("\(n)").monospacedDigit().frame(width: 48)
            .foregroundStyle(n == 0 ? Color.secondary : color)
    }
}

// MARK: - 学习（仿 Anki：先看正面，空格显示答案，1–4 评分）

struct StudyView: View {
    @Environment(LibraryStore.self) private var store
    private var study: StudyState { store.study }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let card = study.current {
                CardWebView(front: card.front, back: study.showingAnswer ? card.back : nil, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                controls(card).padding()
            } else {
                finished
            }
        }
        .navigationTitle("学习 · \(study.deck ?? "")")
        .onAppear { if study.current == nil && !study.finished { store.nextCard() } }
    }

    private var counts: StudyQueue.Counts {
        _ = store.revision
        guard let deck = study.deck,
              let s = try? store.db.deckSummaries(now: Date(), newPerDay: CardSettings.newPerDay,
                                                  reviewsPerDay: CardSettings.reviewsPerDay)
                .first(where: { $0.name == deck }) else { return .init() }
        return s.counts
    }

    private var header: some View {
        HStack {
            Button {
                study.deck = nil
                study.current = nil
                study.finished = false
            } label: { Label("牌组", systemImage: "chevron.left") }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            let c = counts
            HStack(spacing: 14) {
                Text("新 \(c.new)").foregroundStyle(.blue)
                Text("学习中 \(c.learning)").foregroundStyle(.red)
                Text("待复习 \(c.review)").foregroundStyle(.green)
            }
            .monospacedDigit()
            .font(.callout)
            Spacer()
            if let card = study.current {
                Button { store.editCard(card) } label: { Label("编辑", systemImage: "pencil") }
                    .keyboardShortcut("e", modifiers: [])
                    .help("编辑这张卡（E）")
                Button {
                    if let id = card.id { store.setSuspended(true, cards: [id]) }
                    store.nextCard()
                } label: { Label("暂停", systemImage: "pause.circle") }
                    .help("暂停这张卡：不再出现在学习中，可在“浏览”里恢复")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func controls(_ card: Card) -> some View {
        if !study.showingAnswer {
            Button {
                study.showingAnswer = true
            } label: {
                Text("显示答案").frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .help("空格")
        } else {
            let preview = CardScheduler().preview(card)
            HStack(spacing: 12) {
                ForEach(CardAnswer.allCases, id: \.self) { a in
                    Button {
                        store.answerCurrent(a)
                    } label: {
                        VStack(spacing: 2) {
                            Text(preview[a] ?? "").font(.caption).foregroundStyle(.secondary)
                            Text("\(a.rawValue) \(a.label)")
                        }
                        .frame(minWidth: 90)
                    }
                    .controlSize(.large)
                    .tint(answerColor(a))
                    .keyboardShortcut(KeyEquivalent(Character(String(a.rawValue))), modifiers: [])
                }
            }
            .background {
                // 与 Anki 相同：显示答案后，空格 = 良好
                Button("") { store.answerCurrent(.good) }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    private func answerColor(_ a: CardAnswer) -> Color {
        switch a {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal").font(.system(size: 48)).foregroundStyle(.tint)
            Text("这个牌组今天学完了").font(.title2)
            Text("学习中的卡片到时间会再出现；新卡与复习数量受每日上限约束。")
                .foregroundStyle(.secondary)
            HStack {
                Button("返回牌组") {
                    study.deck = nil
                    study.finished = false
                }
                Button("再查一次") { store.nextCard() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 浏览牌组

struct CardBrowseView: View {
    @Environment(LibraryStore.self) private var store
    let deck: String
    private var study: StudyState { store.study }

    private var cards: [Card] {
        _ = store.revision
        return (try? store.db.cards(deck: deck, query: study.browseQuery)) ?? []
    }

    var body: some View {
        let list = cards
        let selected = Array(study.browseSelection)
        let deckNames = (try? store.db.deckNames()) ?? []
        return VStack(spacing: 0) {
            HStack {
                Button {
                    study.browsingDeck = nil
                    study.browseQuery = ""
                } label: { Label("牌组", systemImage: "chevron.left") }
                TextField("搜索正面、背面、标签", text: Bindable(store.study).browseQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Text("\(list.count) 张").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            List(list, id: \.rowID, selection: Bindable(store.study).browseSelection) { c in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Markdown.plainText(fromHTML: Card.renderHTML(c.front)))
                            .lineLimit(2)
                        if !c.back.isEmpty {
                            Text(Markdown.plainText(fromHTML: Card.renderHTML(c.back)))
                                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if c.isSuspended {
                        Text("已暂停").font(.caption).padding(.horizontal, 6)
                            .background(.yellow.opacity(0.3), in: Capsule())
                    }
                    Text(stateLabel(c)).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .contextMenu { menu(for: study.browseSelection.contains(c.rowID) ? selected : [c.rowID], deckNames: deckNames) }
                .onTapGesture(count: 2) { store.editCard(c) }
            }
        }
        .navigationTitle("浏览 · \(deck)")
        .toolbar {
            ToolbarItemGroup {
                Button { store.newCard(deck: deck) } label: { Label("新建卡片", systemImage: "plus") }
                Menu {
                    menu(for: selected, deckNames: deckNames)
                } label: {
                    Label("操作", systemImage: "ellipsis.circle")
                }
                .disabled(selected.isEmpty)
                Button("学习") { store.startStudy(deck: deck) }
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: [Int64], deckNames: [String]) -> some View {
        if ids.count == 1, let id = ids.first, let c = try? store.db.card(id: id) {
            Button("编辑…") { store.editCard(c) }
        }
        Button("暂停") { store.setSuspended(true, cards: ids) }
        Button("恢复") { store.setSuspended(false, cards: ids) }
        Menu("移到牌组") {
            ForEach(deckNames.filter { $0 != deck }, id: \.self) { name in
                Button(name) {
                    store.moveCards(ids, toDeck: name)
                    study.browseSelection = []
                }
            }
        }
        Divider()
        Button("删除 \(ids.count) 张卡片", role: .destructive) {
            store.deleteCards(ids)
            study.browseSelection = []
        }
    }

    private func stateLabel(_ c: Card) -> String {
        switch c.state {
        case .new: return "新卡"
        case .learning, .relearning: return "学习中"
        case .review:
            let f = DateFormatter()
            f.dateFormat = "M月d日"
            return "下次 " + f.string(from: c.due)
        }
    }
}

extension Card {
    var rowID: Int64 { id ?? -1 }
}

// MARK: - 编辑卡片

struct CardEditorView: View {
    @Environment(LibraryStore.self) private var store

    private func binding<T>(_ kp: WritableKeyPath<CardDraft, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { store.cardEditor?[keyPath: kp] ?? fallback },
                set: { store.cardEditor?[keyPath: kp] = $0 })
    }

    var body: some View {
        let draft = store.cardEditor
        let decks = (try? store.db.deckNames()) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text(draft?.isNew == true ? "新建记忆卡" : "编辑记忆卡").font(.title2.bold())
            HStack {
                Text("牌组")
                TextField("牌组", text: binding(\.card.deck, ""))
                    .textFieldStyle(.roundedBorder)
                Menu("选择") {
                    ForEach(decks, id: \.self) { d in
                        Button(d) { store.cardEditor?.card.deck = d }
                    }
                }
                .fixedSize()
                Text("标签")
                TextField("用逗号或空格分隔", text: binding(\.tagsText, ""))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正面").font(.headline)
                    TextEditor(text: binding(\.card.front, ""))
                        .font(.system(size: 14))
                        .border(Color.secondary.opacity(0.3))
                    Text("背面").font(.headline)
                    TextEditor(text: binding(\.card.back, ""))
                        .font(.system(size: 14))
                        .border(Color.secondary.opacity(0.3))
                    Text("支持 Markdown（**粗体**、*斜体*、列表、> 引用、`代码`）或直接写 HTML；图片可用 <img src=\"网址\">。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("预览").font(.headline)
                    CardWebView(front: draft?.card.front ?? "", back: draft?.card.back ?? "", store: store)
                        .background(Color(nsColor: .textBackgroundColor))
                        .border(Color.secondary.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                if let c = draft?.card, c.id != nil {
                    Text(c.state == .new ? "新卡" : "已复习 \(c.reps) 次，遗忘 \(c.lapses) 次，间隔 \(Int(c.interval)) 天")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { store.cardEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { store.commitCardEditor() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled((draft?.card.front ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - Anki 导入预览

struct CardImportPreviewView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let p = store.cardImport
        return VStack(alignment: .leading, spacing: 12) {
            Text("导入 Anki").font(.title2.bold())
            if let p {
                Text(p.fileName).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("卡片"); Text("\(p.notes.count) 张").monospacedDigit() }
                    GridRow { Text("带复习进度"); Text("\(p.withSchedule) 张（沿用 Anki 的间隔与到期日）").monospacedDigit() }
                    GridRow { Text("媒体文件"); Text("\(p.media.count) 个").monospacedDigit() }
                    GridRow { Text("牌组"); Text(p.decks.joined(separator: "、")).lineLimit(3) }
                }
                Text("示例").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(p.notes.prefix(3).enumerated()), id: \.offset) { _, n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Markdown.plainText(fromHTML: n.front)).lineLimit(2)
                            Text(Markdown.plainText(fromHTML: n.back)).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("每条 Anki 笔记导入为一张卡（取第一张卡片的正反面；填空题合并为一张）。已导入过的笔记（同一 GUID）会跳过。导入前自动备份。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.cardImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入") { store.confirmCardImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
