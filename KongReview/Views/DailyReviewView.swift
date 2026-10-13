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
            topBar
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
                    .padding(.top, 4)
                    .padding(.bottom, 22)
            }
        }
        .background(ReviewPalette.page)
        .navigationTitle(state.theme.map { "主题回顾 · #\($0)" } ?? "今日回顾")
        .task(id: (state.theme ?? "") + "|" + store.today) { loadSession(forceNew: false) }
        .onChange(of: store.revision) { refreshCards() }
    }

    // MARK: 子视图

    /// 顶部细条：范围、进度、连续天数、待学卡片、全部统计（不抢正文的视线）
    private var topBar: some View {
        let _ = store.revision
        let _ = store.today
        let s = ReviewStats.summarize((try? store.db.events()) ?? [], now: Date(), days: 7)
        let due = store.dueCardCount()
        return VStack(spacing: 0) {
            HStack(spacing: 22) {
                Picker("范围", selection: Bindable(store.review).theme) {
                    Text("全部摘录").tag(String?.none)
                    ForEach(store.tags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                if !state.cards.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(min(state.position, state.cards.count)), total: Double(state.cards.count))
                            .tint(ReviewPalette.accent)
                            .frame(width: 90)
                        Text("\(min(state.position + 1, state.cards.count)) / \(state.cards.count)")
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(ReviewPalette.sub)
                    }
                }
                StatChip(icon: "flame.fill", iconColor: ReviewPalette.hard, label: "连续", value: "\(s.currentStreak) 天")
                Button { store.selection = .cards } label: {
                    StatChip(icon: "brain", iconColor: ReviewPalette.accent, label: "记忆卡待学", value: "\(due)")
                }
                .buttonStyle(.plain)
                .help("打开记忆卡")
                Spacer()
                Button("全部统计 ›") { store.selection = .stats }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ReviewPalette.accent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            Rectangle().fill(ReviewPalette.hair).frame(height: 1)
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

    /// 回顾完成：页面中部的一张总结卡——日期、三项大数字、近 7 天、今日一句、下一步
    private var finished: some View {
        let _ = store.revision
        let s = ReviewStats.summarize((try? store.db.events()) ?? [], now: Date(), days: 7)
        let due = store.dueCardCount()
        let peak = max(1, s.lastDays.map(\.total).max() ?? 1)
        let quote = todaysQuote()
        return ScrollView {
            VStack(spacing: 0) {
                Text(Self.longDate(Date()))
                    .font(.system(size: 12.5))
                    .tracking(1)
                    .foregroundStyle(ReviewPalette.sub)
                Text("今日回顾完成")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(ReviewPalette.ink)
                    .padding(.top, 10)
                    .padding(.bottom, 26)

                // 三项大数字
                HStack(spacing: 0) {
                    bigStat("\(s.today.highlights)", unit: "条", label: s.today.cards > 0 ? "今日回顾 · 记忆卡 \(s.today.cards) 次" : "今日回顾摘录")
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                    bigStat("\(s.currentStreak)", unit: "天", label: "连续回顾 · 最长 \(s.longestStreak) 天")
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                    bigStat("\(due)", unit: "张", label: due > 0 ? "记忆卡待学" : "记忆卡今天学完了", accent: due > 0)
                }
                .frame(height: 104)
                .overlay(alignment: .top) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }

                // 近 7 天
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(Array(s.lastDays.enumerated()), id: \.offset) { i, d in
                        let isToday = i == s.lastDays.count - 1
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isToday ? ReviewPalette.accent : ReviewPalette.accentSoft)
                                .frame(width: 16, height: max(6, 52 * CGFloat(d.total) / CGFloat(peak)))
                            Text(isToday ? "今天" : Self.weekday(d.key))
                                .font(.system(size: 11))
                                .foregroundStyle(isToday ? ReviewPalette.ink : ReviewPalette.sub)
                        }
                        .help("\(d.key)：摘录 \(d.highlights) 条，记忆卡 \(d.cards) 次")
                    }
                }
                .frame(height: 82, alignment: .bottom)
                .padding(.top, 22)

                // 今日一句
                if let q = quote {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("“\(q.text)”")
                            .font(.system(size: 16, design: .serif))
                            .lineSpacing(6)
                            .foregroundStyle(ReviewPalette.ink.opacity(0.88))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("今日一句" + (q.source.isEmpty ? "" : " · " + q.source))
                            .font(.system(size: 12.5))
                            .foregroundStyle(ReviewPalette.sub)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 24)
                }

                // 下一步
                HStack(spacing: 8) {
                    PillButton(icon: "chevron.left", title: "上一条", key: "←", style: .ghost) { go(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    if due > 0 {
                        PillButton(icon: "brain", title: "去学习记忆卡 · \(due)", style: .primary) { store.selection = .cards }
                    }
                    PillButton(title: "从头再看") { state.position = 0; persist() }
                    PillButton(title: "再抽一组", style: due > 0 ? .normal : .primary) { loadSession(forceNew: true) }
                }
                .padding(.top, 26)
            }
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .padding(.bottom, 34)
            .frame(width: 640)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ReviewPalette.hair))
            .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.08), radius: 20, y: 10)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private func bigStat(_ number: String, unit: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ? ReviewPalette.accent : ReviewPalette.ink)
                Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
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

    static func longDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 · EEEE"
        return f.string(from: d)
    }

    static func weekday(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return "" }
        return ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: d) - 1]
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
                    Text("回顾过 \(h.surfacedCount) 次").font(.caption).foregroundStyle(ReviewPalette.sub)
                }
                .padding(.top, 20)
            }

            Rectangle().fill(ReviewPalette.hair).frame(height: 1).padding(.top, 26)
            HStack(spacing: 14) {
                Text("添加于 \(h.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub.opacity(0.8))
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
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14))
                        .foregroundStyle(ReviewPalette.sub)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("分享")
            }
            .padding(.top, 12)
        }
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
            PillButton(icon: "text.bubble", title: "按语", key: "N", disabled: editingNote) { state.noteDraft = card.highlight.note ?? "" }
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
