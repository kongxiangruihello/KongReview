import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 5.0.2：自测、本周进展、学问检视、问题的经过

/// 每周自测：出处题、要点题、论证题共 10 题；先想，再展开对照，自评 1 记得、2 大致、3 忘了
struct SelfTestView: View {
    @Environment(LibraryStore.self) private var store
    @State private var set = SelfTestSet()
    @State private var results: [SelfTestItem: SelfTestResult] = [:]
    @State private var loaded = false
    @State private var revealed = false
    @State private var redo: SelfTestItem?

    private var week: GrowthWindow { GrowthPeriod.week.window(containing: Date()) }
    private var current: SelfTestItem? { redo ?? set.items.first { results[$0] == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
                else if set.items.isEmpty { empty }
                else if let item = current { SelfTestCard(item: item, revealed: $revealed) { r in grade(item, r) }.id(item) }
                else { summary }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("自测")
        .task(id: "\(week.key)|\(store.today)") {
            set = (try? store.db.selfTestSet(week: week)) ?? SelfTestSet()
            results = (try? store.db.selfTestResults(week: week)) ?? [:]
            loaded = true
        }
    }

    private func grade(_ item: SelfTestItem, _ r: SelfTestResult) {
        store.recordSelfTest(item, r, week: week)
        results[item] = r
        redo = nil
        revealed = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("本周自测").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if loaded && !set.items.isEmpty {
                    let done = set.items.filter { results[$0] != nil }.count
                    Text("已做 \(done) / \(set.items.count) 题").font(.system(size: 13).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Button { store.openReflection(period: .week, date: week.start) } label: { Label("每周复盘", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless).font(.system(size: 12)).handCursor()
            }
            Text("先回忆，再对照：先想后看比重读记得牢，也让人知道自己哪里其实没记住。每题自评 1 记得、2 大致、3 忘了，不计分。")
                .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        ReviewCardContainer(padding: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有可以自测的材料").font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text("题目从收藏、写过按语、被札记引用或属于当前项目的摘录（有出处、还没做成记忆卡）以及引用了摘录的札记中抽取；近 28 天测过的不再抽。")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: set.items.compactMap { results[$0] }, by: { $0 }).mapValues(\.count)
        let forgot = set.items.filter { results[$0] == .forgot }
        return VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本周自测做完了").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("记得 \(counts[.remembered] ?? 0) 题，大致 \(counts[.partly] ?? 0) 题，忘了 \(counts[.forgot] ?? 0) 题。")
                        .font(.system(size: 14)).foregroundStyle(ReviewPalette.ink)
                    HStack(spacing: 10) {
                        PillButton(icon: "arrow.triangle.2.circlepath", title: "接着做每周复盘", style: .primary) { store.openReflection(period: .week, date: week.start) }
                        PillButton(icon: "house", title: "回到首页") { store.selection = .home }
                    }
                }
            }
            if !forgot.isEmpty {
                ReviewCardContainer(padding: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("忘了的").font(.system(size: 15, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                        Text("做成记忆卡，或在每日回顾中多出现；札记可打开重读。").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
                        ForEach(forgot, id: \.self) { item in ForgotRow(item: item) { redo = item; revealed = false } }
                    }
                }
            }
        }
    }
}

/// 一道题
private struct SelfTestCard: View {
    @Environment(LibraryStore.self) private var store
    let item: SelfTestItem
    @Binding var revealed: Bool
    let grade: (SelfTestResult) -> Void
    @State private var highlight: Highlight?
    @State private var note: IdeaNote?
    @State private var cited: [Highlight] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Label(item.kind.title, systemImage: item.kind == .argument ? "lightbulb" : "text.quote")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                    prompt
                    if revealed {
                        Divider()
                        answer
                    } else {
                        PillButton(icon: "chevron.down", title: "想好了，展开对照", key: "空格") { revealed = true }
                            .keyboardShortcut(.space, modifiers: [])
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach([SelfTestResult.remembered, .partly, .forgot], id: \.rawValue) { r in
                    PillButton(title: r.title, key: "\(r.rawValue)", style: r == .remembered ? .primary : .normal) { grade(r) }
                        .keyboardShortcut(KeyEquivalent(Character("\(r.rawValue)")), modifiers: [])
                }
                Spacer()
            }
        }
        .task(id: item) { load() }
    }

    private func load() {
        if item.kind == .argument {
            note = try? store.db.ideaNote(id: item.recordId)
            let ids = (try? store.db.notebookIdeaNotes(ids: [item.recordId]))?[item.recordId]?.highlightIDs ?? []
            cited = (try? store.db.highlights(ids: Array(ids.prefix(4)))) ?? []
        } else {
            highlight = try? store.db.highlights(ids: [item.recordId]).first
        }
    }

