import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 1.7：记忆卡首页（牌组）重新设计
//
// 版式取“书斋”意趣：暖白纸色底、宋体标题、传统色书脊、印章表示“今日已毕”；
// 顶部是今天的功课（还剩多少、已复习多少、预计用时），下面是牌组卡片网格。

/// 牌组书脊用的传统色（色值为常见“中国传统色”色卡的近似值，略压暗以保证白底上的对比度）
enum DeckColors {
    static let all: [(name: String, color: Color)] = [
        ("石青", Color(red: 0x1D / 255, green: 0x6F / 255, blue: 0x93 / 255)),
        ("朱砂", Color(red: 0xB5 / 255, green: 0x49 / 255, blue: 0x3A / 255)),
        ("松绿", Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0x4F / 255)),
        ("藤黄", Color(red: 0xC2 / 255, green: 0x8E / 255, blue: 0x1E / 255)),
        ("黛蓝", Color(red: 0x42 / 255, green: 0x50 / 255, blue: 0x66 / 255)),
        ("赭石", Color(red: 0x9C / 255, green: 0x5B / 255, blue: 0x3B / 255)),
        ("胭脂", Color(red: 0x9D / 255, green: 0x29 / 255, blue: 0x33 / 255)),
        ("竹青", Color(red: 0x5E / 255, green: 0x7D / 255, blue: 0x4E / 255)),
    ]
    static func color(for deck: String) -> Color {
        all[DeckOverview.colorIndex(deck, count: all.count)].color
    }
    /// 印泥红
    static let seal = Color(red: 0xC0 / 255, green: 0x2C / 255, blue: 0x38 / 255)
    static let newColor = ReviewPalette.accent
    static let learnColor = ReviewPalette.hard
    static let reviewColor = ReviewPalette.easy
}

/// 印章：两字竖排或四字两列（自右向左读）
struct SealStamp: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        let chars = text.map(String.init)
        let columns: [[String]] = chars.count <= 2
            ? [chars]
            : [Array(chars.prefix(2)), Array(chars.dropFirst(2).prefix(2))].reversed()
        HStack(spacing: size * 0.12) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                VStack(spacing: 0) {
                    ForEach(Array(col.enumerated()), id: \.offset) { _, c in
                        Text(c).font(.custom("Kaiti SC", size: size).weight(.bold))
                    }
                }
            }
        }
        .foregroundStyle(DeckColors.seal)
        .padding(.horizontal, size * 0.32)
        .padding(.vertical, size * 0.22)
        .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(DeckColors.seal, lineWidth: max(1.2, size * 0.1)))
        .opacity(0.86)
        .rotationEffect(.degrees(-7))
        .accessibilityLabel(text)
    }
}

/// 今日已学张数；学习步骤中已学和待学可能重叠，因此不写百分比。
/// 3.14：环按“今天已学（松绿）: 当前待学（朱红）”分两段，与首页同色。
struct DailyRing: View {
    let done: Int
    let remaining: Int

    var body: some View {
        let total = done + remaining
        let doneShare = total == 0 ? 0 : CGFloat(done) / CGFloat(total)
        ZStack {
            Circle().stroke(ReviewPalette.hair, lineWidth: 9)
            if done > 0 {
                Circle().trim(from: 0, to: doneShare)
                    .stroke(ReviewPalette.done, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if remaining > 0 {
                Circle().trim(from: doneShare, to: 1)
                    .stroke(ReviewPalette.pending.opacity(0.85), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text("\(done)")
                    .font(.system(size: 30, weight: .medium, design: .serif).monospacedDigit())
                    .foregroundStyle(done > 0 ? ReviewPalette.done : ReviewPalette.ink)
                Text("今天已学").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                if remaining > 0 {
                    Text("待学 \(remaining)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(ReviewPalette.pending)
                }
            }
        }
        .frame(width: 118, height: 118)
        .help("今天已学 \(done) 张，当前可学 \(remaining) 张。同一卡片反复评分只计 1 张，学习步骤中的卡片可能再次待学。")
    }
}

struct DeckHomeView: View {
    @Environment(LibraryStore.self) private var store
    let decks: [DeckSummary]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                HStack {
                    Button("难卡集中练习") { store.learningExplorer = .init(route: .difficult) }
                    Button("学习记录日历") { store.learningExplorer = .init(route: .day(Date())) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 18, alignment: .top)],
                              alignment: .leading, spacing: 18) {
                        ForEach(decks) { d in
                            DeckTile(deck: d, all: decks)
                        }
                    }
                }
                legend
                ReviewHeatmapView()
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        // 2.2：每次回到牌组页、以及停留期间每分钟，按当前时间重算（学习中的卡几分钟后到期、跨日都会变）
        .onAppear { store.refreshDerived() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                store.checkDayChange()
                store.refreshDerived()
            }
        }
    }

