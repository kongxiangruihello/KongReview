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
        let html = Self.page(front: front, back: back, adjustDarkColors: CardSettings.adjustDarkColors)
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

    static func page(front: String, back: String?, adjustDarkColors: Bool = true) -> String {
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
        </style></head><body>\(body)
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
                Button { ExportService.importAnki(store: store) } label: { Label("导入 Anki", systemImage: "square.and.arrow.down") }
                    .help("导入 Anki 牌组（.apkg / .colpkg，或“纯文本笔记”导出的 .txt）")
                Button { store.apkgExport = ApkgExportRequest(allDecks: decks.map(\.name), decks: Set(decks.map(\.name))) } label: {
                    Label("导出到 Anki", systemImage: "square.and.arrow.up")
                }
                .help("导出为 .apkg，在 AnkiMobile / AnkiDroid / Anki 桌面版里导入复习")
                .disabled(decks.isEmpty)
                Menu {
                    let templates = store.noteTemplates.values.sorted { $0.name < $1.name }
                    if templates.isEmpty { Text("没有多字段的笔记类型（从 Anki 导入后出现）") }
                    ForEach(templates) { t in
                        Button("\(t.name)（\(t.fieldNames.count) 个字段）…") { store.templateEditor = t }
                    }
                } label: {
                    Label("卡片模板", systemImage: "rectangle.split.2x1")
                }
                .help("多字段卡片：设置正面、背面各显示哪些字段，哪些折叠")
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
                        CardWebView(front: f.front, back: study.showingAnswer ? f.back : nil, store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        // 1.9：原文语境——同一出处里按页码排在前后的摘录
                        if study.showingAnswer, study.showContext, let hid = card.highlightId {
                            CardContextPanel(highlightId: hid)
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
        .onAppear { if study.current == nil && !study.finished { store.nextCard() } }
    }

    private var counts: StudyQueue.Counts {
        _ = store.revision
        if study.notebookId != nil { return study.notebookCounts }
        guard let deck = study.deck,
              let s = store.deckSummaryCache.first(where: { $0.name == deck }) else { return .init() }
        return s.counts
    }

    private var header: some View {
        HStack {
            Button {
                study.deck = nil
                study.notebookId = nil
                study.current = nil
                study.finished = false
            } label: { Label("牌组", systemImage: "chevron.left") }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            let c = counts
            HStack(spacing: 16) {
                headerCount(DeckColors.newColor, "新卡", c.new)
                headerCount(DeckColors.learnColor, "学习中", c.learning)
                headerCount(DeckColors.reviewColor, "待复习", c.review)
            }
            Spacer()
            // 与左边的返回按钮对称，让计数居中
            Label("牌组", systemImage: "chevron.left").hidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func headerCount(_ color: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            Text("\(n)").font(.system(size: 14, weight: .medium, design: .serif).monospacedDigit())
                .foregroundStyle(n == 0 ? ReviewPalette.sub : ReviewPalette.ink)
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
                    .keyboardShortcut("c", modifiers: [])
                }
                CardIconButton(icon: "text.quote", help: "原摘录（出处、按语、标签）") { store.openHighlight(of: card) }
            }
            CardIconButton(icon: "square.and.pencil", help: "编辑这张卡（E）") { store.editCard(card) }
                .keyboardShortcut("e", modifiers: [])
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
        if !study.showingAnswer {
            PillButton(icon: "eye", title: "显示答案", key: "空格", style: .primary) {
                study.showingAnswer = true
            }
            .keyboardShortcut(.space, modifiers: [])
        } else {
            let preview = store.scheduler(forDeck: card.deck).preview(card, now: Date())
            HStack(spacing: 10) {
                ForEach(CardAnswer.allCases, id: \.self) { a in
                    GradeButton(title: a.label, detail: "\(preview[a] ?? "") · \(a.rawValue)",
                                dot: answerColor(a), primary: a == .good) {
                        store.answerCurrent(a)
                    }
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
        case .again: return DeckColors.seal
        case .hard: return DeckColors.all[3].color     // 藤黄
        case .good: return ReviewPalette.accent
        case .easy: return DeckColors.all[2].color     // 松绿
        }
    }

    /// 学完：页面中部的总结卡——今日复习次数、正确率、明天到期
    private var finished: some View {
        let _ = store.revision
        let start = Calendar.current.startOfDay(for: Date())
        let answers = (try? store.db.cardAnswersToday()) ?? (total: 0, correct: 0)
        let accuracy = answers.total == 0 ? "—" : "\(Int((Double(answers.correct) / Double(answers.total) * 100).rounded()))"
        let tomorrowEnd = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
        let deckCards: [Card] = {
            if let nid = study.notebookId {
                let ids = ((try? store.db.notebookHighlights(nid)) ?? []).compactMap(\.id)
                return (try? store.db.cards(highlightIds: ids)) ?? []
            }
            return study.deck.flatMap { try? store.db.cards(deck: $0) } ?? []
        }()
        let dueTomorrow = deckCards.filter { $0.state != .new && !$0.isSuspended && $0.due < tomorrowEnd }.count
        return VStack(spacing: 0) {
            // 1.8：学完盖一枚“日课已毕”
            SealStamp(text: "日课已毕", size: 20)
                .padding(.bottom, 4)
            Text(study.notebookId != nil ? "这本笔记本的卡片今天学完了" : "这个牌组今天学完了")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(ReviewPalette.ink)
                .padding(.top, 12)
            Text(study.deck ?? "")
                .font(.system(size: 13))
                .foregroundStyle(ReviewPalette.sub)
                .padding(.top, 6)
                .padding(.bottom, 24)
            HStack(spacing: 0) {
                summaryStat("\(answers.total)", unit: "次", label: "今日复习（全部牌组）")
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                summaryStat(accuracy, unit: answers.total == 0 ? "" : "%", label: "答对率（非“重来”）")
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                summaryStat("\(dueTomorrow)", unit: "张", label: "明天到期", accent: true)
            }
            .frame(height: 100)
            .overlay(alignment: .top) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
            Text("学习中的卡片到时间会再出现；新卡与复习数量受每日上限约束。")
                .font(.system(size: 12.5))
                .foregroundStyle(ReviewPalette.sub)
                .padding(.top, 18)
            Text("温故而知新，可以为师矣。——《论语·为政》")
                .font(.custom("Kaiti SC", size: 13))
                .foregroundStyle(ReviewPalette.sub.opacity(0.9))
                .padding(.top, 10)
            HStack(spacing: 8) {
                PillButton(icon: "chevron.left", title: "返回牌组", style: .primary) {
                    study.deck = nil
                    study.notebookId = nil
                    study.finished = false
                }
                PillButton(icon: "arrow.clockwise", title: "再查一次") { store.nextCard() }
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(width: 600)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ReviewPalette.hair))
        .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.08), radius: 20, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryStat(_ number: String, unit: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number)
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ? ReviewPalette.accent : ReviewPalette.ink)
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
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

    private func fieldBinding(_ i: Int) -> Binding<String> {
        Binding(get: {
            guard let f = store.cardEditor?.card.fields, i < f.count else { return "" }
            return f[i]
        }, set: { v in
            guard var f = store.cardEditor?.card.fields, i < f.count else { return }
            f[i] = v
            store.cardEditor?.card.fields = f
        })
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
            // 1.2：所见即所得编辑（去掉右侧预览）；背面可加多个自定义栏目
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let c = draft?.card, let type = c.noteType, !c.fields.isEmpty {
                        // 多字段卡片：逐个字段编辑，正反面由“卡片模板”决定
                        let names = store.noteTemplates[type]?.fieldNames ?? []
                        Text("笔记类型：\(type)（正反面怎么排由“记忆卡 → 卡片模板”决定）")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(c.fields.indices), id: \.self) { i in
                            Text(i < names.count ? names[i] : "字段\(i + 1)").font(.headline)
                            RichEditor(text: fieldBinding(i), mode: .card, toolbar: true, autoHeight: false, minHeight: 160,
                                       slot: "card-field-\(i)", onSubmit: submit, onCancel: cancel)
                                .frame(height: 180)
                                .richEditorFrame()
                        }
                    } else {
                        Text("正面").font(.headline)
                        RichEditor(text: binding(\.card.front, ""), mode: .card, placeholder: "问题、字词或章句",
                                   autoHeight: false, minHeight: 180, focus: draft?.isNew == true, slot: "card-front",
                                   onSubmit: submit, onCancel: cancel)
                            .frame(height: 220)
                            .richEditorFrame()
                        Text("背面").font(.headline).padding(.top, 6)
                        RichEditor(text: binding(\.card.back, ""), mode: .card, placeholder: "答案",
                                   autoHeight: false, minHeight: 180, slot: "card-back",
                                   onSubmit: submit, onCancel: cancel)
                            .frame(height: 220)
                            .richEditorFrame()
                        sectionsEditor
                    }
                }
                .padding(.trailing, 6)
            }
            if let error = draft?.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("所见即所得：⌘B 粗体、⌘I 斜体、⌘K 链接、⌘1/⌘2 标题、⇧⌘8 列表；也可直接敲 Markdown。从网页、Word、Anki 粘贴时保留格式。⌘↩ 保存。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let c = draft?.card, c.id != nil {
                    Text(c.state == .new ? "新卡" : "已复习 \(c.reps) 次，遗忘 \(c.lapses) 次，间隔 \(Int(c.interval)) 天"
                         + (c.stability.map { "，FSRS 稳定性 \(String(format: "%.1f", $0)) 天" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if c.highlightId != nil {
                        Button("原摘录…") {
                            store.cardEditor = nil
                            store.openHighlight(of: c)
                        }
                        .controlSize(.small)
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { store.cardEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { store.commitCardEditor() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled((draft?.card.fields.first ?? draft?.card.front ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 600, idealHeight: 720)
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
                        .buttonStyle(.borderless).help("删除这个栏目")
                }
                RichEditor(text: sectionBinding(sec.id, \.text, ""), mode: .card, placeholder: "栏目内容",
                           toolbar: true, autoHeight: false, minHeight: 130, slot: "card-section-" + sec.id,
                           onSubmit: submit, onCancel: cancel)
                    .frame(height: 160)
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
        Binding(get: {
            store.cardEditor?.card.sections?.first(where: { $0.id == id })?[keyPath: kp] ?? fallback
        }, set: { v in
            guard var secs = store.cardEditor?.card.sections, let i = secs.firstIndex(where: { $0.id == id }) else { return }
            secs[i][keyPath: kp] = v
            store.cardEditor?.card.sections = secs
        })
    }

    private func addSection(_ name: String) {
        var secs = store.cardEditor?.card.sections ?? []
        secs.append(CardSection(name: name))
        store.cardEditor?.card.sections = secs
    }

    private func removeSection(_ id: String) {
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
        let c = store.cardEditor?.card
        let first = (c?.fields.first ?? c?.front ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { NSSound.beep(); return }
        store.commitCardEditor()
    }

    private func cancel() { store.cardEditor = nil }
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
