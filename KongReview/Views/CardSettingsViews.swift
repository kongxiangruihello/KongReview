import SwiftUI
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
    private func limitRow(_ title: String, _ kp: WritableKeyPath<DeckOptions, Int?>, global: Int, range: ClosedRange<Int>, step: Int) -> some View {
        let value = store.deckOptionsEditor?[keyPath: kp]
        return HStack {
            Toggle(title, isOn: Binding(
                get: { value != nil },
                set: { on in store.deckOptionsEditor?[keyPath: kp] = on ? (value ?? global) : nil }
            ))
            Spacer()
            if let v = value {
                Stepper("\(v)", value: Binding(get: { v }, set: { store.deckOptionsEditor?[keyPath: kp] = $0 }),
                        in: range, step: step)
                    .monospacedDigit()
                    .fixedSize()
            } else {
                Text("跟随全局（\(global)）").foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        let o = store.deckOptionsEditor
        return VStack(alignment: .leading, spacing: 14) {
            Text("牌组选项").font(.title2.bold())
            Text(o?.deck ?? "").foregroundStyle(.secondary)
            Form {
                Section("每日上限") {
                    limitRow("单独设置每天新卡数", \.newPerDay, global: CardSettings.newPerDay, range: 0...9999, step: 5)
                    limitRow("单独设置每天复习上限", \.reviewsPerDay, global: CardSettings.reviewsPerDay, range: 0...9999, step: 10)
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
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

// MARK: - 卡片模板（多字段笔记类型）

struct NoteTemplateEditorView: View {
    @Environment(LibraryStore.self) private var store

    enum Placement: String, CaseIterable, Identifiable {
        case front = "正面", back = "背面", collapsed = "背面·折叠", hidden = "不显示"
        var id: String { rawValue }
    }

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

    var body: some View {
        let t = store.templateEditor
        let sample = t.flatMap { tpl in
            (try? store.db.cards())?.first { $0.noteType == tpl.name && !$0.fields.isEmpty }
        }
        let count = t.flatMap { try? store.db.cardCount(noteType: $0.name) } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("卡片模板").font(.title2.bold())
            Text("笔记类型“\(t?.name ?? "")”，\(count) 张卡。改动只影响显示，不改卡片内容。")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let t {
                        ForEach(Array(t.fieldNames.enumerated()), id: \.offset) { i, name in
                            HStack {
                                Text(name).frame(width: 90, alignment: .leading)
                                Picker("", selection: Binding(get: { placement(t, i) }, set: { setPlacement($0, i) })) {
                                    ForEach(Placement.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 130)
                            }
                        }
                    }
                    Text("正面放要回想的内容（如正文），背面放答案；注释这类长内容放“背面·折叠”，需要时点开。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 6) {
                    Text("预览（用这类卡片中的一张）").font(.headline)
                    if let t, let c = sample {
                        let f = t.render(c.fields)
                        CardWebView(front: f.front, back: f.back, store: store)
                            .background(Color(nsColor: .textBackgroundColor))
                            .border(Color.secondary.opacity(0.3))
                    } else {
                        Text("没有可预览的卡片").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            HStack {
                Button("恢复默认") {
                    if let t = store.templateEditor {
                        store.templateEditor = NoteTemplate.defaultTemplate(name: t.name, fieldNames: t.fieldNames, isCloze: t.isCloze)
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { store.templateEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { if let t = store.templateEditor { store.saveTemplate(t) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(t?.front.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 560)
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
                    .disabled(r?.decks.isEmpty ?? true)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
