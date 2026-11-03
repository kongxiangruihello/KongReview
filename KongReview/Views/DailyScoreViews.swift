import SwiftUI
import KongReviewCore

// MARK: - 日期一行（今日试卷、考场门口）
// 6.0.5：5.2.0 的“今日检查”页已并入今日试卷，页面代码拿掉；这里只留日评一节。

enum ExamDate {
    static func line(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }
}

// MARK: - 5.2.1：日评

/// 今日试卷成绩单里的日评：推进、完成度、掌握度、总分四格，自评 1–5 与一句话，近 7 天的总分
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
        // 5.2.2：小胜也计入推进的条数
        let moved = score.progress.total + store.todayGains.count
        tile("推进", moved > 0 ? "\(moved) 项" : "—",
             detail: progressDetail, color: moved > 0 ? ReviewPalette.done : ReviewPalette.sub)
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