    // MARK: 今日功课

    /// 3.13：今天还可学以全库队列为准（有全库合计上限时，各牌组之和可能超过合计余额）
    private var totals: (due: StudyQueue.Counts, done: Int) {
        (store.todayCardPending, decks.reduce(0) { $0 + $1.doneToday })
    }

    /// 有全库合计上限时的一行说明：今天已学 / 合计
    private var totalCapNote: String? {
        guard let ledger = store.dailyLimitLedgerCache else { return nil }
        let spent = ledger.totalSpent
        let parts = [ledger.totalLimit(.new).map { "新卡 \(spent.new) / \($0)" },
                     ledger.totalLimit(.review).map { "复习 \(spent.review) / \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : "全库每日合计：" + parts.joined(separator: " · ")
    }

    /// “开始复习”默认的牌组：3.15 起先选含本期焦点卡片最多、且还有卡的牌组；否则上次学的，再否则待学最多的
    private var suggestedDeck: DeckSummary? {
        let focusDecks = decks.filter { $0.counts.total > 0 && (store.focusDeckCounts[$0.name] ?? 0) > 0 }
        if let d = focusDecks.max(by: { (store.focusDeckCounts[$0.name] ?? 0) < (store.focusDeckCounts[$1.name] ?? 0) }) { return d }
        if let last = store.study.lastDeck, let d = decks.first(where: { $0.name == last && $0.counts.total > 0 }) { return d }
        return decks.filter { $0.counts.total > 0 }.max { $0.counts.total < $1.counts.total }
    }

    @ViewBuilder
    private func heroPrimaryButtons(remaining: Int) -> some View {
        if remaining == 0 && store.revisitCounts.left > 0 {
            // 6.0.3：记忆卡学完，回到今日试卷接着答
            PillButton(icon: "list.clipboard", title: "回到今日试卷", style: .primary) {
                store.openExam()
            }
            .fixedSize()
        }
        if let d = suggestedDeck {
            PillButton(icon: "play.fill", title: "开始复习：\(DeckOverview.split(d.name).leaf)", style: .primary) {
                store.startStudy(deck: d.name)
            }
            .fixedSize()
            .help("学习牌组“\(d.name)”")
        }
    }

    @ViewBuilder
    private var heroSecondaryButtons: some View {
        if decks.filter({ $0.counts.total > 0 }).count > 1 {
            PillButton(icon: "square.stack.3d.up", title: "学习全部牌组") { store.startStudyAllDecks() }
                .fixedSize()
                .help("各牌组混在一起学：学习中、到期复习优先，再按创建先后出新卡；各牌组上限与全库合计照常生效")
        }
        PillButton(icon: "slider.horizontal.3", title: "每日学习量") { store.openDailyLimits() }
            .fixedSize()
            .help("设置牌组默认值、全库合计和各牌组的每日上限")
        PillButton(icon: "plus", title: "新建卡片") { store.newCard(deck: store.study.lastDeck) }
            .fixedSize()
    }

    private var hero: some View {
        let t = totals
        let remaining = t.due.total
        let summary = store.globalCardLearningSummary
        let done = summary?.studiedCards ?? t.done
        let status = summary?.availability
        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(DeckOverview.chineseDate(Date()))
                    .font(.system(size: 12, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(ReviewPalette.sub)
                headline(remaining: remaining, done: done, status: status)
                    .padding(.top, 10)
                HStack(spacing: 18) {
                    dot(DeckColors.newColor, "新卡", t.due.new)
                    dot(DeckColors.learnColor, "学习中", t.due.learning)
                    dot(DeckColors.reviewColor, "待复习", t.due.review)
                    if remaining > 0 {
                        Text("约 \(DeckOverview.estimatedMinutes(t.due)) 分钟")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ReviewPalette.sub)
                    }
                }
                .padding(.top, 12)
                if let note = totalCapNote {
                    Text(note)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(ReviewPalette.sub)
                        .padding(.top, 8)
                }
                if remaining == 0, let status {
                    Text(status.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    if status.blockedNew > 0 || status.blockedReview > 0 {
                        TodayExtraButtons(blockedNew: status.blockedNew, blockedReview: status.blockedReview)
                            .padding(.top, 10)
                    }
                }
                // 6.1.0：按钮一律不截字；窄时“学习全部牌组 / 每日学习量 / 新建卡片”另起一行
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { heroPrimaryButtons(remaining: remaining); heroSecondaryButtons }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { heroPrimaryButtons(remaining: remaining) }
                        HStack(spacing: 10) { heroSecondaryButtons }
                    }
                }
                .padding(.top, 20)
                Text("学而时习之，不亦说乎？——《论语·学而》")
                    .font(.custom("Kaiti SC", size: 12.5))
                    .foregroundStyle(ReviewPalette.sub.opacity(0.85))
                    .padding(.top, 18)
            }
            Spacer(minLength: 12)
            ZStack(alignment: .topTrailing) {
                DailyRing(done: done, remaining: remaining)
                    .padding(8)
                if status?.kind == .complete {
                    SealStamp(text: "日课已毕", size: 14)
                        .offset(x: 14, y: -10)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ReviewPalette.card)
                .overlay(alignment: .bottomTrailing) {
                    // 淡淡的水墨晕染
                    Circle()
                        .fill(RadialGradient(colors: [ReviewPalette.accent.opacity(0.07), .clear],
                                             center: .center, startRadius: 0, endRadius: 180))
                        .frame(width: 360, height: 360)
                        .offset(x: 120, y: 150)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ReviewPalette.hair))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.07), radius: 16, y: 8)
    }

    @ViewBuilder
    private func headline(remaining: Int, done: Int, status: CardStudyAvailability?) -> some View {
        let font = Font.system(size: 30, weight: .semibold, design: .serif)
        if remaining > 0 {
            Text("今天还有 \(Text("\(remaining)").foregroundStyle(ReviewPalette.pending)) 张卡片等你")
                .font(font)
                .foregroundStyle(ReviewPalette.ink)
        } else if let status {
            Text(status.title).font(font).foregroundStyle(ReviewPalette.ink)
        } else if done > 0 {
            Text("当前待学已完成").font(font).foregroundStyle(ReviewPalette.ink)
        } else {
            Text("今天没有到期的卡片").font(font).foregroundStyle(ReviewPalette.ink)
        }
    }

    private func dot(_ color: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            // 3.15：待学张数用朱红；圆点仍表示新卡／学习中／待复习的类别
            Text("\(n)").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(n == 0 ? ReviewPalette.sub : ReviewPalette.pending)
        }
    }

    // MARK: 牌组

    private var sectionHeader: some View {
        let total = decks.reduce(0) { $0 + $1.total }
        let m = decks.reduce(DeckMaturity()) { $0 + $1.maturity }
        return HStack(alignment: .firstTextBaseline) {
            Text("牌组").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
            Spacer()
            Text("\(decks.count) 个牌组 · 共 \(total) 张" + (m.matureRatio.map { " · 熟记 \(Int(($0 * 100).rounded()))%" } ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(ReviewPalette.sub)
        }
        .padding(.horizontal, 4)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text("条形图").foregroundStyle(ReviewPalette.sub)
            swatch(DeckColors.all[2].color, "书脊色：熟记（间隔 ≥ 21 天）")
            swatch(DeckColors.all[2].color.opacity(0.4), "浅色：生疏")
            swatch(DeckColors.learnColor, "学习中")
            swatch(DeckColors.newColor.opacity(0.25), "新卡")
            Spacer()
            Text("点牌组卡片上的“新 · 复”调整这个牌组的每日上限；右键可重命名、设置算法（SM-2 / FSRS）。未单独设置的牌组：每天新卡 \(CardSettings.newPerDay)、复习 \(CardSettings.reviewsPerDay)。")
                .foregroundStyle(ReviewPalette.sub)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 4)
    }

    private func swatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 6)
            Text(label).foregroundStyle(ReviewPalette.sub)
        }
        .fixedSize()
    }
}

