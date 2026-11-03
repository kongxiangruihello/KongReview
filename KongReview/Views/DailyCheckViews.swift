import SwiftUI
import KongReviewCore

// MARK: - 5.2.0：今日检查
//
// 一页看全今天的检查：回顾、记忆卡、重温（札记、笔记、问题、书）、自测，各组“已做 / 应做”。
// 应做在当天第一次统计时定下，之后新到期的不追加；可以今天跳过整组（不计入合计）。
// 页底列出标为“待整理”的笔记段落。

struct DailyCheckView: View {
    @Environment(LibraryStore.self) private var store
    @State private var organize: [OrganizeBlockItem] = []
    @State private var queue = RevisitQueue.empty

    var body: some View {
        let state = store.dailyCheck
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(state)
                ReviewCardContainer(padding: 0) {
                    ForEach(Array(state.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().padding(.leading, 64) }
                        groupRow(i + 1, row)
                    }
                }
                DailyScoreSection()
                if !organize.isEmpty { organizeSection }
                Text("“应做”是今天第一次统计时各组的待办，之后新到期的不追加；做得比应做多时按已做计。跳过的组今天不计入合计，明天照常。每天从本周自测中带几题、每天重温几段笔记，可在设置的“回顾”页修改。")
                    .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("今日检查")
        .task(id: "\(store.dailyCheckRevision)|\(store.revisitRevision)|\(store.today)") {
            organize = (try? store.db.blocksToOrganize()) ?? []
            queue = (try? store.db.revisitQueue()) ?? .empty
        }
    }

    // MARK: 页头

