import SwiftUI
import KongGleanCore

/// 每日回顾：一次一张卡片。同一天内重开应用会回到同一组、同一位置。
struct DailyReviewView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(SettingsKeys.dailyCount) private var dailyCount = 10
    @AppStorage(SettingsKeys.masteryLimit) private var masteryLimit = 5

    /// 主题回顾：按标签限定范围；nil 为全库
    @State private var theme: String?
    @State private var cards: [ReviewCard] = []
    @State private var position = 0

    private var scheduler: ReviewScheduler {
        ReviewScheduler(config: .init(dailyCount: dailyCount, masteryLimit: masteryLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cards.isEmpty {
                ContentUnavailableView(
                    "暂无可回顾的摘录",
                    systemImage: "sun.max",
                    description: Text("先录入几条摘录，明天这里就会出现它们。")
                )
            } else if position >= cards.count {
                finished
            } else {
                ScrollView {
                    ReviewCardView(card: cards[position], source: store.source(for: cards[position].highlight))
                        .padding(40)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
                Divider()
                controls(for: cards[position])
                    .padding()
            }
        }
        .navigationTitle(theme.map { "主题回顾 · #\($0)" } ?? "今日回顾")
        .task(id: theme) { loadSession(forceNew: false) }
        .onChange(of: store.revision) { refreshCards() }
    }

    // MARK: 子视图

    private var header: some View {
        HStack {
            Picker("范围", selection: $theme) {
                Text("全部").tag(String?.none)
                ForEach(store.tags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
            }
            .frame(maxWidth: 220)
            Spacer()
            if !cards.isEmpty {
                ProgressView(value: Double(min(position, cards.count)), total: Double(cards.count))
                    .frame(width: 160)
                Text("\(min(position + 1, cards.count)) / \(cards.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal").font(.system(size: 48)).foregroundStyle(.tint)
            Text("今日回顾完成").font(.title2)
            Text("共 \(cards.count) 条").foregroundStyle(.secondary)
            HStack {
                Button("从头再看一遍") { position = 0; persist() }
                Button("再抽一组") { loadSession(forceNew: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func controls(for card: ReviewCard) -> some View {
        HStack(spacing: 12) {
            Button { go(-1) } label: { Label("上一条", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(position == 0)
            Button("编辑") { store.edit(card.highlight) }
                .keyboardShortcut("e", modifiers: [])

            Spacer()

            if card.isMastery {
                ForEach(ReviewScheduler.MasteryGrade.allCases, id: \.self) { grade in
                    let number = (ReviewScheduler.MasteryGrade.allCases.firstIndex(of: grade) ?? 0) + 1
                    Button("\(number). \(grade.label)（\(Int(grade.halfLifeDays))天）") {
                        update(scheduler.grade(grade, scheduler.markSurfaced(card.highlight)))
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
                }
            } else {
                Button(role: .destructive) {
                    update(scheduler.apply(.discard, to: card.highlight))
                } label: { Label("弃置", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("以后不再出现（可在列表中恢复）")

                Button {
                    update(scheduler.apply(.favorite, to: card.highlight))
                } label: { Label("收藏", systemImage: card.highlight.isFavorite ? "star.fill" : "star") }
                    .keyboardShortcut("f", modifiers: [])

                Button {
                    update(scheduler.addToMastery(scheduler.markSurfaced(card.highlight)))
                } label: { Label("加入记忆卡", systemImage: "brain") }
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(card.highlight.isInMastery)

                Button {
                    update(scheduler.apply(.keep, to: card.highlight))
                } label: { Label("下一条", systemImage: "chevron.right") }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: 逻辑

    private func update(_ highlight: Highlight) {
        store.save(highlight)
        go(1)
    }

    private func go(_ delta: Int) {
        position = max(0, min(cards.count, position + delta))
        persist()
    }

    private func loadSession(forceNew: Bool) {
        let today = ReviewSessionRecord.dayString(Date())
        let key = ReviewSessionRecord.key(theme: theme)
        do {
            if !forceNew,
               let saved = ReviewSessionRecord.load(key: key),
               saved.day == today {
                let regular = try store.db.highlights(ids: saved.regularIds)
                let mastery = try store.db.highlights(ids: saved.masteryIds)
                cards = regular.map { ReviewCard(highlight: $0, isMastery: false) }
                    + mastery.map { ReviewCard(highlight: $0, isMastery: true) }
                position = min(saved.position, cards.count)
                return
            }

            let (highlights, weights) = try store.db.reviewCandidates(tag: theme)
            let session: ReviewScheduler.Session
            if forceNew {
                session = scheduler.makeSession(highlights: highlights, sourceWeights: weights)
            } else {
                // 以日期为种子：同一天抽到的是同一组
                var rng = SeededGenerator.forDay(Date())
                session = scheduler.makeSession(highlights: highlights, sourceWeights: weights, using: &rng)
            }
            cards = session.regular.map { ReviewCard(highlight: $0, isMastery: false) }
                + session.mastery.map { ReviewCard(highlight: $0, isMastery: true) }
            position = 0
            persist()
        } catch {
            store.report(error)
        }
    }

    /// 编辑或其他写入后，用数据库中的最新内容刷新卡片（顺序不变）
    private func refreshCards() {
        let ids = cards.compactMap(\.highlight.id)
        guard !ids.isEmpty, let fresh = try? store.db.highlights(ids: ids) else { return }
        let byId = Dictionary(uniqueKeysWithValues: fresh.compactMap { h in h.id.map { ($0, h) } })
        cards = cards.map { card in
            var c = card
            if let id = card.highlight.id, let h = byId[id] { c.highlight = h }
            return c
        }
    }

    private func persist() {
        ReviewSessionRecord(
            day: ReviewSessionRecord.dayString(Date()),
            regularIds: cards.filter { !$0.isMastery }.compactMap(\.highlight.id),
            masteryIds: cards.filter(\.isMastery).compactMap(\.highlight.id),
            position: position
        ).save(key: ReviewSessionRecord.key(theme: theme))
    }
}

struct ReviewCard: Identifiable {
    var highlight: Highlight
    var isMastery: Bool
    var id: Int64 { highlight.id ?? -1 }
}

struct ReviewCardView: View {
    let card: ReviewCard
    let source: Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if card.isMastery {
                Label("记忆卡", systemImage: "brain").font(.caption).foregroundStyle(.purple)
            }
            Text(card.highlight.text)
                .font(.system(size: 22, design: .serif))
                .lineSpacing(8)
                .textSelection(.enabled)
            if let t = card.highlight.translation {
                Text(t).font(.system(size: 16)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let n = card.highlight.note {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(.tint).frame(width: 3)
                    Text(n).font(.callout).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            let cite = CitationFormatter.citation(for: card.highlight, source: source)
            if !cite.isEmpty {
                Text("—— \(cite)").font(.callout).foregroundStyle(.secondary)
            }
            if !card.highlight.tags.isEmpty {
                Text(card.highlight.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
