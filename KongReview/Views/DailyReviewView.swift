import SwiftUI
import AppKit
import KongReviewCore

/// 每日回顾：一次一张卡片。同一天内重开应用会回到同一组、同一位置；跨日自动换新。
///
/// 快捷键：下一条 空格 / → / J；上一条 ← / K；写按语 N；做成记忆卡 M；收藏 F；弃置 Delete；
/// 编辑 E（1.2 起在卡片上就地编辑，⌥E 打开编辑面板）。
/// 写按语、就地编辑时单键快捷键全部停用，以免打字被当成命令。
struct DailyReviewView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(SettingsKeys.dailyCount) private var dailyCount = 10

    private var state: ReviewState { store.review }

    /// 记忆卡已独立成“记忆卡”页（仿 Anki），回顾里不再混入
    private var scheduler: ReviewScheduler {
        ReviewScheduler(config: .init(dailyCount: dailyCount, masteryLimit: 0))
    }

    /// 正在写按语或就地编辑：单键快捷键停用
    private var editingNote: Bool { state.noteDraft != nil || state.inlineDraft != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if state.cards.isEmpty && state.theme == nil && store.todayReviewIsComplete {
                finished
            } else if state.cards.isEmpty {
                ContentUnavailableView(
                    "暂无可回顾的摘录",
                    systemImage: "sun.max",
                    description: Text("先录入几条摘录，明天这里就会出现它们。")
                )
            } else if state.position >= state.cards.count {
                finished
            } else {
                let card = state.cards[state.position]
                ScrollView {
                    VStack(spacing: 18) {
                        if let d = store.currentWeeklyDigest() {
                            WeeklyDigestCard(digest: d)
                        }
                        reviewCard(card)
                        noteEditor(for: card)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                controls(for: card)
                    .padding(.top, 4)
                    .padding(.bottom, 22)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(scopeTitle)
        .task(id: (state.theme ?? "") + "|" + store.today + "|\(state.sessionToken)") { loadSession(forceNew: false) }
        .onChange(of: store.revision) { refreshCards() }
        .onChange(of: state.position) { persist() }
    }

    // MARK: 子视图

    /// 顶部细条：范围、进度、连续天数、待学卡片、全部统计（不抢正文的视线）
    private var topBar: some View {
        let _ = store.revision
        let _ = store.today
        let due = store.dueCardCount()
        return VStack(spacing: 0) {
            // 1.3：窄窗口时不再挤掉左右两端——范围改成自绘的胶囊菜单，右侧按宽度逐级收起
            HStack(spacing: 16) {
                scopeMenu
                if !state.cards.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(min(state.position, state.cards.count)), total: Double(state.cards.count))
                            .tint(ReviewPalette.accent)
                            .frame(width: 80)
                        Text("\(min(state.position + 1, state.cards.count)) / \(state.cards.count)")
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(ReviewPalette.sub)
                            .fixedSize()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        streakChip
                        cardsChip(due, label: "记忆卡待学")
                        Spacer(minLength: 8)
                        statsLink(full: true)
                    }
                    HStack(spacing: 12) {
                        streakChip
                        cardsChip(due, label: "待学")
                        Spacer(minLength: 6)
                        statsLink(full: false)
                    }
                    HStack(spacing: 10) {
                        cardsChip(due, label: "待学")
                        Spacer(minLength: 4)
                        statsLink(full: false)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            Rectangle().fill(ReviewPalette.hair).frame(height: 1)
        }
    }

    /// 回顾范围：全部摘录或某个标签（主题回顾）
    private var scopeMenu: some View {
        let theme = state.theme
        return Menu {
            Button { store.review.theme = nil } label: {
                if theme == nil { Label("全部摘录", systemImage: "checkmark") } else { Text("全部摘录") }
            }
            Button { store.review.theme = ReviewScope.stale } label: {
                if theme == ReviewScope.stale { Label("久未回顾的摘录", systemImage: "checkmark") } else { Text("久未回顾的摘录") }
            }
            if !store.notebooks.isEmpty {
                Divider()
                Section("专题回顾（按笔记本，按笔记本中的顺序全部过一遍）") {
                    ForEach(store.notebooks) { n in
                        if let id = n.id {
                            let t = ReviewScope.notebook(id)
                            Button { store.review.theme = t } label: {
                                if theme == t { Label("《\(n.title)》", systemImage: "checkmark") } else { Text("《\(n.title)》") }
                            }
                        }
                    }
                }
            }
            if let label = store.sourceScopeLabel(theme) ?? store.chapterScopeLabel(theme), let t = theme {
                Divider()
                Section(ReviewScope.chapterScope(theme) != nil ? "按篇回顾（按页码顺序）" : "按书回顾（按页码顺序）") {
                    Button { store.review.theme = t } label: { Label(label, systemImage: "checkmark") }
                }
            }
            if !store.tags.isEmpty {
                Divider()
                Section("主题回顾（按标签）") {
                    ForEach(store.tags, id: \.self) { t in
                        Button { store.review.theme = t } label: {
                            if theme == t { Label("#\(t)", systemImage: "checkmark") } else { Text("#\(t)") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: theme == nil ? "tray.full"
                      : (theme == ReviewScope.stale ? "clock.arrow.circlepath"
                         : (ReviewScope.notebookID(theme) != nil ? "text.book.closed"
                            : (ReviewScope.sourceScope(theme) != nil || ReviewScope.chapterScope(theme) != nil ? "book" : "number"))))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ReviewPalette.accent)
                Text(scopeLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ReviewPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(ReviewPalette.sub)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(ReviewPalette.card))
            .overlay(Capsule().stroke(ReviewPalette.hair))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .handCursor()
        .help("回顾范围：全部摘录、某本专题笔记本（按顺序全部过一遍），或某个标签（主题回顾）")
    }

    /// 范围的显示名
    private var scopeLabel: String {
        guard let t = state.theme else { return "全部摘录" }
        if t == ReviewScope.stale { return "久未回顾" }
        if let nid = ReviewScope.notebookID(t) {
            return store.notebooks.first { $0.id == nid }.map { "《\($0.title)》" } ?? "专题笔记本"
        }
        if let label = store.sourceScopeLabel(t) ?? store.chapterScopeLabel(t) { return label }
        return t
    }

    private var scopeTitle: String {
        guard let t = state.theme else { return "今日回顾" }
        if t == ReviewScope.stale { return "今日回顾 · 久未回顾的摘录" }
        if ReviewScope.notebookID(t) != nil { return "专题回顾 · " + scopeLabel }
        if ReviewScope.sourceScope(t) != nil { return "按书回顾 · " + scopeLabel }
        if ReviewScope.chapterScope(t) != nil { return "按篇回顾 · " + scopeLabel }
        return "主题回顾 · #\(t)"
    }

    private var streakChip: some View {
        StatChip(icon: "flame.fill", iconColor: ReviewPalette.hard, label: "连续", value: "\(store.stats.currentStreak) 天")
            .fixedSize()
    }

    private func cardsChip(_ due: Int, label: String) -> some View {
        Button { store.selection = .cards } label: {
            StatChip(icon: "brain", iconColor: ReviewPalette.accent, label: label, value: "\(due)")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .handCursor()
        .help("打开记忆卡")
    }

    @ViewBuilder
    private func statsLink(full: Bool) -> some View {
        Button { store.selection = .stats } label: {
            if full {
                Text("全部统计 ›").font(.system(size: 12.5))
            } else {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 13))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReviewPalette.accent)
        .fixedSize()
        .handCursor()
        .help("全部统计")
    }

    @ViewBuilder
    private func noteEditor(for card: ReviewCard) -> some View {
        if state.noteDraft != nil {
            ReviewCardContainer(padding: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("按语").font(.caption).foregroundStyle(.secondary)
                RichEditor(text: Binding(get: { state.noteDraft ?? "" }, set: { state.noteDraft = $0 }),
                           font: .note, placeholder: "写下按语…", autoHeight: false, minHeight: 160, focus: true,
                           slot: "review-note-draft",
                           onSubmit: { saveNote(for: card) }, onCancel: { state.noteDraft = nil })
                    .frame(height: 180)
                    .richEditorFrame()
                HStack {
                    Spacer()
                    Button("取消") { state.noteDraft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("保存按语") { saveNote(for: card) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .handCursor()
                }
            }
            }
        }
    }

    /// 与首页共用截图中的日课卡；回顾结束后保留从头再看、再抽一组等操作。
    private var finished: some View {
        let due = store.dueCardCount()
        return ScrollView {
            DailyReviewSummaryCard(title: "今日回顾完成", quoteOverride: state.theme == nil ? nil : todaysQuote()) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { finishedActions(due: due) }
                    VStack(spacing: 12) { finishedActions(due: due) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func finishedActions(due: Int) -> some View {
        if !state.cards.isEmpty {
            PillButton(icon: "chevron.left", title: "上一条", key: "←", style: .ghost) { go(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
        }
        if due > 0 {
            PillButton(icon: "brain", title: "去学习记忆卡 · \(due)", style: .primary) { store.startSuggestedStudy() }
        }
        if !state.cards.isEmpty {
            PillButton(title: "从头再看") { state.position = 0; persist() }
        }
        PillButton(title: "再抽一组", style: due > 0 ? .normal : .primary) { loadSession(forceNew: true) }
    }

    /// 今日一句：今天这组里收藏的那条；没有收藏就按日期固定取一条（同一天总是同一句）
    private func todaysQuote() -> (text: String, source: String)? {
        guard !state.cards.isEmpty else { return nil }
        let pick = state.cards.first { $0.highlight.isFavorite }
            ?? state.cards[store.today.unicodeScalars.reduce(0) { $0 + Int($1.value) } % state.cards.count]
        let plain = Markdown.plainText(fromHTML: Markdown.richHTML(pick.highlight.text))
            .replacingOccurrences(of: "\n", with: " ")
        let text = plain.count > 120 ? String(plain.prefix(118)) + "…" : plain
        let src = store.source(for: pick.highlight)
        let source = [src?.author ?? "", src.map { "《\($0.title)》" } ?? ""].filter { !$0.isEmpty }.joined()
        return (text, source)
    }

    /// 写按语时返回 nil，让单键快捷键失效
    private func key(_ k: KeyEquivalent) -> KeyboardShortcut? {
        editingNote ? nil : KeyboardShortcut(k, modifiers: [])
    }

    /// 回顾卡片：出处头（封面、书名、作者，右侧写按语与展开详情）→ 正文 → 译文、按语 → 折叠的出处详情 → 右下角图标
    private func reviewCard(_ card: ReviewCard) -> some View {
        let h = card.highlight
        let source = store.source(for: h)
        let hasCard = store.cardHighlightIDs.contains(card.id)
        return ReviewCardContainer(padding: 34) {
            HStack(alignment: .center, spacing: 14) {
                SourceThumb(source: source)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source?.title ?? "未归类")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ReviewPalette.ink)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        let byline = [source?.author ?? "", h.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !byline.isEmpty {
                            Text(byline).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                        }
                        if hasCard {
                            Label("记忆卡", systemImage: "brain")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .foregroundStyle(ReviewPalette.accent)
                                .background(ReviewPalette.accentSoft, in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 12)
                CardIconButton(icon: h.note == nil ? "text.bubble" : "text.bubble.fill",
                               help: h.note == nil ? "写按语（N）" : "改按语（N）") {
                    state.noteDraft = h.note ?? ""
                }
                CardIconButton(icon: state.showDetails ? "chevron.up" : "chevron.down",
                               help: state.showDetails ? "收起出处详情" : "展开出处详情（完整引文、位置、标签）") {
                    state.showDetails.toggle()
                }
            }
            .padding(.bottom, 24)

            if let d = state.inlineDraft, d.id == h.id {
                inlineEditor(card)
            } else {
            // 正文与译文、按语（网页渲染：Markdown 标题、列表、图片都按真实样式显示）
            RichWebText(text: h.text, style: .highlight, slot: "review-text")
            if let t = h.translation {
                RichWebText(text: t, style: .translation, slot: "review-translation")
                    .padding(.top, 16)
            }
            if let n = h.note {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.7)).frame(width: 3)
                    RichWebText(text: n, style: .note, slot: "review-note")
                }
                .padding(.top, 18)
            }
            }

            if state.showDetails {
                VStack(alignment: .leading, spacing: 6) {
                    let cite = CitationFormatter.citation(for: h, source: source, style: CitationSettings.style)
                    if !cite.isEmpty {
                        Text(cite).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !h.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(h.tags, id: \.self) { t in
                                Text("#\(t)").font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    Text("回顾过 \(h.surfacedCount) 次").font(.caption).foregroundStyle(ReviewPalette.sub)
                }
                .padding(.top, 20)
            }

            relatedSection(h)
            Rectangle().fill(ReviewPalette.hair).frame(height: 1).padding(.top, 22)
            HStack(spacing: 14) {
                Text("添加于 \(h.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub.opacity(0.8))
                Spacer()
                CardIconButton(icon: h.isFavorite ? "heart.fill" : "heart", help: "收藏（F）", active: h.isFavorite) {
                    act(.favorite, card)
                }
                CardIconButton(icon: "square.and.pencil", help: "就地编辑（E）；按住 ⌥ 点击打开编辑面板") {
                    if NSEvent.modifierFlags.contains(.option) { store.edit(h) } else { startInlineEdit(h) }
                }
                CardIconButton(icon: hasCard ? "brain.fill" : "brain", help: hasCard ? "已做成记忆卡" : "做成记忆卡（M）") {
                    if !hasCard { makeCard(card) }
                }
                CardIconButton(icon: "rectangle.dashed", help: "做成填空卡（C）") { store.startCloze(for: h) }
                Menu {
                    Button((h.frequency ?? 0) > 0 ? "✓ 多出现" : "多出现") { store.setFrequency(1, for: h) }
                    Button((h.frequency ?? 0) == 0 ? "✓ 正常" : "正常") { store.setFrequency(nil, for: h) }
                    Button((h.frequency ?? 0) < 0 ? "✓ 少出现" : "少出现") { store.setFrequency(-1, for: h) }
                    Divider()
                    Button("不再出现（弃置）") { act(.discard, card) }
                } label: {
                    Image(systemName: (h.frequency ?? 0) > 0 ? "dial.high" : ((h.frequency ?? 0) < 0 ? "dial.low" : "dial.medium"))
                        .font(.system(size: 14))
                        .foregroundStyle((h.frequency ?? 0) == 0 ? ReviewPalette.sub : ReviewPalette.accent)
                }
                .menuStyle(.borderlessButton)
                .handCursor()
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28, height: 26)
                .help("这条摘录以后出现得多一些还是少一些")
                Menu {
                    Button("复制文字（含出处）") { copy(h, source: source) }
                    Button("生成分享图…") { store.shareImageHighlight = h }
                    if let id = h.id {
                        Divider()
                        AddToNotebookMenu(ids: [id])
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14)).foregroundStyle(ReviewPalette.sub)
                }
                .menuStyle(.borderlessButton)
                .handCursor()
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28, height: 26)
                .help("复制或生成分享图")
            }
            .padding(.top, 12)
        }
    }

    /// 相关摘录：默认折叠，展开后列出用词相近、同标签、同出处的几条
    @ViewBuilder
    private func relatedSection(_ h: Highlight) -> some View {
        let items = state.showRelated ? store.related(to: h) : []
        VStack(alignment: .leading, spacing: 8) {
            Button {
                state.showRelated.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.showRelated ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("相关摘录").font(.system(size: 12.5, weight: .medium))
                    if store.relatedIndex == nil { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(ReviewPalette.sub)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("用词相近、同标签或同出处的其他摘录（R）")
            if state.showRelated {
                if items.isEmpty {
                    Text(store.relatedIndex == nil ? "正在建立索引…" : "没有找到相关的摘录。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                }
                ForEach(items) { item in
                    Button { store.edit(item.highlight) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MarkdownText.attributed(item.highlight.text))
                                .font(.system(size: 13.5, design: .serif))
                                .foregroundStyle(ReviewPalette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(store.source(for: item.highlight).map { "《\($0.title)》" } ?? "未归类")
                                    .lineLimit(1)
                                ForEach(item.hit.sharedTags, id: \.self) { t in Text("#\(t)").foregroundStyle(ReviewPalette.accent) }
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(ReviewPalette.sub)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("打开这条摘录")
                }
            }
        }
        .padding(.top, 22)
    }

    /// 卡片下方的操作条：上一条 ｜ 弃置 · 按语 · 记忆卡 ｜ 保留（主操作）
    @ViewBuilder
    private func controls(for card: ReviewCard) -> some View {
        let hasCard = store.cardHighlightIDs.contains(card.id)
        HStack(spacing: 8) {
            PillButton(icon: "chevron.left", title: "上一条", key: "←", style: .ghost, disabled: state.position == 0) { go(-1) }
                .keyboardShortcut(key(.leftArrow))
            BarSeparator()
            PillButton(icon: "xmark", title: "弃置", key: "⌫") { act(.discard, card) }
                .keyboardShortcut(key(.delete))
                .help("以后不再出现（可在列表中恢复）")
            PillButton(icon: "text.bubble", title: "按语", key: "N", disabled: editingNote) { state.inlineDraft = nil; state.noteDraft = card.highlight.note ?? "" }
                .keyboardShortcut(key("n"))
            PillButton(icon: "brain", title: hasCard ? "已是记忆卡" : "记忆卡", key: "M", disabled: hasCard) { makeCard(card) }
                .keyboardShortcut(key("m"))
            BarSeparator()
            PillButton(icon: "checkmark", title: "保留", key: "空格", style: .primary) { act(.keep, card) }
                .keyboardShortcut(key(.space))
                .help("保留并看下一条（空格、→ 或 J）")
        }
        .frame(maxWidth: .infinity)
        .background {
            // 其余快捷键：→ / J 下一条，K 上一条，F 收藏，E 编辑
            Group {
                Button("") { act(.keep, card) }.keyboardShortcut(key(.rightArrow))
                Button("") { act(.keep, card) }.keyboardShortcut(key("j"))
                Button("") { go(-1) }.keyboardShortcut(key("k"))
                Button("") { act(.favorite, card) }.keyboardShortcut(key("f"))
                Button("") { startInlineEdit(card.highlight) }.keyboardShortcut(key("e"))
                Button("") { store.edit(card.highlight) }
                    .keyboardShortcut(editingNote ? nil : KeyboardShortcut("e", modifiers: .option))
                Button("") { store.startCloze(for: card.highlight) }.keyboardShortcut(key("c"))
                Button("") { state.showRelated.toggle() }.keyboardShortcut(key("r"))
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func makeCard(_ card: ReviewCard) {
        store.makeCard(from: card.highlight)
        store.logReview(.toCard, highlightId: card.highlight.id)
        update(scheduler.apply(.keep, to: card.highlight))
    }

    private func shareText(_ h: Highlight, source: Source?) -> String {
        let cite = CitationFormatter.citation(for: h, source: source, style: CitationSettings.style)
        return cite.isEmpty ? h.text : h.text + "\n——" + cite
    }

    private func copy(_ h: Highlight, source: Source?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareText(h, source: source), forType: .string)
    }

    // MARK: 逻辑

    private func act(_ action: ReviewScheduler.Action, _ card: ReviewCard) {
        let kind: ReviewEvent.Kind
        switch action {
        case .keep: kind = .keep
        case .favorite: kind = .favorite
        case .discard: kind = .discard
        }
        store.logReview(kind, highlightId: card.highlight.id)
        let name: String
        switch action {
        case .keep: name = "保留"
        case .favorite: name = card.highlight.isFavorite ? "取消收藏" : "收藏"
        case .discard: name = "弃置"
        }
        // 可撤销（⌘Z）：摘录恢复原状，回到这一条
        store.undoable(name, highlights: card.highlight.id.map { [$0] } ?? [], reviewPosition: state.position) {
            update(scheduler.apply(action, to: card.highlight))
        }
    }

    private func saveNote(for card: ReviewCard) {
        guard let draft = state.noteDraft else { return }
        var h = card.highlight
        h.note = draft.nilIfBlank
        store.save(h)
        store.logReview(.note, highlightId: h.id)
        state.noteDraft = nil
    }

    /// 1.2：就地编辑——原文、译文、按语直接在卡片上改
    private func startInlineEdit(_ h: Highlight) {
        state.noteDraft = nil
        state.inlineDraft = InlineEditDraft(id: h.id, text: h.text, translation: h.translation ?? "", note: h.note ?? "")
    }

    private func saveInline(_ card: ReviewCard) {
        guard let d = state.inlineDraft else { return }
        guard d.id == card.highlight.id else { state.inlineDraft = nil; return }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        var h = card.highlight
        let changed = h.text != text || (h.translation ?? "") != d.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            || (h.note ?? "") != d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        state.inlineDraft = nil
        guard changed else { return }
        h.text = text
        h.translation = d.translation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        h.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        h.updatedAt = Date()
        store.saveEdited(h)
    }

    @ViewBuilder
    private func inlineEditor(_ card: ReviewCard) -> some View {
        let h = card.highlight
        VStack(alignment: .leading, spacing: 8) {
            Text("原文").font(.caption).foregroundStyle(ReviewPalette.sub)
            RichEditor(text: Binding(get: { state.inlineDraft?.text ?? "" }, set: { state.inlineDraft?.text = $0 }),
                       font: .highlight, placeholder: "摘录原文", autoHeight: false, minHeight: 220, focus: true,
                       slot: "inline-text", onSubmit: { saveInline(card) }, onCancel: { state.inlineDraft = nil })
                .frame(height: 260)
                .richEditorFrame()
            Text("译文 / 白话").font(.caption).foregroundStyle(ReviewPalette.sub).padding(.top, 6)
            RichEditor(text: Binding(get: { state.inlineDraft?.translation ?? "" }, set: { state.inlineDraft?.translation = $0 }),
                       placeholder: "（可选）", toolbar: true, autoHeight: false, minHeight: 130,
                       slot: "inline-translation", onSubmit: { saveInline(card) }, onCancel: { state.inlineDraft = nil })
                .frame(height: 150)
                .richEditorFrame()
            Text("按语").font(.caption).foregroundStyle(ReviewPalette.sub).padding(.top, 6)
            RichEditor(text: Binding(get: { state.inlineDraft?.note ?? "" }, set: { state.inlineDraft?.note = $0 }),
                       font: .note, placeholder: "（可选）", autoHeight: false, minHeight: 130,
                       slot: "inline-note", onSubmit: { saveInline(card) }, onCancel: { state.inlineDraft = nil })
                .frame(height: 150)
                .richEditorFrame()
            HStack {
                Button("在编辑面板中打开（出处、位置、标签）…") {
                    state.inlineDraft = nil
                    store.edit(h)
                }
                .buttonStyle(.link)
                .handCursor()
                .font(.system(size: 12))
                Spacer()
                Button("取消") { state.inlineDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveInline(card) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
            }
            .padding(.top, 6)
        }
    }

    private func update(_ highlight: Highlight) {
        store.save(highlight)
        go(1)
    }

    private func go(_ delta: Int) {
        state.noteDraft = nil
        state.inlineDraft = nil
        state.position = max(0, min(state.cards.count, state.position + delta))
        persist()
    }

    private func loadSession(forceNew: Bool) {
        let today = ReviewSessionRecord.dayString(Date())
        let key = ReviewSessionRecord.key(theme: state.theme)
        state.noteDraft = nil
        state.inlineDraft = nil
        do {
            // 专题回顾：笔记本里的摘录有增删或换序时不沿用当天的进度
            // 1.7：按书回顾同理——书里的摘录（按页码）有变化时重新开始
            let bookScope = ReviewScope.sourceScope(state.theme)
            // 2.0：按篇回顾同理
            let chapterScope = ReviewScope.chapterScope(state.theme)
            let bookHighlights = try bookScope.map { try store.db.sourceHighlights($0.id, pages: $0.pages) }
                ?? chapterScope.map { try store.db.sourceChapterHighlights($0.id, chapter: $0.chapter) }
            let notebookIDs = try ReviewScope.notebookID(state.theme).map { try store.db.notebookHighlights($0).compactMap(\.id) }
                ?? bookHighlights?.compactMap(\.id)
            if !forceNew,
               let saved = ReviewSessionRecord.load(key: key),
               saved.day == today,
               notebookIDs == nil || notebookIDs == saved.regularIds {
                let ids = saved.regularIds + saved.masteryIds
                let found = try store.db.highlights(ids: ids)
                let byID = Dictionary(found.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
                state.cards = ids.compactMap { byID[$0] }.map { ReviewCard(highlight: $0, isMastery: false) }
                // 已看前缀里有摘录被删除时，进度随存活条目重新映射，不能跳过下一条。
                state.position = saved.resumePosition(existingIDs: Set(byID.keys))
                state.day = today
                return
            }

            // 1.4：按专题笔记本回顾——笔记本里的全部摘录，按笔记本中的顺序
            if let nid = ReviewScope.notebookID(state.theme) {
                state.cards = try store.db.notebookHighlights(nid).map { ReviewCard(highlight: $0, isMastery: false) }
                state.position = 0
                state.day = today
                persist()
                return
            }
            // 1.7：按书回顾——这本书（或其中一段）的全部摘录，按页码
            if let bookHighlights {
                state.cards = bookHighlights.map { ReviewCard(highlight: $0, isMastery: false) }
                state.position = 0
                state.day = today
                persist()
                return
            }
            let highlights: [Highlight]
            let weights: [Int64: Double]
            if state.theme == ReviewScope.stale {
                // 1.5：久未回顾——只从从未出现或半年以上没出现的摘录里抽
                highlights = try store.db.staleHighlights()
                weights = try store.db.sourceWeights()
            } else {
                (highlights, weights) = try store.db.reviewCandidates(tag: state.theme)
            }
            let session: ReviewScheduler.Session
            if forceNew {
                session = scheduler.makeSession(highlights: highlights, sourceWeights: weights)
            } else {
                // 以日期为种子：同一天抽到的是同一组
                var rng = SeededGenerator.forDay(Date())
                session = scheduler.makeSession(highlights: highlights, sourceWeights: weights, using: &rng)
            }
            state.cards = session.all.map { ReviewCard(highlight: $0, isMastery: false) }
            state.position = 0
            state.day = today
            persist()
        } catch {
            store.report(error)
        }
    }

    /// 编辑或其他写入后，用数据库中的最新内容刷新卡片（顺序不变）
    private func refreshCards() {
        let ids = state.cards.compactMap(\.highlight.id)
        guard !ids.isEmpty, let fresh = try? store.db.highlights(ids: ids) else { return }
        let byId = Dictionary(uniqueKeysWithValues: fresh.compactMap { h in h.id.map { ($0, h) } })
        state.cards = state.cards.map { card in
            var c = card
            if let id = card.highlight.id, let h = byId[id] { c.highlight = h }
            return c
        }
    }

    private func persist() {
        ReviewSessionRecord(
            day: state.day.isEmpty ? ReviewSessionRecord.dayString(Date()) : state.day,
            regularIds: state.cards.compactMap(\.highlight.id),
            masteryIds: [],
            position: state.position
        ).save(key: ReviewSessionRecord.key(theme: state.theme))
        StatusItemController.shared.updateCounts()
    }
}

/// 摘录、译文、按语的 Markdown 显示（块级语法逐行处理，见 KongReviewCore/MarkdownText.swift）
enum RichText {
    static func attributed(_ s: String) -> AttributedString {
        MarkdownText.attributed(s)
    }

    /// 同上，并把搜索词标成黄底（列表里的搜索结果）
    static func marked(_ s: String, terms: [String]) -> AttributedString {
        var a = attributed(s)
        guard !terms.isEmpty else { return a }
        // 先按字符位置记下所有命中，再统一上色（改属性后旧的索引可能失效）
        var spans: [(Int, Int)] = []
        let plain = String(a.characters)
        for r in SearchTerms.ranges(of: terms, in: plain) {
            spans.append((plain.distance(from: plain.startIndex, to: r.lowerBound), plain.distance(from: r.lowerBound, to: r.upperBound)))
        }
        for (off, len) in spans {
            let lo = a.index(a.startIndex, offsetByCharacters: off)
            let hi = a.index(lo, offsetByCharacters: len)
            a[lo..<hi].backgroundColor = Color.yellow.opacity(0.38)
        }
        return a
    }
}

/// 当日回顾的持久化（UserDefaults，体积很小）
struct ReviewSessionRecord: Codable {
    var day: String
    var regularIds: [Int64]
    var masteryIds: [Int64]
    var position: Int

    func resumePosition(existingIDs: Set<Int64>) -> Int {
        let ids = regularIds + masteryIds
        return ids.prefix(min(ids.count, max(0, position))).filter { existingIDs.contains($0) }.count
    }

    static func key(theme: String?) -> String {
        "review.session." + (theme ?? "_all")
    }

    static func dayString(_ date: Date) -> String {
        ReminderPlan.dayKey(date)
    }

    static func load(key: String) -> ReviewSessionRecord? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReviewSessionRecord.self, from: data)
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
