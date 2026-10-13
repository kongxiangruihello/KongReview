import SwiftUI
import AppKit
import KongReviewCore

/// 每日回顾：一次一张卡片。同一天内重开应用会回到同一组、同一位置；跨日自动换新。
///
/// 快捷键：下一条 空格 / → / J；上一条 ← / K；写按语 N；做成记忆卡 M；收藏 F；弃置 Delete；编辑 E。
/// 写按语时单键快捷键全部停用，以免打字被当成命令。
struct DailyReviewView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(SettingsKeys.dailyCount) private var dailyCount = 10

    private var state: ReviewState { store.review }

    /// 记忆卡已独立成“记忆卡”页（仿 Anki），回顾里不再混入
    private var scheduler: ReviewScheduler {
        ReviewScheduler(config: .init(dailyCount: dailyCount, masteryLimit: 0))
    }

    private var editingNote: Bool { state.noteDraft != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            cardsBanner
            if state.cards.isEmpty {
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
                    .padding(.top, 6)
                    .padding(.bottom, 18)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(state.theme.map { "主题回顾 · #\($0)" } ?? "今日回顾")
        .task(id: (state.theme ?? "") + "|" + store.today) { loadSession(forceNew: false) }
        .onChange(of: store.revision) { refreshCards() }
    }

    // MARK: 子视图

    private var header: some View {
        HStack {
            Picker("范围", selection: Bindable(store.review).theme) {
                Text("全部").tag(String?.none)
                ForEach(store.tags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
            }
            .frame(maxWidth: 220)
            Spacer()
            if !state.cards.isEmpty {
                ProgressView(value: Double(min(state.position, state.cards.count)), total: Double(state.cards.count))
                    .frame(width: 160)
                Text("\(min(state.position + 1, state.cards.count)) / \(state.cards.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// 首页顶部的统计条：今日回顾、连续天数、近 7 天、记忆卡待学；点“全部统计”进统计页
    private var cardsBanner: some View {
        let _ = store.revision
        let _ = store.today
        let s = ReviewStats.summarize((try? store.db.events()) ?? [], now: Date(), days: 7)
        let due = store.dueCardCount()
        let week = s.lastDays
        let peak = max(1, week.map(\.total).max() ?? 1)
        return VStack(spacing: 0) {
            HStack(spacing: 18) {
                statItem("今日回顾", "\(s.today.highlights) 条", s.today.cards > 0 ? "记忆卡 \(s.today.cards) 次" : nil,
                         icon: s.today.total > 0 ? "checkmark.circle.fill" : "sun.max",
                         color: s.today.total > 0 ? .green : .orange)
                statItem("连续回顾", "\(s.currentStreak) 天", "最长 \(s.longestStreak) 天", icon: "flame", color: .red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("近 7 天").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(week.enumerated()), id: \.offset) { idx, d in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(idx == week.count - 1 ? Color.accentColor : Color.accentColor.opacity(0.45))
                                .frame(width: 8, height: max(2, 22 * CGFloat(d.total) / CGFloat(peak)))
                                .help("\(d.key)：摘录 \(d.highlights) 条，记忆卡 \(d.cards) 次")
                        }
                    }
                    .frame(height: 22, alignment: .bottom)
                }
                Button {
                    store.selection = .cards
                } label: {
                    statItem("记忆卡待学", "\(due) 张", due > 0 ? "去学习 ›" : "今天学完了",
                             icon: "brain", color: .purple)
                }
                .buttonStyle(.plain)
                .help("打开记忆卡")
                Spacer()
                Button("全部统计 ›") { store.selection = .stats }
                    .buttonStyle(.link)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            Divider()
        }
    }

    private func statItem(_ title: String, _ value: String, _ detail: String?, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(.headline).monospacedDigit()
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder
    private func noteEditor(for card: ReviewCard) -> some View {
        if state.noteDraft != nil {
            ReviewCardContainer(padding: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("按语（支持 Markdown）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { state.noteDraft ?? "" }, set: { state.noteDraft = $0 }))
                    .font(.system(size: 15))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                MarkdownPreview(text: state.noteDraft ?? "", font: .callout, slot: "preview-draft")
                HStack {
                    Spacer()
                    Button("取消") { state.noteDraft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("保存按语") { saveNote(for: card) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            }
            }
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal").font(.system(size: 48)).foregroundStyle(.tint)
            Text("今日回顾完成").font(.title2)
            Text("共 \(state.cards.count) 条").foregroundStyle(.secondary)
            HStack {
                Button("上一条") { go(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("从头再看一遍") { state.position = 0; persist() }
                Button("再抽一组") { loadSession(forceNew: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return ReviewCardContainer(padding: 36) {
            HStack(alignment: .top, spacing: 16) {
                SourceThumb(source: source)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source?.title ?? "未归类")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text([source?.author ?? "", h.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if hasCard {
                        Label("已做成记忆卡", systemImage: "brain").font(.caption).foregroundStyle(.purple)
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
            .padding(.bottom, 26)

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
                    Text("添加于 \(h.createdAt.formatted(date: .abbreviated, time: .omitted))，回顾过 \(h.surfacedCount) 次")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 20)
            }

            HStack(spacing: 28) {
                Spacer()
                CardIconButton(icon: h.isFavorite ? "heart.fill" : "heart", help: "收藏（F）", active: h.isFavorite) {
                    act(.favorite, card)
                }
                CardIconButton(icon: "square.and.pencil", help: "编辑摘录（E）") { store.edit(h) }
                CardIconButton(icon: hasCard ? "brain.fill" : "brain", help: hasCard ? "已做成记忆卡" : "做成记忆卡（M）") {
                    if !hasCard { makeCard(card) }
                }
                CardIconButton(icon: "doc.on.doc", help: "复制（含出处）") { copy(h, source: source) }
                ShareLink(item: shareText(h, source: source)) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 18))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .help("分享")
            }
            .padding(.top, 28)
        }
    }

    /// 卡片下方的一排圆形按钮（参照 Readwise：弃置 · 中间操作 · 保留）
    @ViewBuilder
    private func controls(for card: ReviewCard) -> some View {
        let hasCard = store.cardHighlightIDs.contains(card.id)
        HStack(alignment: .top, spacing: 44) {
            CircleActionButton(icon: "chevron.left", title: "上一条", hint: "← / K", kind: .plain, diameter: 44,
                               disabled: state.position == 0) { go(-1) }
                .keyboardShortcut(key(.leftArrow))
            CircleActionButton(icon: "xmark", title: "弃置", hint: "Delete", kind: .outline) { act(.discard, card) }
                .keyboardShortcut(key(.delete))
                .help("以后不再出现（可在列表中恢复）")
            CircleActionButton(icon: "text.bubble", title: "按语", hint: "N", kind: .plain, diameter: 52,
                               disabled: editingNote) { state.noteDraft = card.highlight.note ?? "" }
                .keyboardShortcut(key("n"))
            CircleActionButton(icon: "brain", title: hasCard ? "已是卡片" : "记忆卡", hint: "M", kind: .plain, diameter: 52,
                               disabled: hasCard) { makeCard(card) }
                .keyboardShortcut(key("m"))
            CircleActionButton(icon: "checkmark", title: "保留", hint: "空格 / → / J", kind: .filled) { act(.keep, card) }
                .keyboardShortcut(key(.space))
        }
        .frame(maxWidth: .infinity)
        .background {
            // 其余快捷键：→ / J 下一条，K 上一条，F 收藏，E 编辑
            Group {
                Button("") { act(.keep, card) }.keyboardShortcut(key(.rightArrow))
                Button("") { act(.keep, card) }.keyboardShortcut(key("j"))
                Button("") { go(-1) }.keyboardShortcut(key("k"))
                Button("") { act(.favorite, card) }.keyboardShortcut(key("f"))
                Button("") { store.edit(card.highlight) }.keyboardShortcut(key("e"))
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
        update(scheduler.apply(action, to: card.highlight))
    }

    private func saveNote(for card: ReviewCard) {
        guard let draft = state.noteDraft else { return }
        var h = card.highlight
        h.note = draft.nilIfBlank
        store.save(h)
        store.logReview(.note, highlightId: h.id)
        state.noteDraft = nil
    }

    private func update(_ highlight: Highlight) {
        store.save(highlight)
        go(1)
    }

    private func go(_ delta: Int) {
        state.noteDraft = nil
        state.position = max(0, min(state.cards.count, state.position + delta))
        persist()
    }

    private func loadSession(forceNew: Bool) {
        let today = ReviewSessionRecord.dayString(Date())
        let key = ReviewSessionRecord.key(theme: state.theme)
        state.noteDraft = nil
        do {
            if !forceNew,
               let saved = ReviewSessionRecord.load(key: key),
               saved.day == today {
                let hs = try store.db.highlights(ids: saved.regularIds + saved.masteryIds)
                state.cards = hs.map { ReviewCard(highlight: $0, isMastery: false) }
                state.position = min(saved.position, state.cards.count)
                state.day = today
                return
            }

            let (highlights, weights) = try store.db.reviewCandidates(tag: state.theme)
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
}

/// 一边写一边看：Markdown 实时预览
struct MarkdownPreview: View {
    let text: String
    var font: Font = .body
    var style: RichWebText.Style = .preview
    var slot = "preview"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("预览").font(.caption).foregroundStyle(.secondary)
            if text.isEmpty {
                Text("（空）").font(font).foregroundStyle(.secondary)
            } else {
                // 与回顾页同一套网页渲染：标题放大、列表缩进、图片显示
                RichWebText(text: text, style: style, slot: slot)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 当日回顾的持久化（UserDefaults，体积很小）
struct ReviewSessionRecord: Codable {
    var day: String
    var regularIds: [Int64]
    var masteryIds: [Int64]
    var position: Int

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
