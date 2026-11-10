import SwiftUI
import Charts
import KongReviewCore

// MARK: - 6.0.5：成绩册
//
// 日评、打卡、回顾统计、个人成长与复盘合成一本：周报月报（只写一句话）、每天一行、掌握度走势、常错的题、打卡热力图。

struct GradebookView: View {
    @Environment(LibraryStore.self) private var store
    @State private var month = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                MakeupCard()   // 6.3.5
                CheckinStatusStrip()
                StreakBreakPrompt()
                GradebookReportSection()
                GradebookMonthSection(month: $month)
                MasteryTrendSection()
                WeakItemsSection()
                // 6.3：判“记得”而要点写出不到一半的题，点名列出
                OverconfidentSection()
                // 原“回顾统计”里的记忆卡负荷预测、保留率与各牌组统计
                if let insights = store.cardInsights {
                    GradebookCard("记忆卡", subtitle: "未来的复习量、实际保留率、各牌组") {
                        CardInsightsSection(insights: insights)
                        DeckStudySection()
                    }
                }
                CheckinSection()
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("成绩册")
        .onAppear { store.refreshCheckin(); store.refreshCardInsights() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("成绩册").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
                PillButton(icon: "list.clipboard", title: "去做今天的日课", style: .ghost) { store.openExam() }
            }
            Text("每天一行，每周、每月一份报告；看掌握度的走势与常错的题。成绩只作记录，不设目标线。")
                .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 成绩册各节共用的卡片外框与标题
struct GradebookCard<Content: View>: View {
    let title: String
    var subtitle = ""
    var trailing: AnyView
    var content: () -> Content

    init(_ title: String, subtitle: String = "", trailing: AnyView = AnyView(EmptyView()),
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing; self.content = content
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
        }
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 窄时标题一行、按钮另起一行，免得按钮被挤掉
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleLine
                    Spacer(minLength: 12)
                    trailing.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLine
                    trailing.fixedSize()
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ReviewPalette.hair))
    }
}

enum GradebookFormat {
    static func percent(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// 6.2：“写了回答 12 道：对得上 9 道（75%）；判记得而要点不到一半 2 道；判忘了而写出八成以上 1 道”
    static func calibration(_ t: CalibrationTally) -> String {
        guard t.written > 0 else { return "" }
        var parts = ["写了回答 \(t.written) 道：对得上 \(t.fair) 道" + (t.fairRatio.map { "（\(percent($0))）" } ?? "")]
        if t.over > 0 { parts.append("判“记得”而要点写出不到一半 \(t.over) 道（偏高）") }
        if t.under > 0 { parts.append("判“忘了”而写出八成以上 \(t.under) 道（偏低）") }
        return parts.joined(separator: "；")
    }

    static func day(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return key }
        return "\(m)月\(d)日"
    }

    static func weekday(_ key: String) -> String {
        let (start, _) = AppDatabase.bounds(day: key)
        return "周" + ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: start) - 1]
    }

    static func range(_ start: Date, _ endExclusive: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        let last = endExclusive.addingTimeInterval(-1)
        return f.string(from: start) + "–" + f.string(from: last)
    }

    static func title(_ w: GrowthWindow) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: w.start)
        switch w.period {
        case .week: return range(w.start, w.fullEnd)
        case .month: return "\(c.year!)年\(c.month!)月"
        case .year: return "\(c.year!)年"
        case .day: return day(AppDatabase.revisitDay(w.start))
        }
    }

    /// 与上一期相比：比上期多 3 天、比上期少 5 个百分点
    static func delta(_ now: Double?, _ before: Double?, unit: String) -> String? {
        guard let now, let before else { return nil }
        let r = Int(((now - before) * (unit == "个百分点" ? 100 : 1)).rounded())
        if r == 0 { return "与上期持平" }
        return "比上期" + (r > 0 ? "多 " : "少 ") + "\(abs(r)) " + unit
    }

    static func tallyLine(_ t: MasteryTally) -> String {
        t.total == 0 ? "没有作答" : "好 \(t.good) · 中 \(t.mid) · 差 \(t.bad)"
    }
}

// MARK: 周报、月报