/// 一个牌组：传统色书脊、宋体名、三项计数、熟练度条、操作
struct DeckTile: View {
    @Environment(LibraryStore.self) private var store
    let deck: DeckSummary
    let all: [DeckSummary]

    var body: some View {
        let tint = DeckColors.color(for: deck.name)
        let parts = DeckOverview.split(deck.name)
        let o = store.options(for: deck.name)
        let availability = store.globalCardLearningSummary?.deckAvailability[deck.name]
        let finishedToday = availability?.kind == .complete
        return HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 5)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(parts.parent ?? " ")
                        .font(.system(size: 11.5))
                        .foregroundStyle(parts.parent == nil ? Color.clear : ReviewPalette.sub)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(parts.leaf)
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .foregroundStyle(ReviewPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let n = store.focusDeckCounts[deck.name], n > 0, let focus = store.learningFocus {
                            Label("焦点 \(n)", systemImage: "scope")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(ReviewPalette.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(ReviewPalette.accentSoft, in: Capsule())
                                .help("本牌组有 \(n) 张卡片来自\(focus.kind == .project ? "当前" : "本期焦点")\(focus.label)，学习时优先出现")
                                .fixedSize()
                        }
                    }
                }
                .padding(.trailing, finishedToday ? 56 : 0)
                HStack(spacing: 0) {
                    stat("新卡", deck.counts.new, DeckColors.newColor)
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 30)
                    stat("学习中", deck.counts.learning, DeckColors.learnColor)
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 30)
                    stat("待复习", deck.counts.review, DeckColors.reviewColor)
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ReviewPalette.soft))
                VStack(alignment: .leading, spacing: 6) {
                    MaturityBar(m: deck.maturity, tint: tint)
                    HStack {
                        Text("共 \(deck.total) 张" + (deck.maturity.matureRatio.map { " · 熟记 \(Int(($0 * 100).rounded()))%" } ?? " · 尚未开始"))
                        Spacer()
                        if deck.maturity.suspended > 0 { Text("暂停 \(deck.maturity.suspended)") }
                        if deck.maturity.new > deck.counts.new && deck.maturity.new > 0 { Text("新卡尚余 \(deck.maturity.new)") }
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(ReviewPalette.sub)
                }
                if deck.counts.total == 0, let availability {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(availability.title).font(.system(size: 12, weight: .medium))
                        Text(availability.detail).font(.system(size: 11.5))
                    }
                    .foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(o.algorithm == .fsrs ? "FSRS \(Int((o.desiredRetention * 100).rounded()))%" : "SM-2")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ReviewPalette.sub)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(ReviewPalette.soft))
                        .overlay(Capsule().stroke(ReviewPalette.hair))
                        .lineLimit(1)
                        .fixedSize()
                        .help("排程算法（右键“牌组选项…”修改）")
                    DeckLimitChip(deck: deck.name, options: o)
                    Spacer(minLength: 4)
                    PillButton(title: "浏览") {
                        store.study.openCardBrowser(deck.name)
                    }
                    .fixedSize()
                    PillButton(icon: finishedToday ? nil : "play.fill", title: "学习", style: .primary, disabled: deck.counts.total == 0) {
                        store.startStudy(deck: deck.name)
                    }
                    .fixedSize()
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.vertical, 16)
        }
        .background {
            ZStack(alignment: .bottomTrailing) {
                ReviewPalette.card
                // 牌组名首字作水印
                Text(String(parts.leaf.prefix(1)))
                    .font(.system(size: 120, weight: .bold, design: .serif))
                    .foregroundStyle(tint.opacity(0.05))
                    .offset(x: 12, y: 34)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        .overlay(alignment: .topTrailing) {
            if finishedToday {
                SealStamp(text: "今日已毕", size: 13)
                    .padding(.top, 16)
                    .padding(.trailing, 18)
                    .help("这个牌组今天学完了")
            }
        }
        .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
        .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.06), radius: 10, y: 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if deck.counts.total > 0 { store.startStudy(deck: deck.name) } }
        .contextMenu {
            Button("在此牌组新建卡片") { store.newCard(deck: deck.name) }
            Button("重命名牌组…") {
                store.study.renameText = deck.name
                store.study.renamingDeck = deck.name
            }
            Button("每日学习量…") { store.openDailyLimits(focus: deck.name) }
            Button("牌组选项…") {
                var opt = (try? store.db.deckOptions())?[deck.name] ?? DeckOptions(deck: deck.name)
                opt.deck = deck.name
                store.deckOptionsEditor = opt
            }
            Button("设置录入模板…") {
                store.deckEntryPresetEditor = .init(deck:deck.name)
            }
            Divider()
            Button("导出到 Anki…") { store.apkgExport = ApkgExportRequest(allDecks: all.map(\.name), decks: [deck.name]) }
        }
    }

    /// 3.15：张数都是“待学”，用朱红；标签前的圆点保留类别色
    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)")
                .font(.system(size: 22, weight: .medium, design: .serif).monospacedDigit())
                .foregroundStyle(n == 0 ? ReviewPalette.sub.opacity(0.55) : ReviewPalette.pending)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 熟练度条：熟记（书脊色深）、生疏（书脊色浅）、学习中（橙）、新卡（淡蓝）
