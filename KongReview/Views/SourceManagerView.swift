import SwiftUI
import Observation
import KongReviewCore

/// 出处管理表格的一行
struct SourceRow: Identifiable, Hashable, Sendable {
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
    static let pageSize = 200
    var selection: Set<Int64> = []
    var filter = ""
    var onlyDuplicates = false
    var sortOrder: [KeyPathComparator<SourceRow>] = [KeyPathComparator(\.count, order: .reverse)]
    var items: [SourceRow] = []
    var total = 0
    var page = 1
    var pageInput = "1"
    var isLoading = false
    var duplicateIDs: Set<Int64> = []
    var duplicateCount = 0
    var loadID = UUID()
    var loadedCriteria: SourcePageCriteria?
    var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }

    func goToPage(_ requested: Int) {
        let target = min(max(1, requested), pageCount)
        pageInput = String(target)
        guard target != page else { return }
        loadID = UUID()
        selection = []
        items = []
        isLoading = true
        page = target
    }
}

struct SourcePageCriteria: Hashable {
    var query: String
    var onlyDuplicates: Bool
    var sorts: [SourcePageSort]
}

private struct SourcePageRequest: Hashable {
    var criteria: SourcePageCriteria
    var page: Int
    var revision: Int
}

struct SourceManagerView: View {
    @Environment(LibraryStore.self) private var store
    private var ui: SourceManagerState { store.sourceManager }
    private var request: SourcePageRequest {
        SourcePageRequest(criteria: SourcePageCriteria(
            query: ui.filter.trimmingCharacters(in: .whitespacesAndNewlines),
            onlyDuplicates: ui.onlyDuplicates, sorts: ui.sortOrder.compactMap(SourcePageSort.init)),
                          page: ui.page, revision: store.revision)
    }
    private var selected: [Int64] { visibleIDs(Array(ui.selection)) }

    var body: some View {
        VStack(spacing: 0) {
            sourceTable
            Divider()
            pageControls
        }
        .navigationTitle("出处管理")
        .navigationSubtitle("\(ui.total) 个出处" + (ui.duplicateCount == 0 ? "" : " · 疑似重复 \(ui.duplicateCount) 个") + (selected.isEmpty ? "" : " · 已选 \(selected.count) 个"))
        .searchable(text: Bindable(ui).filter, prompt: "搜索书名、作者")
        .task(id: request) { await loadPage(request) }
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
                .disabled(selected.isEmpty || ui.isLoading)
            }
        }
    }

    private var sourceTable: some View {
        Table(ui.items, selection: Bindable(ui).selection, sortOrder: Bindable(ui).sortOrder) {
            TableColumn("书名 / 篇名", value: \.title) { r in
                HStack(spacing: 4) {
                    if ui.duplicateIDs.contains(r.id) {
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
            menu(visibleIDs(Array(ids)))
        } primaryAction: { ids in
            if !ui.isLoading, let id = visibleIDs(Array(ids)).first { store.selection = .source(id) }
        }
    }

    private var pageControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pageStatus
                Spacer()
                pageNavigation
                pageJump
            }
            VStack(alignment: .leading, spacing: 8) {
                pageStatus
                HStack(spacing: 12) { pageNavigation; Spacer(); pageJump }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pageStatus: some View {
        HStack(spacing: 8) {
            if ui.isLoading { ProgressView().controlSize(.small) }
            Text(ui.total == 0 ? "共 0 个 · 每页 \(SourceManagerState.pageSize) 个" :
                "第 \((ui.page - 1) * SourceManagerState.pageSize + 1)–\(min(ui.page * SourceManagerState.pageSize, ui.total)) 个，共 \(ui.total) 个")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var pageNavigation: some View {
        HStack(spacing: 8) {
            Button { ui.goToPage(ui.page - 1) } label: { Label("上一页", systemImage: "chevron.left") }
                .disabled(ui.page <= 1 || ui.isLoading)
            Text("第 \(ui.page) / \(ui.pageCount) 页").monospacedDigit().fixedSize()
            Button { ui.goToPage(ui.page + 1) } label: { Label("下一页", systemImage: "chevron.right") }
                .disabled(ui.page >= ui.pageCount || ui.isLoading)
        }
    }

    private var pageJump: some View {
        HStack(spacing: 6) {
            TextField("页码", text: Bindable(ui).pageInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 52)
                .accessibilityLabel("跳转到出处页码")
                .onSubmit(jumpToPage)
            Button("跳转", action: jumpToPage)
        }
        .disabled(ui.isLoading)
    }

    private func jumpToPage() {
        ui.goToPage(Int(ui.pageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ui.page)
    }

    @MainActor
    private func loadPage(_ key: SourcePageRequest) async {
        guard !Task.isCancelled, request == key else { return }
        let requestID = UUID()
        ui.loadID = requestID
        if ui.loadedCriteria != key.criteria {
            ui.loadedCriteria = key.criteria
            ui.selection = []
            ui.items = []
            ui.total = 0
            ui.duplicateIDs = []
            ui.duplicateCount = 0
            ui.pageInput = "1"
            if ui.page != 1 {
                ui.page = 1
                return
            }
        }
        ui.isLoading = true
        defer { if ui.loadID == requestID { ui.isLoading = false } }
        do {
            let result = try await store.db.sourcePage(query: key.criteria.query,
                onlyDuplicates: key.criteria.onlyDuplicates, sorts: key.criteria.sorts,
                page: key.page, pageSize: SourceManagerState.pageSize)
            guard !Task.isCancelled, ui.loadID == requestID, request == key else { return }
            ui.total = result.total
            if ui.page != result.page { ui.selection = [] }
            ui.page = result.page
            ui.pageInput = String(result.page)
            ui.items = result.items
            ui.duplicateIDs = result.duplicateIDs
            ui.duplicateCount = result.duplicateCount
            ui.selection.formIntersection(result.items.map(\.id))
        } catch {
            if !Task.isCancelled, ui.loadID == requestID, request == key { store.report(error) }
        }
    }

    private func visibleIDs(_ ids: [Int64]) -> [Int64] {
        let visible = Set(ui.items.map(\.id))
        return ids.filter { visible.contains($0) }
    }

    @ViewBuilder
    private func menu(_ ids: [Int64]) -> some View {
        Group {
            if ids.count == 1, let s = ui.items.first(where: { $0.id == ids[0] })?.source {
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
                store.sourcesPendingDeletion = ui.items.filter { ids.contains($0.id) }.map(\.source)
            }
        }
        .disabled(ids.isEmpty || ui.isLoading)
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
                        .handCursor()
                }
            }
            .padding(24)
            .frame(width: 520)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
