import Foundation
import KongReviewCore

// MARK: - 1.5：整理重复摘录

/// 重复摘录整理面板的数据
struct DuplicateReview: Identifiable {
    let id = UUID()
    var scanning = true
    var groups: [DuplicateFinder.Group] = []
    var highlights: [Int64: Highlight] = [:]
    /// 每组选定保留哪一条（组 id → 摘录 id）
    var keeper: [String: Int64] = [:]
    var merged = 0
}

extension LibraryStore {
    static let ignoredDuplicatesKey = "duplicates.ignored"

    var ignoredDuplicateGroups: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.ignoredDuplicatesKey) ?? [])
    }

    /// 后台查找重复摘录，结果放进 duplicateReview
    func findDuplicates() {
        // 保留同一个面板（id 不变），只重新扫描
        if duplicateReview == nil { duplicateReview = DuplicateReview() } else { duplicateReview?.scanning = true }
        let db = self.db
        let ignored = ignoredDuplicateGroups
        Task.detached(priority: .userInitiated) {
            let items = (try? db.duplicateCandidates()) ?? []
            let groups = DuplicateFinder.groups(items, ignored: ignored)
            let ids = Array(Set(groups.flatMap(\.ids)))
            let hs = (try? db.highlights(ids: ids)) ?? []
            await MainActor.run {
                guard var r = self.duplicateReview else { return }
                r.scanning = false
                r.groups = groups
                r.keeper = [:]
                r.highlights = Dictionary(hs.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
                for g in groups { r.keeper[g.id] = self.defaultKeeper(g, in: r.highlights) }
                self.duplicateReview = r
                AppLog.write("查找重复摘录：\(groups.count) 组")
            }
        }
    }

    /// 默认保留：收藏过的 > 有按语的 > 有位置的 > 回顾次数多的 > 最早录入的
    func defaultKeeper(_ g: DuplicateFinder.Group, in hs: [Int64: Highlight]) -> Int64 {
        let list = g.ids.compactMap { hs[$0] }
        func score(_ h: Highlight) -> Int {
            var s = 0
            if h.isFavorite { s += 1000 }
            if !(h.note ?? "").isEmpty { s += 100 }
            if !(h.location ?? "").isEmpty { s += 50 }
            if cardHighlightIDs.contains(h.id ?? -1) { s += 30 }
            s += min(h.surfacedCount, 20)
            return s
        }
        let best = list.max { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            return a.createdAt > b.createdAt
        }
        return best?.id ?? g.ids[0]
    }

    /// 合并一组；可 ⌘Z 撤销
    func mergeDuplicateGroup(_ groupID: String) {
        guard var r = duplicateReview, let g = r.groups.first(where: { $0.id == groupID }) else { return }
        let keeper = r.keeper[groupID] ?? g.ids[0]
        let others = g.ids.filter { $0 != keeper }
        if !mergeBackupDone {
            _ = try? BackupService.backupNow(db: db)
            mergeBackupDone = true
        }
        do {
            let undo = try db.mergeHighlights(keeper: keeper, others: others)
            r.groups.removeAll { $0.id == groupID }
            r.merged += 1
            duplicateReview = r
            undoManager?.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    try? store.db.undoMerge(undo)
                    store.reload()
                    if store.duplicateReview != nil { store.findDuplicates() }
                }
            }
            undoManager?.setActionName("合并重复摘录")
            reload()
        } catch {
            report(error)
        }
    }

    /// 合并全部“完全重复”的组
    func mergeAllExactDuplicates() {
        guard let r = duplicateReview else { return }
        for g in r.groups where g.exact { mergeDuplicateGroup(g.id) }
    }

    /// 标记“不是重复”，以后不再提示
    func ignoreDuplicateGroup(_ groupID: String) {
        var set = ignoredDuplicateGroups
        set.insert(groupID)
        UserDefaults.standard.set(Array(set), forKey: Self.ignoredDuplicatesKey)
        duplicateReview?.groups.removeAll { $0.id == groupID }
    }

    // MARK: 笔记本里的本文批注

    func updateNotebookBlockNote(_ id: Int64, _ note: String) {
        let st = notebookState
        guard let i = st.blocks.firstIndex(where: { $0.id == id }), (st.blocks[i].note ?? "") != note else { return }
        st.blocks[i].note = note
        st.pendingNoteSaves[id]?.cancel()
        let db = self.db
        st.pendingNoteSaves[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try? db.updateBlockNote(id, note: t.isEmpty ? nil : note)
            st.pendingNoteSaves[id] = nil
        }
    }
}