struct MaturityBar: View {
    let m: DeckMaturity
    let tint: Color

    var body: some View {
        let f = m.fractions
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                Rectangle().fill(tint).frame(width: w * f.mature)
                Rectangle().fill(tint.opacity(0.4)).frame(width: w * f.young)
                Rectangle().fill(DeckColors.learnColor).frame(width: w * f.learning)
                Rectangle().fill(DeckColors.newColor.opacity(0.22)).frame(width: w * f.new)
            }
        }
        .frame(height: 6)
        .background(ReviewPalette.hair)
        .clipShape(Capsule())
        .help("熟记 \(m.mature) · 生疏 \(m.young) · 学习中 \(m.learning) · 新卡 \(m.new)" + (m.suspended > 0 ? " · 暂停 \(m.suspended)" : ""))
    }
}

// MARK: - 1.8：一年来的功课（复习热力图）

/// 每格一天、每列一周（周一在上）；颜色取当天复习最多的牌组的书脊色，深浅表示复习次数
struct ReviewHeatmapView: View {
    @Environment(LibraryStore.self) private var store

    static let cell: CGFloat = 11
    static let gap: CGFloat = 3

    var body: some View {
        let _ = store.revision
        let days = store.reviewHeatmap()
        let cal = ReviewHeatmap.calendar()
        let keys = Set(days.filter { $0.value.count > 0 }.keys)
        let streak = ReviewHeatmap.streak(keys, today: Date(), calendar: cal)
        let yearAgo = ReviewHeatmap.dayKey(cal.date(byAdding: .day, value: -365, to: Date()) ?? Date(), calendar: cal)
        let inYear = days.filter { $0.key > yearAgo && $0.value.count > 0 }
        let total = inYear.values.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("一年来的功课").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
                Text("过去一年学了 \(inYear.count) 天 · 复习 \(total) 次 · 连续 \(streak) 天")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(ReviewPalette.sub)
            }
            .padding(.horizontal, 4)
            GeometryReader { geo in
                let weekCount = max(4, min(53, Int((geo.size.width - 22) / (Self.cell + Self.gap))))
                grid(days: days, weeks: ReviewHeatmap.weeks(end: Date(), count: weekCount, calendar: cal), calendar: cal)
            }
            .frame(height: 7 * (Self.cell + Self.gap) + 18)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
            HStack(spacing: 6) {
                Text("颜色取当天复习最多的牌组的书脊色。少").foregroundStyle(ReviewPalette.sub)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(l == 0 ? ReviewPalette.hair : DeckColors.all[2].color.opacity(Self.opacity(l)))
                        .frame(width: Self.cell, height: Self.cell)
                }
                Text("多").foregroundStyle(ReviewPalette.sub)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 4)
        }
    }

    static func opacity(_ level: Int) -> Double { [0, 0.28, 0.5, 0.75, 1][max(0, min(4, level))] }

    private func grid(days: [String: ReviewHeatmap.Day], weeks: [[Date?]], calendar: Calendar) -> some View {
        let maxCount = weeks.joined().compactMap { $0 }.map { days[ReviewHeatmap.dayKey($0, calendar: calendar)]?.count ?? 0 }.max() ?? 0
        let labels = ReviewHeatmap.monthLabels(weeks, calendar: calendar)
        let step = Self.cell + Self.gap
        return HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(height: 18)
                ForEach(0..<7, id: \.self) { i in
                    Text(i % 2 == 0 ? ["一", "", "三", "", "五", "", "日"][i] : "")
                        .font(.system(size: 9))
                        .foregroundStyle(ReviewPalette.sub)
                        .frame(width: 14, height: step, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                        if let label {
                            Text(label).font(.system(size: 9.5)).foregroundStyle(ReviewPalette.sub)
                                .fixedSize()
                                .offset(x: CGFloat(i) * step)
                        }
                    }
                }
                .frame(height: 18, alignment: .topLeading)
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { r in
                                cellView(col[r], days: days, maxCount: maxCount, calendar: calendar)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ date: Date?, days: [String: ReviewHeatmap.Day], maxCount: Int, calendar: Calendar) -> some View {
        if let date {
            let key = ReviewHeatmap.dayKey(date, calendar: calendar)
            let day = days[key]
            let n = day?.count ?? 0
            let level = ReviewHeatmap.level(n, max: maxCount)
            let tint = day?.topDeck.map { DeckColors.color(for: $0) } ?? DeckColors.all[2].color
            let isToday = calendar.isDateInToday(date)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(level == 0 ? ReviewPalette.hair : tint.opacity(Self.opacity(level)))
                .frame(width: Self.cell, height: Self.cell)
                .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(isToday ? ReviewPalette.ink.opacity(0.5) : .clear, lineWidth: 1))
                .help(Self.tooltip(date, n: n, deck: day?.topDeck, calendar: calendar))
                .onTapGesture { store.learningExplorer = .init(route: .day(date)) }
                .handCursor()
                .accessibilityAddTraits(.isButton)
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }

    static func tooltip(_ d: Date, n: Int, deck: String?, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        let date = "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
        guard n > 0 else { return date + "：没有复习" }
        return date + "：复习 \(n) 次" + (deck.map { "（主要是“\($0)”）" } ?? "")
    }
}

