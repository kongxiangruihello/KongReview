import SwiftUI
import Observation
import KongReviewCore

/// 出处管理表格的一行
struct SourceRow: Identifiable, Hashable {
    let id: Int64
    let source: Source
    let count: Int
    var title: String { source.title }
    var author: String { source.author }
    var kindLabel: String { source.kind.label }
    var createdAt: Date { source.createdAt }
}

/// 出处管理页的局部状态（不能用 @State，见 ViewState.swift）
@MainActor
@Observable
final class SourceManagerState {
    static let shared = SourceManagerState()
    var selection: Set<Int64> = []
    var filter = ""
    var onlyDuplicates = false
    var sortOrder: [KeyPathComparator<SourceRow>] = [KeyPathComparator(\.count, order: .reverse)]
}

struct SourceManagerView: View {
    @Environment(LibraryStore.self) private var store
    private var ui: SourceManagerState { SourceManagerState.shared }

    var body: some View {
        let _ = store.revision
        let all = ((try? store.db.sourcesWithCounts()) ?? []).compactMap { pair in
            pair.source.id.map { SourceRow(id: $0, source: pair.source, count: pair.count) }
        }
        let dupIDs = Set(SourceDedup.duplicateGroups(all.map(\.source)).flatMap { $0 })
        let q = ui.filter.trimmingCharacters(in: .whitespaces)
        var rows = all.filter { r in
            (q.isEmpty || r.title.localizedCaseInsensitiveContains(q) || r.author.localizedCaseInsensitiveContains(q))
                && (!ui.onlyDuplicates || dupIDs.contains(r.id))
        }
        if ui.onlyDuplicates {
            // 疑似重复的按归一化书名排在一起
            rows.sort { SourceDedup.key($0.title) == SourceDedup.key($1.title) ? $0.count > $1.count : SourceDedup.key($0.title) < SourceDedup.key($1.title) }
        } else {
            rows.sort(using: ui.sortOrder)
        }
        let selected = Array(ui.selection)

        return Table(rows, selection: Bindable(ui).selection, sortOrder: Bindable(ui).sortOrder) {
            TableColumn("书名 / 篇名", value: \.title) { r in
                HStack(spacing: 4) {
                    if dupIDs.contains(r.id) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("可能与其他出处重复")
                    }
                    Text(r.title).lineLimit(1)
                }
            }
            .width(min: 220, ideal: 360)
            TableColumn("作者", value: \.author) { r in Text(r.author).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("类型", value: \.kindLabel) { r in Text(r.kindLabel) }
                .width(70)
            TableColumn("摘录", value: \.count) { r in Text("\(r.count)").monospacedDigit() }
                .width(60)
            TableColumn("添加时间", value: \.createdAt) { r in
                Text(r.createdAt.formatted(date: .numeric, time: .omitted))
            }
            .width(100)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(Array(ids))
        } primaryAction: { ids in
            if let id = ids.first { store.selection = .source(id) }
        }
        .navigationTitle("出处管理")
        .navigationSubtitle("\(rows.count) 个出处" + (dupIDs.isEmpty ? "" : " · 疑似重复 \(dupIDs.count) 个") + (selected.isEmpty ? "" : " · 已选 \(selected.count) 个"))
        .searchable(text: Bindable(ui).filter, prompt: "搜索书名、作者")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: Bindable(ui).onlyDuplicates) {
                    Label("只看疑似重复", systemImage: "square.on.square")
                }
                .help("书名去掉空格、标点和括注后相同的出处")
            }
            ToolbarItem {
                Menu {
                    menu(selected)
                } label: {
                    Label("操作", systemImage: "ellipsis.circle")
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func menu(_ ids: [Int64]) -> some View {
        if ids.count == 1, let s = store.sources.first(where: { $0.id == ids[0] }) {
            Button("查看摘录") { store.selection = .source(ids[0]) }
            Button("编辑出处…") { store.editingSource = s }
        }
        if ids.count >= 2 {
            Button("合并这 \(ids.count) 个出处…") { store.requestMerge(ids) }
        }
        Button(ids.count == 1 ? "生成参考文献条目…" : "生成参考文献表（\(ids.count) 种）…") {
            store.showBibliography(sourceIDs: ids, title: "出处管理")
        }
        Menu("类型改为") {
            ForEach(SourceKind.allCases, id: \.self) { k in
                Button(k.label) { store.setKind(k, for: ids) }
            }
        }
        Divider()
        Button("删除出处（保留摘录）…", role: .destructive) {
            store.sourcesPendingDeletion = store.sources.filter { ids.contains($0.id ?? -1) }
        }
    }
}

/// 合并出处：选择保留哪一个
struct MergeSourcesView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let m = store.mergeRequest {
            VStack(alignment: .leading, spacing: 12) {
                Text("合并 \(m.sources.count) 个出处").font(.title2.bold())
                Text("选择要保留的出处。其余出处的摘录和网页存档都会转到它名下，它缺少的书目信息（出版者、年份等）会用其余出处的补上，然后删除其余出处。合并前会自动备份。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("保留", selection: Binding(
                    get: { store.mergeRequest?.target ?? m.target },
                    set: { store.mergeRequest?.target = $0 }
                )) {
                    ForEach(m.sources) { pair in
                        Text("\(pair.source.title)\(pair.source.author.isEmpty ? "" : " · " + pair.source.author)（\(pair.count) 条）")
                            .tag(pair.source.id ?? -1)
                    }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { store.mergeRequest = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("合并") { store.commitMerge() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 520)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