struct GradebookReportSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var report: GradebookReport?
    @State private var previous: GradebookReport?
    @State private var remark = ""
    @State private var savedRemark = ""
    @State private var legacy: GrowthReflection?

    private var period: GrowthPeriod { store.reflectionPeriod == .day ? .week : store.reflectionPeriod }
    private var window: GrowthWindow { period.window(containing: store.reflectionDate) }
    private var isCurrent: Bool { window.fullEnd > Date() }

    var body: some View {
        GradebookCard(period == .week ? "周报" : period == .month ? "月报" : "年报",
                      subtitle: GradebookFormat.title(window) + (isCurrent ? "（到今天为止）" : ""),
                      trailing: AnyView(controls)) {
            if let r = report {
                tiles(r)
                details(r)
                remarkField
                if let legacy, !(legacy.gains + legacy.challenges + legacy.nextSteps).isEmpty { legacyView(legacy) }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .task(id: "\(window.key)|\(store.dailyCheckRevision)|\(store.reflectionRevision)|\(store.today)") { load() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { period }, set: { store.reflectionPeriod = $0; store.reflectionDate = Date() })) {
                Text("周报").tag(GrowthPeriod.week)
                Text("月报").tag(GrowthPeriod.month)
                Text("年报").tag(GrowthPeriod.year)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("上一期").handCursor()
            Button { move(1) } label: { Image(systemName: "chevron.right") }.help("下一期").disabled(isCurrent).handCursor()
            if !isCurrent { Button("本期") { store.reflectionDate = Date() }.handCursor() }
        }
        .controlSize(.small)
    }

    private func move(_ n: Int) {
        store.reflectionDate = Calendar.current.date(byAdding: period.component, value: n, to: window.start) ?? Date()
    }

    private func load() {
        let w = window
        report = try? store.db.gradebookReport(w)
        previous = try? store.db.gradebookReport(period.window(containing: w.previousStart))
        let saved = (try? store.db.gradebookRemark(w.key)) ?? ""
        remark = saved; savedRemark = saved
        legacy = try? store.db.progressValue(GrowthReflection.self, key: w.key)
    }

    private func tiles(_ r: GradebookReport) -> some View {
        // 宽时一行四格，窄时两行两格
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            tileViews(r)
        }
    }

    @ViewBuilder private func tileViews(_ r: GradebookReport) -> some View {
        tile("打卡", "\(r.checkinDays) 天", detail: "共 \(r.days) 天" + (GradebookFormat.delta(Double(r.checkinDays), previous.map { Double($0.checkinDays) }, unit: "天").map { " · " + $0 } ?? ""))
        tile("完成度", GradebookFormat.percent(r.completion),
             detail: r.due > 0 ? "已做 \(r.done) / 应做 \(r.due)" + (GradebookFormat.delta(r.completion, previous?.completion, unit: "个百分点").map { " · " + $0 } ?? "") : "这一期没有应做")
        tile("掌握度", GradebookFormat.percent(r.mastery.ratio),
             detail: GradebookFormat.tallyLine(r.mastery) + (GradebookFormat.delta(r.mastery.ratio, previous?.mastery.ratio, unit: "个百分点").map { " · " + $0 } ?? ""))
        tile("平均总分", r.averageTotal.map(String.init) ?? "—",
             detail: r.scoredDays > 0 ? "\(r.scoredDays) 天写了日评" + (r.bestDay.map { " · 最高 \(GradebookFormat.day($0)) \(r.bestTotal ?? 0)" } ?? "") : "写下日评后才有总分")
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
            Text(detail).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func details(_ r: GradebookReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line("各类掌握度", GradeKind.allCases.compactMap { k in
                guard let t = r.byKind[k], t.total > 0 else { return nil }
                return "\(k.title) \(GradebookFormat.percent(t.ratio))（\(t.total)）"
            }.joined(separator: " · "), empty: "这一期还没有作答")
            // 6.2：写了回答的题，自评与要点对照
            line("自评准不准", GradebookFormat.calibration(r.calibration), empty: "这一期写了回答的题还没有")
            line("新加的题", [("摘录", r.newHighlights), ("记忆卡", r.newCards), ("札记", r.newNotes), ("问题", r.newQuestions)]
                .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · "), empty: "没有新加")
            if r.annotatedArticles > 0 || r.annotationMarks > 0 {
                line("标注文章", "\(r.annotatedArticles) 篇，划出摘录 \(r.annotationMarks) 条", empty: "")
            }
            line("小胜", r.winCount > 0 ? "\(r.winCount) 件：" + r.wins.joined(separator: "；") + (r.winCount > r.wins.count ? "……" : "") : "",
                 empty: "没有记下")
            if !r.breaks.isEmpty {
                line("中断", r.breaks.sorted { $0.value > $1.value }.map { "\($0.key.title) \($0.value) 次" }.joined(separator: " · "), empty: "")
            }
        }
    }

    private func line(_ label: String, _ text: String, empty: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ReviewPalette.sub).frame(width: 72, alignment: .leading)
            Text(text.isEmpty ? empty : text).font(.system(size: 13)).foregroundStyle(text.isEmpty ? ReviewPalette.sub : ReviewPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remarkField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这一期一句话").font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
            HStack(spacing: 8) {
                TextField("这一期最要紧的一点：学到的、卡住的、下一期要改的（可不填）", text: $remark)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(savedRemark.isEmpty ? "保存" : "更新", action: save)
                    .disabled(remark.trimmingCharacters(in: .whitespacesAndNewlines) == savedRemark)
                    .handCursor()
            }
        }
    }

    private func save() {
        store.saveGradebookRemark(remark, window: window)
        savedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func legacyView(_ g: GrowthReflection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当时的复盘（6.0.5 以前写的）").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            Text([("收获", g.gains), ("困难", g.challenges), ("下一步", g.nextSteps)].filter { !$0.1.isEmpty }
                .map { $0.0 + "：" + Markdown.plainText(fromHTML: $0.1).trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n"))
                .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: 每日成绩

struct GradebookMonthSection: View {
    @Environment(LibraryStore.self) private var store
    @Binding var month: Date
    @State private var rows: [GradebookDay] = []
    @State private var showsEmpty = false

    private var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        let shown = showsEmpty ? rows : rows.filter { !$0.isEmpty || $0.isToday }
        GradebookCard("每日成绩", subtitle: "\(c.year!)年\(c.month!)月", trailing: AnyView(controls)) {
            if shown.isEmpty {
                Text("这个月还没有记录。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            } else {
                VStack(spacing: 0) {
                    headerRow
                    ForEach(shown) { row($0) }
                }
            }
        }
        .task(id: "\(Calendar.current.component(.month, from: month))|\(Calendar.current.component(.year, from: month))|\(store.dailyCheckRevision)|\(store.today)") {
            rows = (try? store.db.gradebookMonth(containing: month)) ?? []
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Toggle("显示空白的日子", isOn: $showsEmpty).toggleStyle(.checkbox).font(.system(size: 12))
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("上个月").handCursor()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("下个月").disabled(isCurrentMonth).handCursor()
        }
        .controlSize(.small)
    }

    private func shift(_ n: Int) { month = Calendar.current.date(byAdding: .month, value: n, to: month) ?? Date() }

    private var headerRow: some View {
        HStack(spacing: 8) {
            cell("日期", 92, .leading)
            cell("已做 / 应做", 78, .trailing)
            cell("完成", 46, .trailing)
            cell("掌握", 46, .trailing)
            cell("总分", 40, .trailing)
            cell("自评", 36, .trailing)
            Text("一句话").frame(maxWidth: .infinity, alignment: .leading)
            cell("打卡", 44, .center)
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(ReviewPalette.sub)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment)
    }

    private func row(_ d: GradebookDay) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(GradebookFormat.day(d.day)).foregroundStyle(ReviewPalette.ink)
                Text(GradebookFormat.weekday(d.day)).foregroundStyle(ReviewPalette.sub).font(.system(size: 11))
            }
            .frame(width: 92, alignment: .leading)
            cell(d.due > 0 || d.done > 0 ? "\(d.done) / \(d.due)" : "—", 78, .trailing)
            cell(GradebookFormat.percent(d.score.completion), 46, .trailing)
            cell(GradebookFormat.percent(d.score.mastery.ratio), 46, .trailing)
                .help(GradebookFormat.tallyLine(d.score.mastery))
            Text(d.score.total.map(String.init) ?? "—").fontWeight(d.score.total == nil ? .regular : .semibold)
                .frame(width: 40, alignment: .trailing)
            cell(d.score.selfScore.map { "\($0.rawValue)" } ?? "—", 36, .trailing)
                .help(d.score.selfScore?.title ?? "")
            Text(d.score.note.isEmpty ? (d.rest ? "休息日" : "") : d.score.note)
                .foregroundStyle(d.score.note.isEmpty ? ReviewPalette.sub : ReviewPalette.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(d.score.note)
            checkinMark(d).frame(width: 44)
        }
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(ReviewPalette.ink)
        .padding(.vertical, 7)
        .background(d.isToday ? ReviewPalette.accentSoft.opacity(0.5) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
    }

    @ViewBuilder private func checkinMark(_ d: GradebookDay) -> some View {
        switch d.checkin {
        case .checked?: Image(systemName: "checkmark.seal.fill").foregroundStyle(ReviewPalette.done).help("已打卡")
        case .makeup?: Image(systemName: "checkmark.seal").foregroundStyle(ReviewPalette.done).help("补签")
        case .legacy?: Image(systemName: "checkmark").foregroundStyle(ReviewPalette.sub).help("旧记录")
        case nil: Text(d.isToday ? "未打" : "").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
        }
    }
}

// MARK: 掌握度走势

struct MasteryTrendSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var weeks: [MasteryWeek] = []

    private struct Point: Identifiable {
        var id: String { kind + week }
        var kind: String
        var week: String
        var date: Date
        var value: Double
        var count: Int
    }

    var body: some View {
        let points: [Point] = weeks.flatMap { w in
            GradeKind.allCases.compactMap { k in
                guard let t = w.tallies[k], let r = t.ratio else { return nil }
                return Point(kind: k.title, week: w.key, date: w.start, value: r * 100, count: t.total)
            }
        }
        GradebookCard("掌握度走势", subtitle: "近 12 周 · 每周满 5 次作答才画点") {
            if points.isEmpty {
                Text("作答还不够多，满 5 次的周才会画出来。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("周", p.date, unit: .weekOfYear), y: .value("掌握度", p.value))
                        .foregroundStyle(by: .value("材料", p.kind))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("周", p.date, unit: .weekOfYear), y: .value("掌握度", p.value))
                        .foregroundStyle(by: .value("材料", p.kind))
                        .symbolSize(24)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                } }
                .chartForegroundStyleScale(domain: GradeKind.allCases.map(\.title),
                                           range: [ReviewPalette.accent, ReviewPalette.hard, ReviewPalette.easy, ReviewPalette.again, ReviewPalette.ink])
                .frame(height: 200)
            }
            if let last = weeks.last {
                Text("本周：" + GradeKind.allCases.map { k in
                    let t = last.tallies[k] ?? MasteryTally()
                    return "\(k.title) " + (t.total == 0 ? "—" : "\(GradebookFormat.percent(t.ratio))（\(t.total)）")
                }.joined(separator: " · "))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            }
        }
        .task(id: "\(store.dailyCheckRevision)|\(store.today)") { weeks = (try? store.db.masteryTrend()) ?? [] }
    }
}

