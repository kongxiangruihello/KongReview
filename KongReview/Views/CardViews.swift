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
    /// 6.0.0：卡片的样式（HTML 模板的样式，或普通卡片样式）；加在默认样式之后
    var css: String = ""

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
        let html = Self.page(front: front, back: back, adjustDarkColors: CardSettings.adjustDarkColors, css: css)
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

    /// 6.0.0：用户写的样式；去掉能跳出 <style> 的写法与外部资源
    static func userStyle(_ css: String) -> String {
        var c = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return "" }
        c = c.replacingOccurrences(of: #"(?i)</\s*style"#, with: "", options: .regularExpression)
        c = c.replacingOccurrences(of: #"(?i)@import[^;]*;?"#, with: "", options: .regularExpression)
        c = c.replacingOccurrences(of: #"(?i)url\(\s*['"]?\s*(https?:|//)[^)]*\)"#, with: "none", options: .regularExpression)
        return "<style>" + c + "</style>"
    }

    static func page(front: String, back: String?, adjustDarkColors: Bool = true, css: String = "") -> String {
        var body = "<div class=\"face\">" + Card.renderHTML(front) + "</div>"
        if let back {
            // 1.8：正反面之间用“答”字小印隔开
            body += "<div id=\"answer\" class=\"sep\"><span>答</span></div><div class=\"face back\">" + Card.renderHTML(back) + "</div>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        html, body { background: transparent; }
        body { font: 20px/1.75 "Songti SC", "STSong", serif; color: #1F1E1C;
               max-width: 720px; margin: 24px auto; padding: 0 24px; text-align: center; }
        .face { text-align: left; }
        .back { font-size: 17px; color: #3B3833; }
        img { max-width: 100%; height: auto; }
        hr#answer { border: none; border-top: 1px solid rgba(128,128,128,.35); margin: 24px 0; }
        /* 1.8：书斋风——短的正面（字词、短句）居中放大；正反面之间一枚“答”字小印 */
        .face.short { text-align: center; font-size: 34px; line-height: 1.5; letter-spacing: .12em; margin: 40px 0 8px; }
        #answer.sep { display: flex; align-items: center; gap: 14px; margin: 26px 0 22px;
                      font: 13px "Kaiti SC", "STKaiti", serif; color: #B5493A; }
        #answer.sep::before, #answer.sep::after { content: ""; flex: 1; border-top: 1px solid rgba(128,128,128,.28); }
        #answer.sep span { border: 1px solid rgba(181,73,58,.55); border-radius: 3px; padding: 0 4px; line-height: 1.5; }
        .cloze { font-weight: 600; color: #3B73EF; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(128,128,128,.4); color: #555; }
        code, pre { font: 14px ui-monospace, Menlo, monospace; background: rgba(128,128,128,.12); border-radius: 4px; }
        pre { padding: 8px 10px; overflow-x: auto; }
        table { border-collapse: collapse; } td, th { border: 1px solid rgba(128,128,128,.35); padding: 4px 8px; }
        .kr-field + .kr-field { margin-top: 14px; }
        /* 1.5：背面的各项内容（答案、各栏目、模板字段）之间用细横线隔开 */
        .back > .kr-field + .kr-field { margin-top: 16px; padding-top: 14px; border-top: 1px dashed rgba(128,128,128,.4); }
        .kr-label { font: 13px "Kaiti SC", "STKaiti", serif; letter-spacing: .08em; color: #9C5B3B; margin-bottom: 2px; }
        details.kr-field > summary { font-size: 14px; color: #8e8e93; cursor: pointer; }
        details.kr-field[open] > summary { margin-bottom: 4px; }
        @media (prefers-color-scheme: dark) {
          body { color: #EDEBE6; } .back { color: #D6D2CA; } .cloze { color: #5B8CF5; } blockquote { color: #bbb; }
          #answer.sep { color: #D9826F; } .kr-label { color: #C9906F; }
        }
        </style>\(Self.userStyle(css))</head><body>\(body)
        <script>(function(){
          var f=document.querySelector('.face'); if(f){ var t=(f.innerText||'').trim();
            if(t.length>0 && t.length<=16 && t.indexOf('\\n')<0 && !f.querySelector('img,table,ul,ol,pre,blockquote,details')) f.classList.add('short'); }
          var a=document.getElementById('answer'); if(a){a.scrollIntoView({block:'start'});}
        })();</script>
        \(adjustDarkColors ? darkColorScript : "")
        </body></html>
        """
    }
}

extension CardWebView {
    /// 深色模式下处理卡片自带的颜色（从网页复制来的卡片常带 color: rgb(51,51,51) 这类深灰字）：
    /// 偏灰的深色文字去掉、交给页面的浅色文字；有色彩的深色文字调亮；浅色背景改成透明。
    static let darkColorScript = """
    <script>(function(){
      if (!window.matchMedia('(prefers-color-scheme: dark)').matches) return;
      function rgb(c){ var m=c&&c.match(/rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?/);
        if(!m||(m[4]!==undefined&&parseFloat(m[4])===0)) return null; return [+m[1],+m[2],+m[3]]; }
      function lum(c){ return (0.2126*c[0]+0.7152*c[1]+0.0722*c[2])/255; }
      function sat(c){ var mx=Math.max(c[0],c[1],c[2]), mn=Math.min(c[0],c[1],c[2]); return mx===0?0:(mx-mn)/mx; }
      document.querySelectorAll('.face *').forEach(function(el){
        var hasColor = el.style.color || (el.tagName==='FONT' && el.getAttribute('color'));
        if (hasColor) {
          var c = rgb(getComputedStyle(el).color);
          if (c && lum(c) < 0.45) {
            if (sat(c) < 0.3) { el.style.color=''; el.removeAttribute('color'); if (getComputedStyle(el).color && lum(rgb(getComputedStyle(el).color)||[255,255,255]) < 0.45) el.style.color='inherit'; }
            else { el.style.color='rgb('+c.map(function(v){return Math.round(v+(255-v)*0.45);}).join(',')+')'; }
          }
        }
        if (el.style.backgroundColor || el.getAttribute('bgcolor')) {
          var b = rgb(getComputedStyle(el).backgroundColor);
          if (b && lum(b) > 0.7) { el.style.backgroundColor='transparent'; el.removeAttribute('bgcolor'); }
        }
      });
    })();</script>
    """
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
        return store.deckSummaryCache
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
                // 1.7：重新设计的牌组首页（见 DeckHomeViews.swift）
                DeckHomeView(decks: decks)
            }
        }
        .navigationTitle("记忆卡")
        .toolbar {
            ToolbarItemGroup {
                Button { store.newCard(deck: nil) } label: { Label("新建卡片", systemImage: "plus.rectangle.on.rectangle") }
                    .help("新建记忆卡")
                Menu {
                    Button("批量粘贴问答…") { store.showsCardBulkEntry = true }
                    Button("今日录入与录入历史…") { store.cardEntryHistory.isPresented = true }
                } label: { Label("录入工具",systemImage:"tray.and.arrow.down") }.handCursor()
                Button { ExportService.importAnki(store: store) } label: { Label("导入 Anki", systemImage: "square.and.arrow.down") }
                    .help("导入 Anki 牌组（.apkg / .colpkg，或“纯文本笔记”导出的 .txt）")
                Button { store.apkgExport = ApkgExportRequest(allDecks: decks.map(\.name), decks: Set(decks.map(\.name))) } label: {
                    Label("导出到 Anki", systemImage: "square.and.arrow.up")
                }
                .help("导出为 .apkg，在 AnkiMobile / AnkiDroid / Anki 桌面版里导入复习")
                .disabled(decks.isEmpty)
                Menu {
                    Button("管理常用录入预设…") { store.showsCardEntryPresetManager = true }
                    // 6.0.0：没有 HTML 模板的卡片共用的样式
                    Button("普通卡片样式…") { store.showsPlainCardStyle = true }
                    Divider()
                    let templates = store.noteTemplates.values.sorted { $0.name < $1.name }
                    if templates.isEmpty { Text("没有多字段的笔记类型（从 Anki 导入后出现）") }
                    ForEach(templates) { t in
                        Button("\(t.name)（\(t.fieldNames.count) 个字段）…") { store.templateEditor = t }
                    }
                } label: {
                    Label("卡片模板", systemImage: "rectangle.split.2x1")
                }
                .help("多字段卡片：设置正面、背面各显示哪些字段，哪些折叠")
                Button { store.findDuplicateCards() } label: { Label("查重", systemImage: "square.on.square") }
                    .help("比较已有的重复记忆卡，选择保留的卡片和学习进度")
                if store.cardWorkflow.addedCount > 0 {
                    Button { store.cardWorkflow.showsBatch = true } label: { Label("本次录入",systemImage:"list.bullet.rectangle") }
                        .help("查看本次新建的卡片、重新编辑或批量调整牌组与标签").handCursor()
                }
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

}

// MARK: - 1.9：原文语境

/// 记忆卡背面下方：同一出处里按页码排在这条前后的几条摘录，这条用书脊色标出
struct CardContextPanel: View {
    @Environment(LibraryStore.self) private var store
    let highlightId: Int64

    var body: some View {
        let ctx = try? store.db.contextHighlights(around: highlightId, radius: 2)
        let src = ctx?.items.first.flatMap { store.source(for: $0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("原文语境").font(.custom("Kaiti SC", size: 13)).foregroundStyle(Color(red: 0x9C / 255, green: 0x5B / 255, blue: 0x3B / 255))
                if let src { Text("《\(src.title)》按页码").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub) }
                Spacer()
            }
            if let ctx, ctx.items.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(ctx.items.enumerated()), id: \.offset) { i, h in
                            let current = i == ctx.index
                            HStack(alignment: .top, spacing: 10) {
                                Text(h.location?.trimmingCharacters(in: .whitespaces).isEmpty == false ? h.location! : "—")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(ReviewPalette.sub)
                                    .frame(width: 78, alignment: .trailing)
                                    .lineLimit(1)
                                Text(RichText.attributed(h.text))
                                    .font(.system(size: 13.5, design: .serif))
                                    .foregroundStyle(current ? ReviewPalette.ink : ReviewPalette.sub)
                                    .lineLimit(current ? 3 : 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(current ? ReviewPalette.accentSoft : .clear))
                        }
                    }
                }
                .frame(maxHeight: 170)
            } else {
                Text(ctx == nil ? "这条摘录没有出处，无法排出前后文。" : "这个出处里只有这一条摘录。")
                    .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(ReviewPalette.soft)
        .overlay(alignment: .top) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
    }
}

// MARK: - 学习（仿 Anki：先看正面，空格显示答案，1–4 评分）

struct StudyView: View {
    @Environment(LibraryStore.self) private var store
    /// 3.15.1：记住“先作答再对照”的开关
    @AppStorage("study.selfAnswerFirst") private var selfAnswerEnabled = false
    @State private var selfAnswer = CardSelfAnswerDraft()
    @State private var selfAnswerEditing = false
    private var study: StudyState { store.study }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let card = study.current {
                let f = store.faces(of: card)
                VStack(spacing: 0) {
                    ReviewCardContainer(padding: 0) {
                        cardHeader(card)
                            .padding(.horizontal, 28)
                            .padding(.top, 20)
                        if selfAnswerEnabled {
                            ScrollView {
                                VStack(alignment:.leading,spacing:16) {
                                    RichWebText(text:f.front,slot:"formal-self-front-\(card.id ?? 0)")
                                    CardSelfAnswerPanel(draft:Binding(get:{ selfAnswer },set:{ value in
                                        guard study.current?.id == card.id else { return }
                                        selfAnswer = value
                                    }),showingAnswer:study.showingAnswer,
                                        referenceHTML:f.back,slot:"formal-self-\(card.id ?? 0)",
                                        onReveal:{ if study.current?.id == card.id { study.showingAnswer = true } },
                                        onEditingChanged:{ if study.current?.id == card.id { selfAnswerEditing = $0 } })
                                        .id(card.id)
                                }.padding(20)
                            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                        } else {
                            CardWebView(front: f.front, back: study.showingAnswer ? f.back : nil, store: store, css: store.cardCSS(for: card))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                        }
                        // 1.9：原文语境——同一出处里按页码排在前后的摘录
                        if study.showingAnswer, study.showContext, let hid = card.highlightId {
                            CardContextPanel(highlightId: hid)
                        }
                        // 4.1.2：由摘录做成的卡，显示答案后提示引用其原摘录的札记，与“原文语境”并列
                        if study.showingAnswer, let hid = card.highlightId,
                           let notes = store.ideaNotesCiting([hid])[hid], !notes.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(ReviewPalette.accent)
                                Text("原摘录用在札记中：").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                                ForEach(notes.prefix(3)) { ref in
                                    Button("《\(ref.title)》") { store.selection = .ideaNote(ref.id) }
                                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ReviewPalette.accent)
                                        .lineLimit(1).handCursor()
                                }
                                if notes.count > 3 { Text("等 \(notes.count) 条").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20).padding(.bottom, 10)
                        }
                    }
                    // 1.8：左侧书脊用牌组的传统色
                    .overlay {
                        // 只裁书脊本身，不裁卡片的阴影
                        Rectangle()
                            .fill(DeckColors.color(for: card.deck))
                            .frame(width: 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: 860, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    controls(card)
                        .padding(.top, 18)
                        .padding(.bottom, 20)
                }
            } else {
                finished
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle("学习 · \(study.deck ?? "")")
        .disabled(store.learningExplorer != nil)
        .onChange(of:study.current?.id) { _,_ in resetSelfAnswer() }
        .onChange(of:study.showingAnswer) { wasShown,isShown in if wasShown && !isShown { resetSelfAnswer() } }
        .onChange(of:selfAnswerEnabled) { _,enabled in if !enabled { selfAnswerEditing = false } }
        .onAppear { if study.current == nil && !study.finished { store.nextCard() } }
        .task {
            store.refreshDerived()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                store.checkDayChange()
                store.refreshDerived()
            }
        }
    }

    private var counts: StudyQueue.Counts {
        _ = store.revision
        if store.cardLearningSummaryScope == store.currentCardLearningScope,
           let summary = store.cardLearningSummary { return summary.pending }
        if study.notebookId != nil { return study.notebookCounts }
        guard let deck = study.deck,
              let s = store.deckSummaryCache.first(where: { $0.name == deck }) else { return .init() }
        return s.counts
    }

    private var header: some View {
        HStack {
            Button {
                store.openCardsHome()
            } label: { Label("牌组", systemImage: "chevron.left") }
                .keyboardShortcut(.escape, modifiers: [])
                .handCursor()
            Spacer()
            let c = counts
            HStack(spacing: 16) {
                headerCount(DeckColors.newColor, "新卡", c.new)
                headerCount(DeckColors.learnColor, "学习中", c.learning)
                headerCount(DeckColors.reviewColor, "待复习", c.review)
            }
            Spacer()
            Toggle("先作答再对照",isOn:$selfAnswerEnabled).toggleStyle(.checkbox).fixedSize()
                .help("先写下自己的回答，点“对照参考答案”（⌘↩）后才显示答案；对照后仍用原评分按钮安排复习")
            Button { store.undoLastCardRating() } label: {
                Label("撤销评分", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut(!selfAnswerEditing && store.cardRatingShortcutIsAvailable
                              ? KeyboardShortcut("z", modifiers: .command) : nil)
            .disabled(!store.canUndoLastCardRating)
            .handCursor()
            .help("撤销上一笔评分，恢复这张卡原来的学习安排（⌘Z）")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func headerCount(_ color: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            Text("\(n)").font(.system(size: 14, weight: .medium, design: .serif).monospacedDigit())
                .foregroundStyle(n == 0 ? ReviewPalette.sub : ReviewPalette.pending)
        }
    }

    /// 卡片顶部：牌组、状态、记住概率；右侧原摘录、编辑、暂停
    private func cardHeader(_ card: Card) -> some View {
        HStack(alignment: .center, spacing: 10) {
            let parts = DeckOverview.split(card.deck)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let parent = parts.parent {
                    Text(parent + " ·").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                }
                Text(parts.leaf).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
            }
            Text(stateLabel(card))
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(stateColor(card).opacity(0.15), in: Capsule())
                .foregroundStyle(stateColor(card))
            if store.options(for: card.deck).algorithm == .fsrs,
               let r = FSRS(parameters: CardSettings.fsrsParameters).currentRetrievability(card) {
                Text("记住概率约 \(Int((r * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("FSRS 估计此刻还记得这张卡的概率（稳定性 \(String(format: "%.1f", card.stability ?? 0)) 天，难度 \(String(format: "%.1f", card.difficulty ?? 0))）")
            }
            Spacer()
            if card.highlightId != nil {
                if study.showingAnswer {
                    CardIconButton(icon: "text.alignleft", help: study.showContext ? "收起原文语境（C）" : "原文语境：同一出处里前后几条摘录，按页码（C）",
                                   active: study.showContext) {
                        study.showContext.toggle()
                    }
                    .keyboardShortcut(selfAnswerEditing ? nil : KeyboardShortcut("c",modifiers:[]))
                }
                CardIconButton(icon: "text.quote", help: "原摘录（出处、按语、标签）") { store.openHighlight(of: card) }
            }
            CardIconButton(icon: "square.and.pencil", help: "编辑这张卡（E）") { store.editCard(card) }
                .keyboardShortcut(selfAnswerEditing ? nil : KeyboardShortcut("e",modifiers:[]))
            CardIconButton(icon: "pause.circle", help: "暂停这张卡：不再出现在学习中，可在“浏览”里恢复") {
                if let id = card.id { store.setSuspended(true, cards: [id]) }
                store.nextCard()
            }
        }
    }

    private func stateLabel(_ c: Card) -> String {
        switch c.state {
        case .new: return "新卡"
        case .learning: return "学习中"
        case .relearning: return "重学"
        case .review: return "复习"
        }
    }

    private func stateColor(_ c: Card) -> Color {
        switch c.state {
        case .new: return DeckColors.newColor
        case .learning: return DeckColors.learnColor
        case .relearning: return DeckColors.seal
        case .review: return DeckColors.reviewColor
        }
    }

    /// 卡片下方：先“显示答案”，再四个评分（每个按钮写着下次间隔与数字键）
    @ViewBuilder
    private func controls(_ card: Card) -> some View {
        if !study.showingAnswer && selfAnswerEnabled {
            // 先作答模式：答案只由回答框下方的“对照参考答案”打开，空格不翻面
            Text("评分按钮在对照参考答案之后出现")
                .font(.caption).foregroundStyle(ReviewPalette.sub)
                .frame(height: 36)
        } else if !study.showingAnswer {
            PillButton(icon: "eye", title: "显示答案", key: "空格", style: .primary) {
                study.showingAnswer = true
            }
            .keyboardShortcut(selfAnswerEditing ? nil : KeyboardShortcut(.space,modifiers:[]))
        } else {
            let preview = store.scheduler(forDeck: card.deck).preview(card, now: Date())
            HStack(spacing: 10) {
                ForEach(CardAnswer.allCases, id: \.self) { a in
                    GradeButton(title: a.label, detail: "\(preview[a] ?? "") · \(a.rawValue)",
                                dot: answerColor(a), primary: a == .good) {
                        store.answerCurrent(a)
                    }
                    .keyboardShortcut(selfAnswerEditing ? nil : KeyboardShortcut(KeyEquivalent(Character(String(a.rawValue))),modifiers:[]))
                }
            }
            .background {
                // 与 Anki 相同：显示答案后，空格 = 良好
                Button("") { store.answerCurrent(.good) }
                    .keyboardShortcut(selfAnswerEditing ? nil : KeyboardShortcut(.space,modifiers:[]))
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    private func answerColor(_ a: CardAnswer) -> Color {
        switch a {
        case .again: return DeckColors.seal
        case .hard: return DeckColors.all[3].color     // 藤黄
        case .good: return ReviewPalette.accent
        case .easy: return DeckColors.all[2].color     // 松绿
        }
    }

    private func resetSelfAnswer() {
        selfAnswer = CardSelfAnswerDraft()
        selfAnswerEditing = false
    }

    /// 当前范围的学习总结：张数去重、评分次数独立，待学状态随排程更新。
    private var finished: some View {
        ScrollView {
            if store.cardLearningSummaryScope == store.currentCardLearningScope,
               let summary = store.cardLearningSummary {
                CardLearningCompletionView(summary: summary,
                                           globalStudiedCards: store.learningActivitySummary.today.cards,
                                           globalRatingCount: store.learningActivitySummary.today.cardRatings,
                                           onReturn: { store.openCardsHome() },
                                           onResume: { store.nextCard(); store.refreshDerived() },
                                           revisitLeft: store.revisitCounts.left,
                                           onRevisit: { store.openExam() })
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView("正在更新学习统计…").padding(40)
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

    private struct LoadKey: Hashable {
        var deck: String
        var query: String
        var tag: String
        var state: CardBrowseStateFilter
        var page: Int
        var pageSize: Int
        var revision: Int
    }

    var body: some View {
        let list = study.browseItems
        let selected = Array(study.browseSelection)
        let deckNames = store.deckSummaryCache.map(\.name).sorted()
        return VStack(spacing: 0) {
            HStack {
                Button {
                    store.openCardsHome()
                } label: { Label("牌组", systemImage: "chevron.left") }
                TextField("搜索正面、背面、标签", text: Bindable(store.study).browseQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Text("共 \(study.browseTotal) 张").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { browseFilters; Spacer(); selectionControls }
                VStack(alignment: .leading, spacing: 8) { browseFilters; selectionControls }
            }
            .controlSize(.small)
            .padding(.horizontal)
            .padding(.bottom, 10)
            Divider()
            if study.browseIsLoading && list.isEmpty {
                ProgressView("正在载入记忆卡…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.isEmpty {
                ContentUnavailableView(study.browseQuery.isEmpty && study.browseTag.isEmpty && study.browseStateFilter == .all ? "这个牌组还没有卡片" : "没有符合条件的记忆卡",
                                       systemImage: "rectangle.on.rectangle")
            } else {
            ScrollViewReader { proxy in
            List(list, id: \.rowID, selection: Bindable(store.study).browseSelection) { c in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview(c.front, limit: 1600))
                            .lineLimit(2)
                        if !c.back.isEmpty {
                            Text(preview(c.back, limit: 600))
                                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        if !c.tags.isEmpty {
                            Text(c.tags.map { "#" + $0 }.joined(separator: " "))
                                .font(.caption).foregroundStyle(ReviewPalette.accent).lineLimit(1)
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
                .id(c.rowID)
                .contextMenu { menu(for: study.browseSelection.contains(c.rowID) ? selected : [c.rowID], deckNames: deckNames) }
                .onTapGesture(count: 2) { store.editCard(c) }
            }
            .id("\(deck)|\(study.browsePage)|\(study.browseLoadedQuery)|\(study.browseLoadedTag)|\(study.browseLoadedState.rawValue)")
            .disabled(study.browseIsLoading)
            .onAppear { restoreBrowseAnchor(proxy) }
            .onChange(of: study.browseItems) { _, _ in restoreBrowseAnchor(proxy) }
            }
            }
            Divider()
            pageControls
        }
        .navigationTitle("浏览 · \(deck)")
        .task(id: LoadKey(deck: deck, query: study.browseQuery, tag: study.browseTag,
                          state: study.browseStateFilter, page: study.browsePage,
                          pageSize: study.browsePageSize, revision: store.revision)) {
            await loadPage()
        }
        .onDisappear { study.persistBrowsePosition() }
        .sheet(item: Bindable(store.study).cardTagEdit) { _ in CardTagBatchEditView() }
        .toolbar {
            ToolbarItemGroup {
                Button { store.newCard(deck: deck) } label: { Label("新建卡片", systemImage: "plus") }
                Menu {
                    menu(for: selected, deckNames: deckNames)
                } label: {
                    Label("操作", systemImage: "ellipsis.circle")
                }
                .disabled(selected.isEmpty || study.browseIsLoading)
                Button("学习") { store.startStudy(deck: deck) }
            }
        }
    }

    private var browseFilters: some View {
        HStack(spacing: 10) {
            Picker("标签", selection: Bindable(store.study).browseTag) {
                Text("全部标签").tag("")
                ForEach(Array(Set(study.browseTagOptions + (study.browseTag.isEmpty ? [] : [study.browseTag]))).sorted(), id: \.self) { tag in
                    Text("#" + tag).tag(tag)
                }
            }.frame(maxWidth: 220)
            Picker("状态", selection: Bindable(store.study).browseStateFilter) {
                ForEach(CardBrowseStateFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 160)
            if !study.browseTag.isEmpty || study.browseStateFilter != .all {
                Button("清除筛选") { study.browseTag = ""; study.browseStateFilter = .all }
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 10) {
            Text("本页已选 \(study.browseSelection.count) 张").font(.caption).foregroundStyle(.secondary)
            Button("选中本页") { study.browseSelection = Set(study.browseItems.compactMap(\.id)) }
                .disabled(study.browseItems.isEmpty || study.browseIsLoading)
            if !study.browseSelection.isEmpty {
                Button("取消选择") { study.browseSelection = [] }
                Menu("标签操作") {
                    Button("添加标签…") { store.editCardTags(.add, ids: Array(study.browseSelection), deck: deck) }
                    Button("移除标签…") { store.editCardTags(.remove, ids: Array(study.browseSelection), deck: deck) }
                }.disabled(study.browseIsLoading)
            }
        }
    }

    private var pageControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pageStatus
                Spacer()
                pageNavigation
                pageJump
            }
            VStack(alignment: .leading, spacing: 8) {
                pageStatus
                HStack(spacing: 12) { pageNavigation; Spacer(); pageJump }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pageStatus: some View {
        HStack(spacing: 8) {
            if study.browseIsLoading { ProgressView().controlSize(.small) }
            Picker("每页", selection: Binding(get: { study.browsePageSize }, set: { study.changeBrowsePageSize($0) })) {
                ForEach(ListPositionPersistence.pageSizes, id: \.self) { Text("每页 \($0) 张").tag($0) }
            }.labelsHidden().frame(width: 115)
            Text(study.browseTotal == 0 ? "共 0 张" :
                "第 \((study.browsePage - 1) * study.browsePageSize + 1)–\(min(study.browsePage * study.browsePageSize, study.browseTotal)) 张，共 \(study.browseTotal) 张")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var pageNavigation: some View {
        HStack(spacing: 8) {
            Button { goToPage(study.browsePage - 1) } label: { Label("上一页", systemImage: "chevron.left") }
                .disabled(study.browsePage <= 1 || study.browseIsLoading)
            Text("第 \(study.browsePage) / \(study.browsePageCount) 页").monospacedDigit().fixedSize()
            Button { goToPage(study.browsePage + 1) } label: { Label("下一页", systemImage: "chevron.right") }
                .disabled(study.browsePage >= study.browsePageCount || study.browseIsLoading)
        }
    }

    private var pageJump: some View {
        HStack(spacing: 6) {
            TextField("页码", text: Bindable(store.study).browsePageInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 52)
                .accessibilityLabel("跳转到记忆卡页码")
                .onSubmit(jumpToPage)
            Button("跳转", action: jumpToPage)
        }
        .disabled(study.browseIsLoading)
    }

    private func jumpToPage() {
        goToPage(Int(study.browsePageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? study.browsePage)
    }

    private func restoreBrowseAnchor(_ proxy: ScrollViewProxy) {
        if let anchor = study.browseAnchorID, study.browseItems.contains(where: { $0.id == anchor }) {
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .center) }
        }
    }

    private func goToPage(_ page: Int) {
        let target = min(max(1, page), study.browsePageCount)
        study.browsePageInput = String(target)
        guard target != study.browsePage else { return }
        study.browseLoadID = UUID()
        study.browseSelection = []
        study.browseItems = []
        study.browseAnchorID = nil
        study.browseIsLoading = true
        study.browsePage = target
    }

    @MainActor
    private func loadPage() async {
        guard !Task.isCancelled, study.browsingDeck == deck else { return }
        let requestID = UUID()
        let query = study.browseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = study.browseTag
        let state = study.browseStateFilter
        study.browseLoadID = requestID
        if study.browseOwnerDeck != deck || study.browseLoadedQuery != query || study.browseLoadedTag != tag || study.browseLoadedState != state {
            study.browseOwnerDeck = deck
            study.browseLoadedQuery = query
            study.browseLoadedTag = tag
            study.browseLoadedState = state
            study.browseSelection = []
            study.browseItems = []
            study.browseTotal = 0
            study.browsePageInput = "1"
            if study.browsePage != 1 {
                study.browsePage = 1
                return
            }
        }
        let page = study.browsePage
        let size = study.browsePageSize
        let revision = store.revision
        study.browseIsLoading = true
        defer { if study.browseLoadID == requestID { study.browseIsLoading = false } }
        do {
            let result = try await store.db.cardPage(deck: deck, query: query, limit: size,
                                                    offset: (page - 1) * size, tag: tag, state: state)
            let tags: [String]
            if study.browseTagOptionsDeck == deck, study.browseTagOptionsRevision == revision {
                tags = study.browseTagOptions
            } else {
                tags = try await store.db.cardTagOptions(deck: deck)
            }
            guard !Task.isCancelled, study.browseLoadID == requestID, study.browsingDeck == deck,
                  study.browsePage == page, study.browsePageSize == size, store.revision == revision,
                  study.browseQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                  study.browseTag == tag, study.browseStateFilter == state else { return }
            study.browseTagOptions = tags
            study.browseTagOptionsDeck = deck
            study.browseTagOptionsRevision = revision
            study.browseTotal = result.total
            if page > study.browsePageCount {
                study.browsePage = study.browsePageCount
                study.browsePageInput = String(study.browsePage)
                study.browseItems = []
                study.browseSelection = []
                study.browseAnchorID = nil
                return
            }
            study.browseItems = result.items
            study.browsePageInput = String(page)
            let visible = Set(result.items.compactMap(\.id))
            study.browseSelection.formIntersection(visible)
            study.persistBrowsePosition()
        } catch {
            if !Task.isCancelled, study.browseLoadID == requestID { store.report(error) }
        }
    }

    private func preview(_ text: String, limit: Int) -> String {
        Markdown.plainText(fromHTML: Card.renderHTML(String(text.prefix(limit))))
    }

    @ViewBuilder
    private func menu(for ids: [Int64], deckNames: [String]) -> some View {
        if ids.count == 1, let id = ids.first, let c = try? store.db.card(id: id) {
            Button("编辑…") { store.editCard(c) }
            if c.highlightId != nil {
                Button("查看原摘录…") { store.openHighlight(of: c) }
            }
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
        Button("添加标签…") { store.editCardTags(.add, ids: ids, deck: deck) }
        Button("移除标签…") { store.editCardTags(.remove, ids: ids, deck: deck) }
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
    @State private var comparison: Card?
    @State private var duplicateComparison: Card?
    @State private var duplicateAppendReview = false
    @State private var showsHistory = false
    @State private var checkingDuplicate = false
    @State private var learningPreview: CardEditorPreviewSnapshot?
    @State private var showsSavePreset = false
    @State private var presetName = ""
    @State private var presetSourceID: UUID?

    private func binding<T>(_ kp: WritableKeyPath<CardDraft, T>, _ fallback: T) -> Binding<T> {
        CardEditorSessionBindings.value(store,kp,fallback:fallback)
    }
    private func fieldBinding(_ i: Int) -> Binding<String> { CardEditorSessionBindings.field(store,index:i) }

    var body: some View {
        let draft = store.cardEditor
        let decks = (try? store.db.deckNames()) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft?.isNew == true ? (draft?.card.highlightId != nil ? "预览并编辑新记忆卡" : "新建记忆卡") : "编辑记忆卡").font(.title2.bold())
                Spacer()
                entryPresetMenu
                Button { afterFlushing {
                    if let current = store.cardEditor { learningPreview = CardEditorPreviewSnapshot(draft:current,templates:store.noteTemplates) }
                } } label: { Label("预览卡片",systemImage:"eye") }
                    .handCursor().help("按学习时的排版查看当前输入，并翻面检查答案")
                    .accessibilityIdentifier("card-editor-preview")
            }
            if store.cardWorkflow.addedCount > 0 {
                Button("本次已添加 \(store.cardWorkflow.addedCount) 张 · 查看清单") { afterFlushing { store.cardWorkflow.showsBatch = true } }
                    .buttonStyle(.link).font(.callout).handCursor()
                    .accessibilityIdentifier("card-editor-added-count")
            }
            if draft?.isNew == true, let id = draft?.card.highlightId {
                Text("确认问题、答案、牌组和标签后保存。已有相关卡片可展开核对，关闭时可保留草稿。").font(.caption).foregroundStyle(.secondary)
                RelatedCardsInline(highlightID: id)
            }
            if let notice = store.draftRecoveryNotice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            if store.canReturnToIncomingCardDraft {
                Button("返回本次草稿") { afterFlushing { store.returnToIncomingCardDraft() } }
                    .buttonStyle(.link).handCursor()
                    .help("保留原卡未保存的修改，回到刚才输入的卡片")
                    .accessibilityIdentifier("card-editor-return-incoming")
            }
            if store.canReturnToBulkEntry {
                Button("返回批量录入") { afterFlushing { store.returnToBulkEntry() } }
                    .buttonStyle(.link).handCursor()
                    .help("保留这张原卡尚未保存的修改，返回整批候选继续整理")
                    .accessibilityIdentifier("card-editor-return-bulk")
            }
            if let error = store.draftSaveError { Text(error).font(.caption).foregroundStyle(.red) }
            else if store.draftPersistence != nil { Text("草稿自动保存在本机").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("牌组")
                TextField("牌组", text: binding(\.card.deck, ""))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { afterFlushing {
                        if let value = store.cardEditor?.card.deck { store.selectDeckForCardEntry(value) }
                    } }
                Menu("选择") {
                    ForEach(decks, id: \.self) { d in
                        Button(d) { afterFlushing { store.selectDeckForCardEntry(d) } }
                    }
                }
                .fixedSize()
                Text("标签")
                TextField("用逗号或空格分隔", text: binding(\.tagsText, ""))
                    .textFieldStyle(.roundedBorder)
            }
            if draft?.isNew == true {
                HStack(spacing:14) {
                    Text("连续添加时沿用").font(.caption).foregroundStyle(.secondary)
                    Toggle("牌组",isOn:Bindable(store.cardWorkflow).keepDeck)
                    Toggle("标签",isOn:Bindable(store.cardWorkflow).keepTags)
                    Toggle("栏目结构",isOn:Bindable(store.cardWorkflow).keepStructure)
                    Spacer(minLength:0)
                }.toggleStyle(.checkbox).controlSize(.small)
            }
            CardFormattingToolbar(state: store.cardFormatting)
            if let duplicate = draft?.duplicate {
                CardInputDuplicateNotice(card:duplicate,heading:"正面",presentPreview:{ target,append in
                    duplicateAppendReview = append
                    duplicateComparison = target
                }) { store.commitCardEditor(allowDeleted:true) }
                    .id(duplicate.id)
            }
            // 1.2：所见即所得编辑（去掉右侧预览）；背面可加多个自定义栏目
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let c = draft?.card, let type = c.noteType, !c.fields.isEmpty {
                        // 多字段卡片：逐个字段编辑，正反面由“卡片模板”决定
                        let names = store.noteTemplates[type]?.fieldNames ?? []
                        Text("笔记类型：\(type)（正反面怎么排由“记忆卡 → 卡片模板”决定）")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(c.fields.indices), id: \.self) { i in
                            editorFieldHeading(i < names.count ? names[i] : "字段\(i + 1)",isFront:store.noteTemplates[type]?.front.first == i || (store.noteTemplates[type] == nil && i == 0), entryKey: "field:\(i)")
                            entryFieldHelp("field:\(i)")
                            RichEditor(text: fieldBinding(i), mode: .card, placeholder: entryPlaceholder("field:\(i)", fallback: ""), toolbar: false, autoHeight: true,
                                       slot: "card-field-\(i)", onSubmit: submit, onCancel: cancel,
                                       formatting: store.cardFormatting, fieldName: i < names.count ? names[i] : "字段\(i + 1)")
                                .richEditorFrame()
                        }
                    } else {
                        editorFieldHeading("正面",isFront:true, entryKey: "front")
                        entryFieldHelp("front")
                        RichEditor(text: binding(\.card.front, ""), mode: .card, placeholder: entryPlaceholder("front", fallback: "问题、字词或章句"),
                                   toolbar: false, autoHeight: true, focus: draft?.isNew == true, slot: "card-front",
                                   onSubmit: submit, onCancel: cancel, formatting: store.cardFormatting, fieldName: "正面")
                            .richEditorFrame()
                        editorFieldHeading("背面",isFront:false, entryKey: "back").padding(.top, 6)
                        entryFieldHelp("back")
                        RichEditor(text: binding(\.card.back, ""), mode: .card, placeholder: entryPlaceholder("back", fallback: "答案"),
                                   toolbar: false, autoHeight: true, slot: "card-back",
                                   onSubmit: submit, onCancel: cancel, formatting: store.cardFormatting, fieldName: "背面")
                            .richEditorFrame()
                        sectionsEditor
                    }
                }
                .padding(.trailing, 6)
            }
            if let error = draft?.error, draft?.duplicate == nil {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("默认编辑文字；点击各字段右上角 <> 切换 HTML 源码。⌘B、⌘I、⌘K 设置格式；⌘↩ 保存。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let c = draft?.card, c.id != nil {
                    Text(c.state == .new ? "新卡" : "已复习 \(c.reps) 次，遗忘 \(c.lapses) 次，间隔 \(Int(c.interval)) 天"
                         + (c.stability.map { "，FSRS 稳定性 \(String(format: "%.1f", $0)) 天" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if c.highlightId != nil {
                        Button("原摘录…") {
                            afterFlushing {
                                guard store.draftPersistence != nil else {
                                    store.cardEditor?.error = "草稿保存暂不可用，请先保存当前修改再打开原摘录。"
                                    return
                                }
                                store.keepAndCloseEditor(.card)
                                if store.cardEditor == nil { store.openHighlight(of:c) }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Spacer()
                if let id = draft?.card.id {
                    Button("修改对照") {
                        afterFlushing {
                            do { comparison = try store.db.card(id:id) } catch { store.cardEditor?.error = error.localizedDescription }
                        }
                    }
                    Button("修改历史") { showsHistory = true }
                }
                Button("取消", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                if draft?.isNew == true {
                    Button("保存并新增") { afterFlushing { store.commitCardAndContinue() } }
                        .handCursor().help("保存成功后继续新建，按上方选项沿用牌组、标签和栏目结构")
                        .accessibilityIdentifier("card-editor-save-and-new")
                        .disabled(!hasFrontContent)
                }
                Button(store.canReturnToBulkEntry ? "保存并返回批量录入" : (store.canReturnToIncomingCardDraft ? "保存并返回草稿" : "保存")) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(!hasFrontContent)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 600, idealHeight: 720)
        .disabled(store.cardWorkflow.actionBusy || store.fullBackupBusy)
        .id(store.cardEditor?.id)
        .task(id:store.cardEditor?.card) { await checkDuplicate() }
        .sheet(item:$comparison) { original in
            if let current = store.cardEditor?.card { CardComparisonView(incoming:current,existing:original) }
        }
        .sheet(item:$duplicateComparison) { original in
            if let current = store.cardEditor {
                CardComparisonView(incoming:current.card,existing:original,draftID:current.id,appendReview:duplicateAppendReview)
            }
        }
        .sheet(isPresented:$showsHistory) { if let id = store.cardEditor?.card.id { CardHistoryView(cardID:id) } }
        .sheet(item:$learningPreview) { CardEditorPreviewView(snapshot:$0) }
        .modifier(CardEntryPresetPresentation(insideEditor:true))
        .modifier(DeckEntryPresetPresentation(host:.cardEditor))
        .modifier(CardEntryBatchPresentation(insideEditor:true))
        .modifier(CardEntryHistoryPresentation(insideEditor:true))
        .modifier(CardBulkEntryPresentation(insideEditor:true))
        .alert("保存录入预设",isPresented:$showsSavePreset) {
            TextField("预设名称",text:$presetName)
            Button("取消",role:.cancel) { }
            Button("保存") {
                guard store.cardEditor?.id == presetSourceID else { return }
                do { _ = try store.saveCurrentCardEntryPreset(name:presetName) }
                catch { store.cardEditor?.error = error.localizedDescription }
            }
        } message: { Text("仅保存牌组、标签及空白栏目／字段结构。") }
    }
    private var entryPresetMenu: some View {
        let library = (try? store.db.cardEntryPresetLibrary()) ?? .init()
        return Menu("录入预设") {
            if let deck = store.cardEditor?.card.deck,let preset = library.preset(for:deck) {
                Button("应用本牌组模板：" + preset.name) { afterFlushing { store.applyCurrentDeckEntryPreset() } }
            }
            ForEach(library.presets) { preset in
                Button(preset.name) { afterFlushing { store.applyCardEntryPreset(preset) } }
            }
            Divider()
            Button("批量粘贴问答…") { afterFlushing { store.showsCardBulkEntry = true } }
            Button("今日录入与录入历史…") { afterFlushing { store.cardEntryHistory.isPresented = true } }
            Button("设置当前牌组的录入模板…") { afterFlushing {
                if let deck = store.cardEditor?.card.deck { store.deckEntryPresetEditor = .init(deck:deck) }
            } }
            Button("保存当前结构为预设…") { afterFlushing {
                presetSourceID = store.cardEditor?.id;presetName = "";showsSavePreset = true
            } }
            Button("管理录入预设…") { afterFlushing { store.showsCardEntryPresetManager = true } }
        }.fixedSize().handCursor().help("套用常用结构，或将当前牌组、标签和空白栏目保存为预设")
    }
    private var hasFrontContent: Bool {
        guard let card = store.cardEditor?.card else { return false }
        return CardContinuousEntry.hasFrontContent(card,template:card.noteType.flatMap { store.noteTemplates[$0] })
    }
    private func afterFlushing(_ action: @escaping () -> Void) {
        guard let id = store.cardEditor?.id,!store.fullBackupBusy,!store.cardWorkflow.actionBusy else { return }
        let generation = store.cardWorkflow.generation
        store.cardWorkflow.actionBusy = true
        store.cardFormatting.flushEditors { success in
            guard store.cardWorkflow.generation == generation else { return }
            store.cardWorkflow.actionBusy = false
            guard store.cardEditor?.id == id,store.cardWorkflow.generation == generation,!store.fullBackupBusy else { return }
            guard success else { store.cardEditor?.error = "编辑器尚未完成同步，请稍后再试。当前输入仍保留。"; return }
            action()
        }
    }
    private func save() {
        afterFlushing {
            let returnsToBulk = store.canReturnToBulkEntry
            let returnsToDraft = store.canReturnToIncomingCardDraft
            if store.commitCardEditor() != nil, store.cardEditor == nil {
                // The editor sheet's dismissal restores the batch after the old sheet
                // has gone, so the two presentations cannot compete.
                if !returnsToBulk && returnsToDraft { store.returnToIncomingCardDraft() }
            }
        }
    }
    private func editorFieldHeading(_ title: String,isFront: Bool, entryKey: String? = nil) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(title).font(.headline)
            if let entryKey { entryRequiredIndicator(entryKey) }
            if isFront && checkingDuplicate && store.cardEditor?.duplicate == nil { Text("正在检查…").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength:0)
        }
    }
    private func entryPlaceholder(_ key: String, fallback: String) -> String {
        store.cardEditor?.entryGuidance?.rule(for: key)?.hint.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? fallback
    }
    @ViewBuilder
    private func entryRequiredIndicator(_ key: String) -> some View {
        if store.cardEditor?.entryGuidance?.rule(for: key)?.required == true {
            let missing = store.cardEditor?.entryValidationAttempted == true &&
                store.cardEditor?.entryValidationIssues(templates: store.noteTemplates).contains(where: { $0.key == key }) == true
            Text(missing ? "请填写（必填）" : "必填")
                .font(.caption).foregroundStyle(missing ? Color.red : Color.secondary)
        }
    }
    @ViewBuilder
    private func entryFieldHelp(_ key: String) -> some View {
        if let hint = store.cardEditor?.entryGuidance?.rule(for: key)?.hint.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func checkDuplicate() async {
        guard let draft = store.cardEditor, !store.fullBackupBusy else { return }
        checkingDuplicate = true
        do {
            try await Task.sleep(for:.milliseconds(450))
            let duplicate = try await store.db.liveCardDuplicate(draft.card)
            try Task.checkCancellation()
            guard store.cardEditor?.id == draft.id, store.cardEditor?.card == draft.card, !store.fullBackupBusy else { return }
            store.cardEditor?.duplicate = duplicate
            checkingDuplicate = false
        } catch is CancellationError { } catch {
            if store.cardEditor?.id == draft.id && store.cardEditor?.card == draft.card {
                checkingDuplicate = false; store.cardEditor?.error = "实时查重未完成，保存时会重新检查：" + error.localizedDescription
            }
        }
    }

    // MARK: 背面栏目（1.2）

    /// 背面的自定义栏目：名称、内容、是否默认折叠；可增删、上下移动
    @ViewBuilder
    private var sectionsEditor: some View {
        let secs = store.cardEditor?.card.sections ?? []
        ForEach(secs) { sec in
            let i = secs.firstIndex(where: { $0.id == sec.id }) ?? 0
            Divider().padding(.top, 10)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("栏目名称", text: sectionBinding(sec.id, \.name, ""))
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .frame(width: 150)
                    entryRequiredIndicator("section:" + sec.id)
                    Menu("常用") {
                        ForEach(CardSettings.sectionNames, id: \.self) { n in
                            Button(n) { sectionBinding(sec.id, \.name, "").wrappedValue = n }
                        }
                    }
                    .fixedSize()
                    Toggle("默认折叠（点开才显示）", isOn: sectionBinding(sec.id, \.folded, false))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Spacer()
                    Button { moveSection(sec.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless).disabled(i == 0).help("上移")
                    Button { moveSection(sec.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless).disabled(i == secs.count - 1).help("下移")
                    Button { removeSection(sec.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(store.cardEditor?.entryGuidance?.rule(for: "section:" + sec.id)?.required == true)
                        .help(store.cardEditor?.entryGuidance?.rule(for: "section:" + sec.id)?.required == true ? "此栏目为模板必填；如需调整，请先复制修改录入模板，再新建卡片。" : "删除这个栏目")
                }
                entryFieldHelp("section:" + sec.id)
                RichEditor(text: sectionBinding(sec.id, \.text, ""), mode: .card, placeholder: entryPlaceholder("section:" + sec.id, fallback: "栏目内容"),
                           toolbar: false, autoHeight: true, slot: "card-section-" + sec.id,
                           onSubmit: submit, onCancel: cancel, formatting: store.cardFormatting,
                           fieldName: sec.name.isEmpty ? "背面栏目" : sec.name)
                    .richEditorFrame()
            }
            .padding(.top, 8)
        }
        Menu {
            ForEach(CardSettings.sectionNames, id: \.self) { n in
                Button(n) { addSection(n) }
            }
            Divider()
            Button("自定义名称") { addSection("") }
        } label: {
            Label("添加背面栏目", systemImage: "plus.circle")
        } primaryAction: {
            addSection("")
        }
        .menuStyle(.borderlessButton)
        .handCursor()
        .fixedSize()
        .padding(.top, 8)
        .help("在背面答案之后再加一栏，如“释义”“出处”“例句”；可加多个。点按直接添加，按住选常用名称。")
    }

    private func sectionBinding<T>(_ id: String, _ kp: WritableKeyPath<CardSection, T>, _ fallback: T) -> Binding<T> {
        CardEditorSessionBindings.section(store,id:id,keyPath:kp,fallback:fallback)
    }

    private func addSection(_ name: String) {
        var secs = store.cardEditor?.card.sections ?? []
        secs.append(CardSection(name: name))
        store.cardEditor?.card.sections = secs
    }

    private func removeSection(_ id: String) {
        guard store.cardEditor?.entryGuidance?.rule(for: "section:" + id)?.required != true else { return }
        var secs = store.cardEditor?.card.sections ?? []
        secs.removeAll { $0.id == id }
        store.cardEditor?.card.sections = secs.isEmpty ? nil : secs
    }

    private func moveSection(_ id: String, by delta: Int) {
        guard var secs = store.cardEditor?.card.sections, let i = secs.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard secs.indices.contains(j) else { return }
        secs.swapAt(i, j)
        store.cardEditor?.card.sections = secs
    }

    /// 编辑器里按 ⌘↩
    private func submit() {
        save()
    }

    private func cancel() { afterFlushing { store.requestCloseCardEditor() } }
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
                    GridRow { Text("媒体文件"); Text("\(p.media.count) 个（只含卡片里用到的）").monospacedDigit() }
                    if p.withMemory > 0 || p.usesFSRS {
                        GridRow { Text("FSRS"); Text("\(p.withMemory) 张带记忆状态\(p.usesFSRS ? "；牌组沿用 Anki 的 FSRS 设置" : "")") }
                    }
                    if p.revlogCount > 0 {
                        GridRow { Text("复习记录"); Text("\(p.revlogCount) 条（进入统计，可用来优化 FSRS 参数）").monospacedDigit() }
                    }
                    if !p.noteTypes.isEmpty {
                        GridRow { Text("笔记类型"); Text(p.noteTypes.joined(separator: "、") + "（保留各字段，可设置正反面）").lineLimit(2) }
                    }
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
                Text("每条 Anki 笔记导入为一张卡（取第一张卡片；填空题合并为一张）。已导入过的笔记（同一 GUID）不会重复建卡，但会补上字段、记忆状态和复习记录。导入前自动备份。")
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
                    .handCursor()
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
