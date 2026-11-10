import SwiftUI
import KongReviewCore

// MARK: - 5.2.2：打卡

/// 今日试卷、考场门口、成绩册顶部的一行：今天是否已打卡，连续 / 最长 / 累计 / 本月
struct CheckinStatusStrip: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let c = store.checkin
        HStack(spacing: 14) {
            if c.todayChecked {
                Label("今天已打卡", systemImage: "checkmark.seal.fill").foregroundStyle(ReviewPalette.done)
            } else if c.todayRest {
                Label("今天是休息日，打卡照样计入", systemImage: "cup.and.saucer").foregroundStyle(ReviewPalette.sub)
            } else {
                Label("日课做完（或答过题后收工）并写下日评即打卡", systemImage: "seal").foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 8)
            if c.current > 0 { number(c.current, "连续") } else { number(c.month, "本月") }
            number(c.longest, "最长")
            number(c.total, "累计")
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(c.todayChecked ? ReviewPalette.doneSoft : ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func number(_ n: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).foregroundStyle(ReviewPalette.sub)
            Text("\(n)").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
            Text("天").foregroundStyle(ReviewPalette.sub)
        }
    }
}

/// 连续中断后记一句原因（只记录，不评判）
struct StreakBreakPrompt: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let day = store.checkin.brokenOn {
            VStack(alignment: .leading, spacing: 10) {
                Text("连续打卡在 \(Self.label(day)) 断了。那天是因为——")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                HStack(spacing: 8) {
                    ForEach(StreakBreakReason.allCases) { r in
                        Button(r.title) { store.recordStreakBreak(r) }.controlSize(.small).handCursor()
                    }
                    Spacer()
                    Text("只记录，周报、月报里列出").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                }
                if !store.checkin.makeupDays.isEmpty {
                    Text("那天做过检查、只是忘了写日评，可以在成绩册下方补签（本月还剩 \(store.checkin.makeupLeft) 次）。")
                        .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        }
    }

    static func label(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return key }
        return "\(m)月\(d)日"
    }
}