// MARK: - 3.13：每日上限的入口

/// 牌组卡片上的“新 20 · 复 200”：点一下打开每日学习量并定位到这个牌组
struct DeckLimitChip: View {
    @Environment(LibraryStore.self) private var store
    let deck: String
    /// 牌组的有效选项（未设置的项已填入默认值），只在账本尚未算出时兜底显示
    let options: DeckOptions

    var body: some View {
        let ledger = store.dailyLimitLedgerCache
        let limit = ledger?.deckLimit(deck)
            ?? DailyAmount(new: options.newPerDay ?? CardSettings.newPerDay, review: options.reviewsPerDay ?? CardSettings.reviewsPerDay)
        // options 已用默认值补齐，是否单独设置要看账本里的原始设置
        let custom = ledger.map { $0.isOverridden(deck, .new) || $0.isOverridden(deck, .review) } ?? false
        let extra = ledger.flatMap { $0.settings.extra?.deck(deck, on: $0.day) } ?? .zero
        return Button { store.openDailyLimits(focus: deck) } label: {
            Text("新 \(limit.new) · 复 \(limit.review)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(custom || !extra.isZero ? ReviewPalette.accent : ReviewPalette.sub)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(ReviewPalette.soft))
                .overlay(Capsule().stroke(ReviewPalette.hair))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(helpText(limit: limit, custom: custom, extra: extra))
    }

    private func helpText(limit: DailyAmount, custom: Bool, extra: DailyAmount) -> String {
        var text = "每天新卡 \(limit.new) 张、复习 \(limit.review) 张"
        text += custom ? "（此牌组单独设置）" : "（牌组默认值）"
        if !extra.isZero { text += "，含今天临时加量" }
        if CardSettings.totalNewPerDay != nil || CardSettings.totalReviewsPerDay != nil { text += "；同时受全库合计约束" }
        return text + "。点一下调整。"
    }
}

/// 达到上限时的“仅今天”加量按钮：只放出当前范围被挡住的卡，次日自动恢复
struct TodayExtraButtons: View {
    @Environment(LibraryStore.self) private var store
    let blockedNew: Int
    let blockedReview: Int
    var showsAdjust = true

    var body: some View {
        // 窄窗口时改为上下排列
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if blockedNew > 0 {
            let n = min(10, blockedNew)
            PillButton(icon: "plus.circle", title: "今天再学 \(n) 张新卡") { _ = store.addTodayExtra(n, kind: .new) }
                .help("仅今天放宽新卡上限，明天自动恢复")
        }
        if blockedReview > 0 {
            let n = min(50, blockedReview)
            PillButton(icon: "plus.circle", title: "今天再复习 \(n) 张") { _ = store.addTodayExtra(n, kind: .review) }
                .help("仅今天放宽复习上限，明天自动恢复")
        }
        if showsAdjust {
            PillButton(icon: "slider.horizontal.3", title: "调整每日学习量…", style: .ghost) {
                store.openDailyLimits(focus: store.study.allDecks ? nil : store.study.deck)
            }
        }
    }
}