// MARK: 常错的题

struct WeakItemsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var items: [GradeKind: [WeakItem]] = [:]

    var body: some View {
        let kinds = GradeKind.allCases.filter { !(items[$0] ?? []).isEmpty }
        GradebookCard("常错的题", subtitle: "近 \(AppDatabase.gradebookWeakDays) 天错了两次以上，或最近一次错了") {
            if kinds.isEmpty {
                Text("近来没有常错的题。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(kinds) { k in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(k.title + "（\((items[k] ?? []).count)）").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                            ForEach(items[k] ?? []) { row($0) }
                        }
                    }
                    HStack(spacing: 10) {
                        Text("错的题会照常回到日课上：今天课末再练一次，摘录两天后补练，记忆卡按 FSRS，笔记“需重读”三天后。点题面打开修改；“今天再练”放进今天的课末；反复记不住的摘录可以做成记忆卡。")
                            .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        PillButton(icon: "arrow.uturn.backward.circle", title: "全部今天再练", style: .ghost) { queueAll() }
                            .help("把这里的摘录、札记、笔记都放进今天的课末再练（记忆卡按 FSRS，不另加）")
                    }
                }
            }
        }
        .task(id: "\(store.dailyCheckRevision)|\(store.revision)|\(store.today)") { items = (try? store.db.weakItems()) ?? [:] }
    }

    private func row(_ w: WeakItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { store.openWeakItem(w) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                        if !w.detail.isEmpty { Text(w.detail).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
                    }
                    Spacer()
                    Text("错 \(w.misses) / \(w.attempts) 次").font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(w.lastMissed ? ReviewPalette.pending : ReviewPalette.sub)
                        .help(w.lastMissed ? "最近一次是错的" : "最近一次答对了")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            // 6.0.7：一键处理
            HStack(spacing: 8) {
                if let kind = relearnKind(w.kind) {
                    let queued = store.examRelearn.items.contains { $0.kind == kind && $0.id == w.recordId }
                    Button(queued ? "已排进" : "今天再练") { store.examRelearnAdd(kind, w.recordId) }
                        .disabled(queued)
                        .help("放进今天的课末再练：常规的题答完后出这一道，答对才算过关")
                }
                if w.kind == .highlight {
                    Button("做成记忆卡") { store.batch(.addToMastery, ids: [w.recordId]) }
                        .help("反复记不住的原文，改用记忆卡的作答题来练（牌组“摘录”）")
                    Button("弃置") { store.batch(.discard(true), ids: [w.recordId]) }
                        .help("以后不再出这一条（可在全部摘录里恢复，⌘Z 可撤销）")
                }
            }
            .buttonStyle(.link).font(.system(size: 11.5)).handCursor()
        }
        .padding(.vertical, 3).padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
    }

    private func relearnKind(_ k: GradeKind) -> ExamRelearnItem.Kind? {
        switch k {
        case .highlight: .highlight
        case .note: .note
        case .block: .block
        case .question: .answer
        case .card: nil
        }
    }

    /// 把常错的摘录、札记、笔记都放进今天的卷尾再考
    private func queueAll() {
        for k in [GradeKind.highlight, .note, .block, .question] {
            guard let kind = relearnKind(k) else { continue }
            for w in items[k] ?? [] { store.examRelearnAdd(kind, w.recordId) }
        }
    }
}

