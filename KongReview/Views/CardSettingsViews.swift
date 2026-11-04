import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 牌组选项

/// 每个牌组自己的每日上限、排程算法与期望保留率
struct DeckOptionsView: View {
    @Environment(LibraryStore.self) private var store

    private func binding<T>(_ kp: WritableKeyPath<DeckOptions, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { store.deckOptionsEditor?[keyPath: kp] ?? fallback },
                set: { store.deckOptionsEditor?[keyPath: kp] = $0 })
    }

    /// nil = 跟随全局；用开关 + 步进器表示
    private func limitRow(_ title: String, _ kp: WritableKeyPath<DeckOptions, Int?>, global: Int, step: Int) -> some View {
        let value = store.deckOptionsEditor?[keyPath: kp]
        return HStack {
            Toggle(title, isOn: Binding(
                get: { value != nil },
                set: { on in store.deckOptionsEditor?[keyPath: kp] = on ? (value ?? global) : nil }
            ))
            Spacer()
            if let v = value {
                DailyLimitNumberField(value: Binding(get: { v }, set: { store.deckOptionsEditor?[keyPath: kp] = $0 }),
                                      step: step)
            } else {
                Text("跟随全局（\(global)）").foregroundStyle(.secondary)
            }
        }
    }

    /// 设了全库合计时提醒：这个牌组的上限之外还受合计约束
    private var totalNote: String? {
        let parts = [CardSettings.totalNewPerDay.map { "新卡 \($0)" }, CardSettings.totalReviewsPerDay.map { "复习 \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : "同时受全库每天合计（\(parts.joined(separator: "、"))）约束；在“每日学习量”里调整。"
    }

    var body: some View {
        let o = store.deckOptionsEditor
        return VStack(alignment: .leading, spacing: 14) {
            Text("牌组选项").font(.title2.bold())
            Text(o?.deck ?? "").foregroundStyle(.secondary)
            Form {
                Section("新建卡片的录入模板") {
                    Button("设置此牌组的录入模板…") { store.deckEntryPresetEditor = .init(deck:o?.deck ?? "默认") }
                }
                Section("每日上限") {
                    limitRow("单独设置每天新卡数", \.newPerDay, global: CardSettings.newPerDay, step: 5)
                    limitRow("单独设置每天复习上限", \.reviewsPerDay, global: CardSettings.reviewsPerDay, step: 10)
                    if let total = totalNote {
                        Text(total).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("排程算法") {
                    Picker("算法", selection: binding(\.algorithm, .sm2)) {
                        ForEach(DeckOptions.Algorithm.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if o?.algorithm == .fsrs {
                        HStack {
                            Text("期望记忆保留率")
                            Slider(value: binding(\.desiredRetention, 0.9), in: 0.75...0.97, step: 0.01)
                            Text("\(Int(((o?.desiredRetention ?? 0.9) * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        }
                        Text("到期时大约能记住多少。设得越高复习越频繁：90% 是 Anki 的默认值；95% 的复习量约为 90% 的两倍。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(CardSettings.fsrsIsDefault ? "参数：FSRS-6 默认参数（可在“设置 → 记忆卡”里用复习记录优化）"
                                                        : "参数：已用你的复习记录优化（\(CardSettings.fsrsInfo ?? "")）")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("SM-2：学习步长 1 分钟、10 分钟，毕业 1 天，简单 4 天，起始难度系数 250%。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("从 SM-2 改为 FSRS 时，会按复习记录算出每张卡的记忆状态；已排好的到期日不变。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("取消", role: .cancel) { store.deckOptionsEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { if let o = store.deckOptionsEditor { store.saveDeckOptions(o) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .modifier(DeckEntryPresetPresentation(host:.options))
    }
}

// MARK: - 卡片模板（多字段笔记类型）
//
// 6.0.0：两种方式——“放置”（字段放正面、背面或折叠）与“HTML”（正面模板、背面模板、样式，写法同 Anki）。
// 写了 HTML 就以 HTML 为准；右侧用这类卡片中的一张实时预览，可换一张。

struct NoteTemplateEditorView: View {
    @Environment(LibraryStore.self) private var store

    enum Placement: String, CaseIterable, Identifiable {
        case front = "正面", back = "背面", collapsed = "背面·折叠", hidden = "不显示"
        var id: String { rawValue }
    }

    enum CodeTab: String, CaseIterable, Identifiable {
        case front = "正面", back = "背面", css = "样式"
        var id: String { rawValue }
    }

    @State private var tab: CodeTab = .front
    @State private var samples: [Card] = []
    @State private var sampleIndex = 0
    @State private var inserter = TemplateCodeInserter()

    private func placement(_ t: NoteTemplate, _ i: Int) -> Placement {
        if t.front.contains(i) { return .front }
        if t.back.contains(i) { return t.collapsed.contains(i) ? .collapsed : .back }
        return .hidden
    }

    private func setPlacement(_ p: Placement, _ i: Int) {
        guard var t = store.templateEditor else { return }
        t.front.removeAll { $0 == i }
        t.back.removeAll { $0 == i }
        t.collapsed.removeAll { $0 == i }
        switch p {
        case .front: t.front.append(i)
        case .back: t.back.append(i)
        case .collapsed: t.back.append(i); t.collapsed.append(i)
        case .hidden: break
        }
        t.front.sort(); t.back.sort(); t.collapsed.sort()
        store.templateEditor = t
    }

    /// 改 HTML 的三栏之一
    private func codeBinding(_ which: CodeTab) -> Binding<String> {
        Binding(get: {
            guard let h = store.templateEditor?.html else { return "" }
            switch which { case .front: return h.front; case .back: return h.back; case .css: return h.css }
        }, set: { v in
            guard var t = store.templateEditor, var h = t.html else { return }
            switch which { case .front: h.front = v; case .back: h.back = v; case .css: h.css = v }
            t.html = h
            store.templateEditor = t
        })
    }

    private var usesHTML: Binding<Bool> {
        Binding(get: { store.templateEditor?.html != nil }, set: { on in
            guard var t = store.templateEditor else { return }
            t.html = on ? (t.html ?? CardTemplateEngine.html(from: t)) : nil
            store.templateEditor = t
        })
    }

    /// HTML 模板里的问题（有就不让保存）
    private func issues(_ t: NoteTemplate) -> [String] {
        guard let h = t.html else { return t.front.isEmpty ? ["正面至少要放一个字段"] : [] }
        let f = CardTemplateEngine.issues(h.front, fieldNames: t.fieldNames, side: .front).map { "正面：" + $0 }
        let b = CardTemplateEngine.issues(h.back, fieldNames: t.fieldNames, side: .back).map { "背面：" + $0 }
        var all = f + b
        if h.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { all.insert("正面模板是空的", at: 0) }
        return all
    }

    var body: some View {
        let t = store.templateEditor
        let count = t.flatMap { try? store.db.cardCount(noteType: $0.name) } ?? 0
        let problems = t.map(issues) ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("卡片模板").font(.title2.bold())
                Text("笔记类型“\(t?.name ?? "")”，\(count) 张卡。改动只影响显示，不改卡片内容。")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: usesHTML) {
                    Text("放置").tag(false)
                    Text("HTML").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if t?.html != nil { htmlColumn(t!) } else { placementColumn(t) }
                }
                .frame(width: 400)
                previewColumn(t)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .font(.caption)
            }
            HStack {
                Button("恢复默认") {
                    if let t = store.templateEditor {
                        store.templateEditor = NoteTemplate.defaultTemplate(name: t.name, fieldNames: t.fieldNames, isCloze: t.isCloze)
                    }
                }
                .help("回到默认的放置（第一个字段在正面，其余在背面），不用 HTML")
                Spacer()
                Button("取消", role: .cancel) { store.templateEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { if let t = store.templateEditor { store.saveTemplate(t) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 620)
        .task(id: t?.name) {
            samples = (try? store.db.sampleCards(noteType: t?.name ?? "", limit: 8)) ?? []
            sampleIndex = 0
        }
    }

    private func placementColumn(_ t: NoteTemplate?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t {
                ForEach(Array(t.fieldNames.enumerated()), id: \.offset) { i, name in
                    HStack {
                        Text(name).frame(width: 120, alignment: .leading)
                        Picker("", selection: Binding(get: { placement(t, i) }, set: { setPlacement($0, i) })) {
                            ForEach(Placement.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
            }
            Text("正面放要回想的内容（如正文），背面放答案；注释这类长内容放“背面·折叠”，需要时点开。要改格式，切到右上角的“HTML”。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func htmlColumn(_ t: NoteTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) { ForEach(CodeTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if tab != .css {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("插入：").font(.caption).foregroundStyle(.secondary)
                        ForEach(t.fieldNames, id: \.self) { name in
                            Button(name) { inserter.insert("{{\(name)}}") }.controlSize(.small)
                        }
                        if tab == .back { Button("FrontSide") { inserter.insert("{{FrontSide}}") }.controlSize(.small) }
                        Menu("更多") {
                            ForEach(t.fieldNames, id: \.self) { name in
                                Button("有“\(name)”时才显示") { inserter.insert("{{#\(name)}}\n\n{{/\(name)}}") }
                            }
                            Divider()
                            ForEach(t.fieldNames, id: \.self) { name in
                                Button("“\(name)”作提示") { inserter.insert("{{hint:\(name)}}") }
                            }
                            if t.isCloze, let first = t.fieldNames.first {
                                Divider()
                                Button("完形填空：\(first)") { inserter.insert("{{cloze:\(first)}}") }
                            }
                        }
                        .controlSize(.small).fixedSize()
                    }
                }
            }
            TemplateCodeEditor(text: codeBinding(tab), inserter: inserter)
                .id(tab)
                .frame(minHeight: 360)
                .border(Color.secondary.opacity(0.3))
            Text(tab == .css
                 ? "样式（CSS）作用于这类卡片的正反面，加在默认样式之后；可用 .kr-field、.kr-label、.cloze、.kr-hint 等类名。"
                 : "写法同 Anki：{{字段}}、{{#字段}}…{{/字段}}（有内容才显示）、{{^字段}}…{{/字段}}（为空才显示）、{{cloze:字段}}、{{hint:字段}}、{{text:字段}}。背面的 {{FrontSide}} 不重复显示正面。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewColumn(_ t: NoteTemplate?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("预览").font(.headline)
                if samples.count > 1 {
                    Text("第 \(sampleIndex + 1) / \(samples.count) 张").font(.caption).foregroundStyle(.secondary)
                    Button("换一张") { sampleIndex = (sampleIndex + 1) % samples.count }.controlSize(.small)
                }
                Spacer()
            }
            if let t, samples.indices.contains(sampleIndex) {
                let f = t.render(samples[sampleIndex].fields)
                CardWebView(front: f.front, back: f.back, store: store, css: t.html != nil ? t.css : store.plainCardCSS)
                    .background(Color(nsColor: .textBackgroundColor))
                    .border(Color.secondary.opacity(0.3))
            } else {
                Text("没有可预览的卡片").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 6.0.0：普通卡片样式

/// 没有 HTML 模板的卡片（只有正面、背面，或用“放置”的多字段卡片）共用的样式
struct PlainCardStyleEditorView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var css = ""
    @State private var sample: Card?
    @State private var inserter = TemplateCodeInserter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("普通卡片样式").font(.title2.bold())
            Text("作用于所有没有 HTML 模板的卡片，加在默认样式之后。改样式只影响显示，不改卡片内容。")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TemplateCodeEditor(text: $css, inserter: inserter)
                        .frame(minHeight: 360)
                        .border(Color.secondary.opacity(0.3))
                    Text("例：.face { font-size: 24px; } 或 .back { color: #7A5C3E; }；深色模式另写在 @media (prefers-color-scheme: dark) { … } 里，否则深色底上可能看不清。可用的类名：.face（正面）、.back（背面）、.kr-field、.kr-label、.cloze。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 400)
                VStack(alignment: .leading, spacing: 6) {
                    Text("预览").font(.headline)
                    if let c = sample {
                        let f = store.faces(of: c)
                        CardWebView(front: f.front, back: f.back, store: store, css: css)
                            .background(Color(nsColor: .textBackgroundColor))
                            .border(Color.secondary.opacity(0.3))
                    } else {
                        CardWebView(front: "学而时习之，不亦说乎？", back: "出自《论语·学而》。", store: store, css: css)
                            .background(Color(nsColor: .textBackgroundColor))
                            .border(Color.secondary.opacity(0.3))
                    }
                }
            }
            HStack {
                Button("清空") { css = "" }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { store.savePlainCardCSS(css); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            css = store.plainCardCSS
            sample = try? store.db.samplePlainCard()
        }
    }
}

/// 代码编辑框（等宽、不自动替换引号），可在光标处插入
@MainActor
final class TemplateCodeInserter {
    weak var textView: NSTextView?
    func insert(_ s: String) {
        guard let v = textView else { return }
        v.window?.makeFirstResponder(v)
        v.insertText(s, replacementRange: v.selectedRange())
    }
}

struct TemplateCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let inserter: TemplateCodeInserter

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let v = scroll.documentView as? NSTextView else { return scroll }
        v.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        v.isRichText = false
        v.allowsUndo = true
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.isAutomaticTextReplacementEnabled = false
        v.isAutomaticSpellingCorrectionEnabled = false
        v.isContinuousSpellCheckingEnabled = false
        v.textContainerInset = NSSize(width: 6, height: 8)
        v.string = text
        v.delegate = context.coordinator
        inserter.textView = v
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let v = scroll.documentView as? NSTextView else { return }
        inserter.textView = v
        if v.string != text { v.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TemplateCodeEditor
        init(_ p: TemplateCodeEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let v = n.object as? NSTextView else { return }
            parent.text = v.string
        }
    }
}

// MARK: - 导出到 Anki

struct ApkgExportView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let r = store.apkgExport
        return VStack(alignment: .leading, spacing: 12) {
            Text("导出到 Anki").font(.title2.bold())
            Text("生成 .apkg 牌组包。在 iPhone / iPad 的 AnkiMobile、安卓的 AnkiDroid 或 Anki 桌面版里导入即可复习。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("牌组").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r?.allDecks ?? [], id: \.self) { d in
                        Toggle(d, isOn: Binding(
                            get: { store.apkgExport?.decks.contains(d) ?? false },
                            set: { on in
                                if on { store.apkgExport?.decks.insert(d) } else { store.apkgExport?.decks.remove(d) }
                            }))
                    }
                }
            }
            .frame(maxHeight: 180)
            Toggle("带上复习进度（间隔、到期日、FSRS 记忆状态与复习记录）", isOn: Binding(
                get: { store.apkgExport?.includeScheduling ?? true },
                set: { store.apkgExport?.includeScheduling = $0 }))
            Text("""
                • 每张卡导出为“KongReview”笔记类型（正面 / 背面），内容就是这里显示的样子（多字段卡片按模板拼好，图片一并带上）。
                • 从 Anki 导入过来的卡保留原来的笔记 ID：导回原来的 Anki 时，已有的笔记不会重复。
                • 导出是单向的：在手机上复习的进度不会自动回到 KongReview。
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.apkgExport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导出…") { if let r = store.apkgExport { ExportService.exportApkg(r, store: store) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(r?.decks.isEmpty ?? true)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