    private func plain(_ html: String) -> String {
        Markdown.plainText(fromHTML: Markdown.richHTML(html)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cite(_ h: Highlight) -> String {
        let s = store.source(for: h)
        return [s?.author ?? "", s.map { "《\($0.title)》" } ?? "", h.location ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder
    private var prompt: some View {
        switch item.kind {
        case .source:
            if let h = highlight {
                Text(plain(h.text)).font(.system(size: 18, design: .serif)).foregroundStyle(ReviewPalette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("这段话出自哪本书？作者是谁？大致在什么位置？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
        case .gist:
            if let h = highlight {
                Text(cite(h)).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if let n = h.note, !plain(n).isEmpty {
                    Text("按语：" + plain(n)).font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("这一处原文说了什么？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
        case .argument:
            Text(note?.title ?? "").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
            Text("为什么这么看？依据是哪些摘录？").font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.ink)
        }
    }

    @ViewBuilder
    private var answer: some View {
        switch item.kind {
        case .source:
            if let h = highlight { Text(cite(h)).font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.accent) }
        case .gist:
            if let h = highlight {
                Text(plain(h.text)).font(.system(size: 17, design: .serif)).foregroundStyle(ReviewPalette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .argument:
            if let n = note {
                Text(plain(WikiLinks.plain(n.body))).font(.system(size: 14)).foregroundStyle(ReviewPalette.ink).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(cited, id: \.id) { h in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(plain(h.text).prefix(120))).font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text(cite(h)).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(ReviewPalette.hair).frame(width: 2) }
            }
        }
    }
}

/// 忘了的一题：做卡、多出现、打开札记、再做一次
private struct ForgotRow: View {
    @Environment(LibraryStore.self) private var store
    let item: SelfTestItem
    let again: () -> Void
    @State private var highlight: Highlight?
    @State private var title = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
            Spacer(minLength: 8)
            if let h = highlight {
                Button("做成记忆卡") { store.makeCard(from: h) }.disabled(store.cardHighlightIDs.contains(h.id ?? -1))
                Button("多出现") { store.setFrequency(1, for: h) }.disabled(h.frequency == 1)
            } else {
                Button("打开札记") { store.selection = .ideaNote(item.recordId) }
            }
            Button("再做一次", action: again)
        }
        .controlSize(.small)
        .task(id: item) {
            if item.kind == .argument {
                title = "札记《" + ((try? store.db.ideaNote(id: item.recordId))?.title ?? "") + "》"
            } else if let h = try? store.db.highlights(ids: [item.recordId]).first {
                highlight = h
                title = String(Markdown.plainText(fromHTML: Markdown.richHTML(h.text)).prefix(60))
            }
        }
    }
}

// MARK: - 首页“本周进展”

struct ProgressHomeCard: View {
    @Environment(LibraryStore.self) private var store
    @State private var events: [ProgressEvent] = []
    @State private var tested = 0
    @State private var total = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("本周进展").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Text(events.isEmpty ? "还没有记下" : "\(events.count) 件").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                Spacer()
                Button { store.openSelfTest() } label: {
                    Label(total > 0 && tested >= total ? "本周自测已做完" : (tested > 0 ? "继续自测 \(tested)/\(total)" : "做本周自测"), systemImage: "checklist")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderless).handCursor()
            }
            if events.isEmpty {
                Text("问题有了线索或解决、札记修订或第一次被链接、第一次引用某本书、自测从“忘了”到“记得”，都会记在这里。")
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(events.prefix(6)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ReflectionView.day(e.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub).fixedSize().frame(minWidth: 56, alignment: .leading)
                    Text(e.text).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                }
            }
            if events.count > 6 { Text("另有 \(events.count - 6) 件，见每周复盘第一步。").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        .task(id: "\(store.progressRevision)|\(store.today)") {
            let w = GrowthPeriod.week.window(containing: Date())
            events = (try? store.db.progressEvents(start: w.start, end: w.fullEnd)) ?? []
            let results = (try? store.db.selfTestResults(week: w)) ?? [:]
            let set = (try? store.db.progressValue(SelfTestSet.self, key: SelfTestSet.key(w))) ?? nil
            total = set?.items.count ?? 0
            tested = set?.items.filter { results[$0] != nil }.count ?? 0
        }
    }
}

// MARK: - 复盘第一步：本期进展与学问检视

struct ReflectionProgressPanel: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    @State private var events: [ProgressEvent] = []
    @State private var now = Inspection()
    @State private var before = Inspection()
    @State private var selfTestDone = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if window.period == .week && window.fullEnd > Date() && !selfTestDone {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").foregroundStyle(ReviewPalette.accent)
                    Text("本周自测还没做完。先回忆、再对照，约五分钟。").font(.system(size: 13)).foregroundStyle(ReviewPalette.ink)
                    Spacer()
                    Button("先做本周自测") { store.openSelfTest() }.controlSize(.small).handCursor()
                }
                .padding(12)
                .background(ReviewPalette.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            }
            ReviewCardContainer(padding: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本期进展（\(events.count)）").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    if events.isEmpty { Text("本期还没有记下进展。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub) }
                    ForEach(events.prefix(window.period == .week ? 20 : 40)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ReflectionView.day(e.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub).fixedSize().frame(minWidth: 56, alignment: .leading)
                            Text(e.text).font(.system(size: 13)).foregroundStyle(ReviewPalette.ink)
                        }
                    }
                }
            }
            if window.period != .week { inspectionPanel }
        }
        .task(id: "\(window.key)|\(store.progressRevision)|\(store.revision)") {
            events = (try? store.db.progressEvents(start: window.start, end: window.fullEnd, limit: 500)) ?? []
            if window.period == .week && window.fullEnd > Date() {
                let set = (try? store.db.selfTestSet(week: window)) ?? SelfTestSet()
                let results = (try? store.db.selfTestResults(week: window)) ?? [:]
                selfTestDone = set.items.isEmpty || set.items.allSatisfy { results[$0] != nil }
            } else if window.period != .week {
                now = (try? await store.db.inspection(start: window.start, end: window.end)) ?? Inspection()
                before = (try? await store.db.inspection(start: window.previousStart, end: window.previousEnd)) ?? Inspection()
            }
        }
    }

    private func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
    private func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }

    private var inspectionPanel: some View {
        ReviewCardContainer(padding: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("学问检视").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Spacer()
                    if window.period == .year {
                        Button("导出“这一年的学问”（Markdown）…") { exportYear() }.controlSize(.small).handCursor()
                    }
                }
                Text("记得多少、想得多深、问题进展与久未触及的材料；“本期”与上期同期比较，札记与问题的总数为现在的数。")
                    .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                    GridRow { Text("方面"); Text("指标"); Text("本期").gridColumnAlignment(.trailing); Text("上期同期").gridColumnAlignment(.trailing) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                    Divider().gridCellColumns(4)
                    row("记得多少", "自测“记得”的比例（\(now.remembered)/\(now.tested) 题）", pct(now.rememberedRate), pct(before.rememberedRate))
                    row("", "记忆卡保持率", pct(now.cardRetention), pct(before.cardRetention))
                    row("想得多深", "本期修订的札记（条）", "\(now.revisedNotes)", "\(before.revisedNotes)")
                    row("", "札记 \(now.notes) 条，每条平均引用摘录", num(now.notes > 0 ? now.avgCited : nil), "—")
                    row("", "每条平均被链接", num(now.notes > 0 ? now.avgBacklinks : nil), "—")
                    row("问题进展", "本期解决（个）", "\(now.solvedInPeriod)", "\(before.solvedInPeriod)")
                    row("", "平均解决用时（天）", num(now.avgDaysToSolve), num(before.avgDaysToSolve))
                    row("", "现有：待研究 \(now.open) · 有线索 \(now.lead) · 已解决 \(now.solved)", "", "")
                    row("久未触及", "半年未改、未重温的札记", "\(now.untouchedNoteCount)", "—")
                    row("", "半年未新录、未回顾的出处", "\(now.untouchedSources)", "—")
                }
                .font(.system(size: 13).monospacedDigit())
                if !now.untouchedNotes.isEmpty {
                    HStack(spacing: 6) {
                        Text("久未触及的札记：").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                        ForEach(now.untouchedNotes) { n in
                            Button(n.title) { store.selection = .ideaNote(n.id) }.buttonStyle(.link).font(.system(size: 12)).lineLimit(1).handCursor()
                        }
                    }
                }
            }
        }
    }

    private func row(_ aspect: String, _ title: String, _ a: String, _ b: String) -> some View {
        GridRow {
            Text(aspect).foregroundStyle(ReviewPalette.sub)
            Text(title).foregroundStyle(ReviewPalette.ink)
            Text(a).fontWeight(.semibold)
            Text(b).foregroundStyle(ReviewPalette.sub)
        }
    }

    private func exportYear() {
        let w = window
        Task { @MainActor in
            do {
                let md = try await store.db.yearMarkdown(w)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = "\(Calendar.current.component(.year, from: w.start))年的学问.md"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch { store.report(error) }
        }
    }
}

// MARK: - 问题页“经过”

struct QuestionTimelinePanel: View {
    @Environment(LibraryStore.self) private var store
    let questionId: Int64
    @State private var steps: [QuestionStep] = []

    var body: some View {
        ProjectPanel(title: "经过", subtitle: steps.isEmpty ? "" : "\(steps.count) 步") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: s.symbol).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.text).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                            Text(ReflectionView.day(s.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                        }
                    }
                }
            }
        }
        .task(id: "\(questionId)|\(store.questionRevision)") { steps = (try? store.db.questionTimeline(id: questionId)) ?? [] }
    }
}