/// 6.3：自评偏高的题——近 30 天里最近一次判“记得”、而“我的回答”写出的要点不到一半
struct OverconfidentSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var items: [OverconfidentItem] = []

    var body: some View {
        GradebookCard("自评偏高的题", subtitle: "近 \(AppDatabase.overconfidentDays) 天最近一次判“记得”，写下的回答里要点不到一半") {
            if items.isEmpty {
                Text("近来没有自评偏高的题（只看写了“我的回答”的题）。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { row($0) }
                    HStack(spacing: 10) {
                        Text("自评偏高的人容易过早停止复习（Dunlosky、Rawson，2012）。这些题判了“记得”，写下的回答却没写出多少要点：点题面打开对照，或“今天再练”放进今天的课末。记忆卡按 FSRS 排程，不另加。")
                            .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        PillButton(icon: "arrow.uturn.backward.circle", title: "全部今天再练", style: .ghost) {
                            for w in items { if let k = relearnKind(w.kind) { store.examRelearnAdd(k, w.recordId) } }
                        }
                        .help("把这里的摘录、札记、笔记、解答题都放进今天的课末再练")
                    }
                    .padding(.top, 6)
                }
            }
        }
        .task(id: "\(store.dailyCheckRevision)|\(store.revision)|\(store.today)") { items = (try? store.db.overconfidentItems()) ?? [] }
    }

    private func row(_ w: OverconfidentItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { store.openWeakItem(w.weakItem) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(w.kind.title).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                        if !w.detail.isEmpty { Text(w.detail).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
                    }
                    Spacer()
                    Text("写出 \(w.hits) / \(w.units) 处").font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.pending)
                        .help("最近一次：\(w.at.formatted(.dateTime.month().day().hour().minute()))")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            if let kind = relearnKind(w.kind) {
                let queued = store.examRelearn.items.contains { $0.kind == kind && $0.id == w.recordId }
                Button(queued ? "已排进" : "今天再练") { store.examRelearnAdd(kind, w.recordId) }
                    .disabled(queued).buttonStyle(.link).font(.system(size: 11.5)).handCursor()
                    .help("放进今天的课末再练：常规的题答完后出这一道，答对才算过关")
            }
        }
        .padding(.vertical, 3).padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
    }

    private func relearnKind(_ k: GradeKind) -> ExamRelearnItem.Kind? {
        switch k {
        case .highlight: .highlight
        case .note: .note
        case .block: .block
        case .question: .answer
        case .card: nil
        }
    }
}