/// 成绩册下方：一年打卡热力图、休息日、补签
struct CheckinSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var makeupDay: String?
    @State private var makeupScore: SelfScore?
    @State private var makeupNote = ""
    @State private var makeupError: String?

    var body: some View {
        let c = store.checkin
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("打卡").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text("本年 \(c.year) 天 · 本月 \(c.month) 天 · 累计 \(c.total) 天")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                Spacer()
            }
            CheckinHeatmap(summary: c)
            restDayRow(c)
            if !c.makeupDays.isEmpty || makeupDay != nil { makeupRow(c) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ReviewPalette.hair))
    }

    private func restDayRow(_ c: CheckinSummary) -> some View {
        HStack(spacing: 10) {
            Text("休息日").font(.system(size: 12.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
            Picker("", selection: Binding(get: { c.restWeekday ?? 0 }, set: { store.setRestWeekday($0 == 0 ? nil : $0) })) {
                Text("不设").tag(0)
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { w in
                    Text("每周" + ["日", "一", "二", "三", "四", "五", "六"][w - 1]).tag(w)
                }
            }
            .labelsHidden().fixedSize()
            Text("这天不打卡不断连续，打了照样算；从今天起生效，不改过去。")
                .font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func makeupRow(_ c: CheckinSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("补签").font(.system(size: 12.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                Text("最近 \(AppDatabase.makeupWindowDays) 天里做过检查、忘了写日评的日子；本月还剩 \(c.makeupLeft) 次")
                    .font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
            HStack(spacing: 8) {
                ForEach(c.makeupDays, id: \.self) { day in
                    Button(StreakBreakPrompt.label(day)) { makeupDay = day; makeupScore = nil; makeupNote = ""; makeupError = nil }
                        .controlSize(.small).handCursor()
                }
            }
            if let day = makeupDay {
                HStack(spacing: 6) {
                    Text("补 \(StreakBreakPrompt.label(day)) 的自评").font(.system(size: 12))
                    ForEach(SelfScore.allCases) { s in
                        Button("\(s.rawValue)") { makeupScore = s }
                            .controlSize(.small)
                            .background(makeupScore == s ? ReviewPalette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .help(s.title).handCursor()
                    }
                }
                TextField("那天的一句话（可不填）", text: $makeupNote).textFieldStyle(.roundedBorder)
                HStack {
                    Button("补签") {
                        guard let s = makeupScore else { return }
                        makeupError = store.makeUpCheckin(day: day, score: s, note: makeupNote)
                        if makeupError == nil { makeupDay = nil }
                    }
                    .disabled(makeupScore == nil).handCursor()
                    Button("取消") { makeupDay = nil }.handCursor()
                    if let makeupError { Text(makeupError).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.pending) }
                }
            }
        }
    }
}

/// 一年打卡热力图：深浅按自评分；旧记录为中性色，补签为空心格，休息日浅灰；悬停看当天的完成、掌握、自评与一句话
struct CheckinHeatmap: View {
    let summary: CheckinSummary
    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    @State private var restDays: [RestDayChange] = []
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let cal = ReviewHeatmap.calendar()
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let count = max(4, min(53, Int((geo.size.width - 22) / (Self.cell + Self.gap))))
                grid(weeks: ReviewHeatmap.weeks(end: Date(), count: count, calendar: cal), calendar: cal)
            }
            .frame(height: 7 * (Self.cell + Self.gap) + 18)
            HStack(spacing: 6) {
                Text("自评低").foregroundStyle(ReviewPalette.sub)
                ForEach(1...5, id: \.self) { s in swatch(fill: ReviewPalette.done.opacity(Self.opacity(s)), stroke: nil) }
                Text("高").foregroundStyle(ReviewPalette.sub)
                swatch(fill: ReviewPalette.sub.opacity(0.45), stroke: nil).padding(.leading, 8)
                Text("旧记录").foregroundStyle(ReviewPalette.sub)
                swatch(fill: .clear, stroke: ReviewPalette.done)
                Text("补签").foregroundStyle(ReviewPalette.sub)
                swatch(fill: ReviewPalette.hair.opacity(0.5), stroke: ReviewPalette.hair)
                Text("休息日").foregroundStyle(ReviewPalette.sub)
            }
            .font(.system(size: 11))
        }
        .task(id: summary.restWeekday) { restDays = (try? store.db.restDayChanges()) ?? [] }
    }

    static func opacity(_ score: Int) -> Double { [0.25, 0.25, 0.42, 0.6, 0.8, 1][max(0, min(5, score))] }

    private func swatch(fill: Color, stroke: Color?) -> some View {
        RoundedRectangle(cornerRadius: 2.5).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(stroke ?? .clear, lineWidth: 1.2))
            .frame(width: Self.cell, height: Self.cell)
    }

    private func grid(weeks: [[Date?]], calendar: Calendar) -> some View {
        let labels = ReviewHeatmap.monthLabels(weeks, calendar: calendar)
        let step = Self.cell + Self.gap
        return HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(height: 18)
                ForEach(0..<7, id: \.self) { i in
                    Text(["一", "", "三", "", "五", "", "日"][i]).font(.system(size: 9)).foregroundStyle(ReviewPalette.sub)
                        .frame(width: 14, height: step, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                        if let label {
                            Text(label).font(.system(size: 9.5)).foregroundStyle(ReviewPalette.sub).fixedSize().offset(x: CGFloat(i) * step)
                        }
                    }
                }
                .frame(height: 18, alignment: .topLeading)
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { r in cell(col[r], calendar: calendar) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ date: Date?, calendar: Calendar) -> some View {
        if let date {
            let key = ReviewHeatmap.dayKey(date, calendar: calendar)
            let day = summary.days[key]
            let rest = day == nil && AppDatabase.isRestDay(key, changes: restDays)
            let isToday = key == summary.today
            RoundedRectangle(cornerRadius: 2.5)
                .fill(fill(day, rest: rest))
                .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(day?.status == .makeup ? ReviewPalette.done : (isToday ? ReviewPalette.ink.opacity(0.5) : .clear), lineWidth: 1.2))
                .frame(width: Self.cell, height: Self.cell)
                .help(Self.tooltip(key, day: day, rest: rest))
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }

    private func fill(_ day: CheckinDay?, rest: Bool) -> Color {
        guard let day else { return rest ? ReviewPalette.hair.opacity(0.5) : ReviewPalette.hair }
        switch day.status {
        case .legacy: return ReviewPalette.sub.opacity(0.45)
        case .makeup: return .clear
        case .checked: return ReviewPalette.done.opacity(Self.opacity(day.selfScore ?? 3))
        }
    }

    static func tooltip(_ key: String, day: CheckinDay?, rest: Bool) -> String {
        let date = StreakBreakPrompt.label(key)
        guard let day else { return date + (rest ? "：休息日" : "：没有打卡") }
        var parts = [date + (day.status == .legacy ? "：旧记录（5.2.2 之前学过）" : day.status == .makeup ? "：补签" : "：已打卡")]
        if day.due > 0 { parts.append("完成 \(day.done)/\(day.due)") }
        if let r = day.mastery.ratio { parts.append("掌握 \(DailyScoreSection.percent(r))") }
        if let s = day.selfScore { parts.append("自评 \(s)") }
        var text = parts.joined(separator: " · ")
        if !day.note.isEmpty { text += "\n" + day.note }
        return text
    }
}
