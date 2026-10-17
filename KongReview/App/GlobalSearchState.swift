import Foundation
import Observation

@MainActor
@Observable
final class GlobalSearchState {
    var isPresented = false
    var query = "" { didSet { if query != oldValue { invalidate() } } }
    var selectedKind: GlobalSearchKind? { didSet { if selectedKind != oldValue { invalidate() } } }
    private(set) var sections: [GlobalSearchPage] = []
    private(set) var requestID = UUID()
    private(set) var isLoading = false
    private(set) var loadingKinds: Set<GlobalSearchKind> = []
    private(set) var error: String?
    private(set) var pendingTarget: GlobalSearchTarget?
    var navigationID = UUID()
    @ObservationIgnored private var loadTasks: [GlobalSearchKind: Task<Void, Never>] = [:]

    static let pageSize = 20
    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var total: Int { sections.reduce(0) { $0 + $1.total } }

    func present() {
        pendingTarget = nil
        navigationID = UUID()
        invalidate()
        isPresented = true
    }

    func invalidate() {
        requestID = UUID()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        loadingKinds = []
        sections = []
        error = nil
        isLoading = !normalizedQuery.isEmpty
    }

    /// 由 SwiftUI 的 task(id:) 调用；新输入和面板关闭都会取消旧的等待/查询。
    func search(db: AppDatabase, debounce: Bool = true) async {
        let token = requestID, text = normalizedQuery, kind = selectedKind
        guard !text.isEmpty else { isLoading = false; return }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            let pages = try await db.globalSearch(query: text, kind: kind, limit: Self.pageSize)
            try Task.checkCancellation()
            _ = apply(pages, requestID: token, query: text, kind: kind)
        } catch is CancellationError {
            // 新请求持有自己的状态，旧请求不能清除其加载提示。
        } catch {
            guard token == requestID, text == normalizedQuery, kind == selectedKind else { return }
            isLoading = false
            self.error = "搜索暂未完成：" + error.localizedDescription
        }
    }

    @discardableResult
    func apply(_ pages: [GlobalSearchPage], requestID token: UUID, query: String,
               kind: GlobalSearchKind?) -> Bool {
        guard token == requestID, query == normalizedQuery, kind == selectedKind else { return false }
        sections = pages
        isLoading = false
        error = nil
        return true
    }

    func loadMore(_ kind: GlobalSearchKind, db: AppDatabase) {
        guard !isLoading, !loadingKinds.contains(kind),
              let page = sections.first(where: { $0.kind == kind }), page.hasMore else { return }
        let token = requestID, text = normalizedQuery, offset = page.offset + page.items.count
        loadingKinds.insert(kind)
        error = nil
        loadTasks[kind] = Task { [weak self] in
            do {
                let next = try await db.globalSearch(query: text, kind: kind, offset: offset, limit: Self.pageSize)
                try Task.checkCancellation()
                guard let self, let next = next.first else { return }
                _ = self.append(next, requestID: token, query: text)
            } catch is CancellationError {
            } catch {
                guard let self, self.requestID == token, self.normalizedQuery == text else { return }
                self.loadingKinds.remove(kind)
                self.loadTasks[kind] = nil
                self.error = "暂未能加载更多：" + error.localizedDescription
            }
        }
    }

    @discardableResult
    func append(_ page: GlobalSearchPage, requestID token: UUID, query: String) -> Bool {
        guard token == requestID, query == normalizedQuery,
              let index = sections.firstIndex(where: { $0.kind == page.kind }),
              page.offset == sections[index].offset + sections[index].items.count else { return false }
        // 两页之间记录插入/删除可能移动 offset；重读首屏，避免漏项或重复。
        let oldIDs = Set(sections[index].items.map(\.id))
        guard page.total == sections[index].total, oldIDs.isDisjoint(with: page.items.map(\.id)) else {
            invalidate()
            return false
        }
        sections[index].items += page.items
        sections[index].total = page.total
        loadingKinds.remove(page.kind)
        loadTasks[page.kind] = nil
        return true
    }

    func choose(_ target: GlobalSearchTarget) {
        pendingTarget = target
        isPresented = false
    }

    func close() {
        pendingTarget = nil
        isPresented = false
    }

    func takePendingTarget() -> GlobalSearchTarget? {
        let target = pendingTarget
        pendingTarget = nil
        return target
    }

    func cancelLoads() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        loadingKinds = []
        requestID = UUID()
        isLoading = false
    }
}