    private func header(_ s: DailyCheckState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日检查").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text(Self.dateLine()).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
                Spacer()
                if s.due > 0 {
                    Text("已做 \(s.done) / 应做 \(s.due)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.left == 0 ? ReviewPalette.done : ReviewPalette.ink)
                }
            }
            if let c = s.completion {
                ProgressView(value: c)
                    .tint(s.left == 0 ? ReviewPalette.done : ReviewPalette.accent)
                Text(s.left == 0 ? "今天的检查都做完了。" : "还剩 \(s.left) 项。按顺序做：先回顾，再记忆卡、重温，最后自测。")
                    .font(.system(size: 12.5)).foregroundStyle(s.left == 0 ? ReviewPalette.done : ReviewPalette.sub)
            } else {
                Text("今天没有到期要检查的材料。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
        }
    }

    static func dateLine(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }

    // MARK: 一组

    private func groupRow(_ n: Int, _ row: DailyCheckRow) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(badgeColor(row)).frame(width: 26, height: 26)
                if row.isComplete {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Label(row.group.title, systemImage: row.group.symbol)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(row.skipped ? ReviewPalette.sub : ReviewPalette.ink)
                Text(detail(row)).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if row.skipped {
                Text("今天跳过").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            } else if row.due == 0 {
                Text("今日无").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            } else {
                Text("\(row.done) / \(row.due) \(row.group.unit)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(row.isComplete ? ReviewPalette.done : ReviewPalette.pending)
            }
            Button(row.left > 0 && !row.skipped ? "去做" : "打开") { store.openDailyCheckGroup(row.group) }
                .controlSize(.small)
                .handCursor()
            Menu {
                if row.skipped {
                    Button("恢复这一组") { store.setDailyCheckGroup(row.group, skipped: false) }
                } else {
                    Button("今天跳过这一组") { store.setDailyCheckGroup(row.group, skipped: true) }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("跳过的组今天不计入已做 / 应做")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .opacity(row.skipped ? 0.6 : 1)
    }

    private func badgeColor(_ row: DailyCheckRow) -> Color {
        if row.skipped || row.due == 0 { return ReviewPalette.sub.opacity(0.5) }
        return row.isComplete ? ReviewPalette.done : ReviewPalette.pending
    }

    private func detail(_ row: DailyCheckRow) -> String {
        switch row.group {
        case .review: return "看过、收藏或弃置今天抽出的摘录"
        case .cards: return "到期的记忆卡（受每日上限约束）"
        case .revisit:
            var parts: [String] = []
            if !queue.notes.isEmpty || queue.notesDone > 0 { parts.append("札记 \(queue.notesDone)/\(queue.notesDone + queue.notes.count)") }
            if !queue.blocks.isEmpty || queue.blocksDone > 0 { parts.append("笔记 \(queue.blocksDone)/\(queue.blocksDone + queue.blocks.count)") }
            if !queue.questions.isEmpty || queue.questionsDone > 0 { parts.append("问题 \(queue.questionsDone)/\(queue.questionsDone + queue.questions.count)") }
            if !queue.books.isEmpty || queue.booksDone > 0 { parts.append("书 \(queue.booksDone)/\(queue.booksDone + queue.books.count)") }
            return parts.isEmpty ? "札记、笔记、「常念」的问题与读完的书" : parts.joined(separator: " · ")
        case .selfTest:
            let n = DailyCheckSettings.selfTestPerDay()
            return n == 0 ? "未开启（设置里可改为每天带 1–5 题）" : "每天从本周自测中带 \(n) 题"
        }
    }

    // MARK: 待整理

    private var organizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("待整理的笔记 \(organize.count) 段", systemImage: "tray.full")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                Spacer()
            }
            Text("重温时标为“待整理”的段落；在笔记本里改过这一段，就从这里移除。")
                .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            ForEach(organize) { item in
                Button { store.selection = .notebook(item.notebookId) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("《\(item.notebookTitle)》" + (item.heading.map { " · " + $0 } ?? ""))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                        Text(item.opening).font(.system(size: 12.5, design: .serif)).foregroundStyle(ReviewPalette.sub)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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


// MARK: - 5.2.1：日评

/// 今日检查页的日评：推进、完成度、掌握度、总分四格，自评 1–5 与一句话，近 7 天的总分
struct DailyScoreSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var score = DailyScore(day: "")
    @State private var recent: [DailyScore] = []
    @State private var picked: SelfScore?
    @State private var note = ""
    @State private var savedNote = ""
    @State private var savedPick: SelfScore?

    private var dirty: Bool { picked != savedPick || note.trimmingCharacters(in: .whitespacesAndNewlines) != savedNote }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("日评").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text("四项分开看，总分只作记录").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { tiles }
                VStack(alignment: .leading, spacing: 10) { tiles }
            }
            selfScorePicker
            if !recent.isEmpty { recentRow }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ReviewPalette.hair))
        .task(id: "\(store.dailyCheckRevision)|\(store.progressRevision)|\(store.today)") { load() }
    }

    private func load() {
        let day = AppDatabase.revisitDay(Date())
        let s = (try? store.db.dailyScore(day: day)) ?? DailyScore(day: day)
        let fresh = s.day != score.day || s.selfScore != savedPick || s.note != savedNote
        score = s
        recent = (try? store.db.recentDailyScores()) ?? []
        if fresh {
            picked = s.selfScore; savedPick = s.selfScore
            note = s.note; savedNote = s.note
        }
    }

    // MARK: 四格

    @ViewBuilder private var tiles: some View {
        tile("推进", score.progress.total > 0 ? "\(score.progress.total) 项" : "—",
             detail: progressDetail, color: score.progress.total > 0 ? ReviewPalette.done : ReviewPalette.sub)
        tile("完成度", score.completion.map { Self.percent($0) } ?? "—",
             detail: score.completion == nil ? "今天没有应做" : "已做 \(store.dailyCheck.done) / 应做 \(store.dailyCheck.due)",
             color: ReviewPalette.ink)
        tile("掌握度", score.mastery.ratio.map { Self.percent($0) } ?? "—",
             detail: score.mastery.total == 0 ? "记忆卡、自测、笔记重温"
                 : score.mastery.ratio == nil ? "已评 \(score.mastery.total) 条，满 5 条才算"
                 : "好 \(score.mastery.good) · 中 \(score.mastery.mid) · 差 \(score.mastery.bad)",
             color: ReviewPalette.ink)
        tile("总分", score.total.map(String.init) ?? "—",
             detail: score.total == nil ? "写下自评后算出" : formula, color: ReviewPalette.accent)
    }

    private var progressDetail: String {
        let lines = score.progress.lines + (store.todayGains.isEmpty ? [] : ["小胜 \(store.todayGains.count)"])
        return lines.isEmpty ? "修订、线索、收藏、弃置、待整理" : lines.joined(separator: " · ")
    }

    private var formula: String {
        switch (score.completion != nil, score.mastery.ratio != nil) {
        case (true, true): "完成 40 · 掌握 40 · 自评 20"
        case (true, false): "完成 70 · 自评 30"
        case (false, true): "掌握 70 · 自评 30"
        case (false, false): "只看自评"
        }
    }

    private func tile(_ title: String, _ value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(detail).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    // MARK: 自评

    private var selfScorePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给今天打个分").font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scoreButtons }
                VStack(alignment: .leading, spacing: 6) { scoreButtons }
            }
            TextField("今天最有收获的一点，或卡住的一点（可不填）", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                PillButton(icon: "checkmark", title: savedPick == nil ? "保存日评" : "更新日评", style: .primary,
                           disabled: picked == nil || !dirty) {
                    store.saveSelfScore(picked, note: note)
                }
                if !dirty && savedPick != nil {
                    Label("已保存", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(ReviewPalette.done)
                }
                Spacer()
                Text("只能当天写或改，明天起锁定").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
        }
    }

    @ViewBuilder private var scoreButtons: some View {
        ForEach(SelfScore.allCases) { s in
            Button { picked = s } label: {
                HStack(spacing: 6) {
                    Text("\(s.rawValue)").font(.system(size: 13, weight: .bold).monospacedDigit())
                    Text(s.title).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(picked == s ? Color.white : ReviewPalette.ink)
                .background(picked == s ? ReviewPalette.accent : ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ReviewPalette.hair))
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    // MARK: 近 7 天

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近 7 天总分").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            HStack(spacing: 6) {
                ForEach(recent, id: \.day) { d in
                    VStack(spacing: 2) {
                        Text(d.total.map(String.init) ?? "—")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(d.total == nil ? ReviewPalette.sub : ReviewPalette.ink)
                        Text(Self.shortDay(d.day)).font(.system(size: 10)).foregroundStyle(ReviewPalette.sub)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(d.day == score.day ? ReviewPalette.accentSoft : ReviewPalette.soft,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(d.note.isEmpty ? "" : d.note)
                }
            }
        }
    }

    static func shortDay(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return key }
        return "\(m)/\(d)"
    }
}
