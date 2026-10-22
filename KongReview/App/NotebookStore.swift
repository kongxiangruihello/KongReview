import Foundation
import Observation
import KongReviewCore

// MARK: - 1.3：专题笔记本的界面状态与操作

/// 当前打开的笔记本（块列表在这里改，不触发全库刷新；文字输入防抖后写库）
@MainActor
@Observable
final class NotebookState {
    var notebookId: Int64?
    var blocks: [NotebookBlock] = []
    /// 块里引用的摘录（最新文字）；4.1.2 起也包括札记块所引的摘录（导出脚注、引文核对、参考文献用）
    var highlights: [Int64: Highlight] = [:]
    /// 4.1.2：札记块引用的札记（最新题目与正文）
    var ideaNotes: [Int64: NotebookIdeaNote] = [:]
    /// 4.1.2：插入札记面板（插到哪一块之后）
    var notePicker: NotebookNotePicker?
    var titleDraft = ""
    /// 插入摘录面板
    var picker: NotebookPicker?
    /// 正在拖动的块
    var dragging: Int64?
    /// 鼠标所在的块（显示操作按钮）
    var hovered: Int64?
    /// 鼠标所在的插入缝（-1 为开头，其余为上一块的 id）
    var hoveredGap: Int64?

    var exportFootnotes: Bool = UserDefaults.standard.object(forKey: "notebook.footnotes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(exportFootnotes, forKey: "notebook.footnotes") }
    }
    var exportBibliography: Bool = UserDefaults.standard.bool(forKey: "notebook.bibliography") {
        didSet { UserDefaults.standard.set(exportBibliography, forKey: "notebook.bibliography") }
    }
    /// 1.4：导出时附上摘录的按语
    var exportNotes: Bool = UserDefaults.standard.bool(forKey: "notebook.notes") {
        didSet { UserDefaults.standard.set(exportNotes, forKey: "notebook.notes") }
    }
    /// 2.1：导出时各部古籍用哪个版本出注（原典书名 → 出处 id）；按笔记本记住
    var exportEditions: [String: Int64] = [:]
    /// 本笔记本摘录的版本页码（摘录 id → 出处 id → 页码）
    var editionPages: [Int64: [Int64: String]] = [:]
    /// 1.4：Word 导出加目录
    var exportTOC: Bool = UserDefaults.standard.object(forKey: "notebook.toc") as? Bool ?? true {
        didSet { UserDefaults.standard.set(exportTOC, forKey: "notebook.toc") }
    }

    @ObservationIgnored var pendingSaves: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingNoteSaves: [Int64: Task<Void, Never>] = [:]
    /// 1.5：正在编辑本文批注的块
    var editingNote: Int64?

    var quoteCount: Int { blocks.filter { $0.kind == .highlight }.count }

    /// 摘录块与札记块所引的全部摘录（按出现顺序，不重复）
    var quotedHighlightIDs: [Int64] {
        var seen = Set<Int64>(), out: [Int64] = []
        for b in blocks {
            let ids: [Int64]
            switch b.kind {
            case .highlight: ids = b.highlightId.map { [$0] } ?? []
            case .note: ids = b.noteId.flatMap { ideaNotes[$0]?.highlightIDs } ?? []
            case .text, .heading: ids = []
            }
            for id in ids where seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}

/// 4.1.2：插入札记面板
struct NotebookNotePicker: Identifiable {
    let id = UUID()
    var after: Int64?
    var atStart = false
}

/// 插入摘录面板：搜索、勾选、插到某块之后
struct NotebookPicker: Identifiable {
    let id = UUID()
    var after: Int64?
    var atStart = false
    var query = ""
    var results: [Highlight] = []
    var selected: [Int64] = []
}

/// 新建笔记本：标题 + 建好后放进去的摘录
struct NewNotebookRequest: Identifiable {
    let id = UUID()
    var title = ""
    var highlightIDs: [Int64] = []
}

extension LibraryStore {

    // MARK: 笔记本

    func reloadNotebooks() {
        notebooks = (try? db.notebooks()) ?? []
        notebookQuoteCounts = (try? db.notebookQuoteCounts()) ?? [:]
    }

    /// 新建并打开；highlightIDs 非空时一并放进去
    @discardableResult
    func createNotebook(title: String, with highlightIDs: [Int64] = [], open: Bool = true) -> Int64? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let n = try db.createNotebook(title: t.isEmpty ? "未命名专题" : t)
            guard let id = n.id else { return nil }
            if !highlightIDs.isEmpty {
                let hs = try db.highlights(ids: highlightIDs)
                try db.insertBlocks(hs.map { NotebookBlock(notebookId: id, position: 0, kind: .highlight, highlightId: $0.id, text: $0.text) },
                                    into: id, after: nil)
            }
            reloadNotebooks()
            if open { selection = .notebook(id) }
            return id
        } catch {
            report(error)
            return nil
        }
    }

    /// 把摘录加到某本笔记本末尾（从列表、回顾卡片加入）
    func addHighlights(_ ids: [Int64], toNotebook notebookId: Int64) {
        guard !ids.isEmpty else { return }
        do {
            let hs = try db.highlights(ids: ids)
            let inserted = try db.insertBlocks(hs.map { NotebookBlock(notebookId: notebookId, position: 0, kind: .highlight,
                                                                      highlightId: $0.id, text: $0.text) },
                                               into: notebookId, after: nil)
            reloadNotebooks()
            if notebookState.notebookId == notebookId {
                notebookState.blocks += inserted
                for h in hs { if let id = h.id { notebookState.highlights[id] = h } }
            }
            let title = notebooks.first { $0.id == notebookId }?.title ?? "笔记本"
            infoMessage = "已把 \(hs.count) 条摘录加入专题笔记本《\(title)》。"
        } catch {
            report(error)
        }
    }

    func renameNotebook(_ id: Int64, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, notebooks.first(where: { $0.id == id })?.title != t else { return }
        perform { try db.renameNotebook(id, title: t) }
        reloadNotebooks()
    }

    func deleteNotebook(_ n: Notebook) {
        guard let id = n.id else { return }
        do {
            _ = try BackupService.backupNow(db: db)
        } catch {
            AppLog.write("删除笔记本前备份失败：\(error.localizedDescription)")
        }
        perform { try db.deleteNotebook(id) }
        if case .notebook(let cur) = selection, cur == id { openTodayReview() }
        if ReviewScope.notebookID(review.theme) == id { review.theme = nil }
        UserDefaults.standard.removeObject(forKey: "review.session." + ReviewScope.notebook(id))
        if notebookState.notebookId == id { notebookState.notebookId = nil; notebookState.blocks = [] }
        reloadNotebooks()
    }

    // MARK: 打开的笔记本

    func loadNotebook(_ id: Int64) {
        flushNotebookSaves()
        let st = notebookState
        st.notebookId = id
        st.titleDraft = notebooks.first { $0.id == id }?.title ?? ""
        st.blocks = (try? db.notebookBlocks(id)) ?? []
        st.ideaNotes = (try? db.notebookIdeaNotes(ids: st.blocks.compactMap(\.noteId))) ?? [:]
        let ids = st.quotedHighlightIDs
        let hs = (try? db.highlights(ids: ids)) ?? []
        st.highlights = Dictionary(hs.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
        st.picker = nil
        st.notePicker = nil
        st.editingNote = nil
        st.exportEditions = NotebookEditionChoice.load(id)
        st.editionPages = (try? db.editionPages(highlightIds: ids)) ?? [:]
    }

    /// 摘录被编辑后刷新引用到的文字
    func refreshNotebookHighlights() {
        let st = notebookState
        guard st.notebookId != nil else { return }
        st.ideaNotes = (try? db.notebookIdeaNotes(ids: st.blocks.compactMap(\.noteId))) ?? [:]
        let ids = st.quotedHighlightIDs
        let hs = (try? db.highlights(ids: ids)) ?? []
        st.highlights = Dictionary(hs.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
        st.editionPages = (try? db.editionPages(highlightIds: ids)) ?? [:]
    }

    /// 插入文字或小标题，返回新块 id
    @discardableResult
    func insertNotebookBlock(_ kind: NotebookBlock.Kind, text: String = "", after: Int64?, atStart: Bool = false) -> Int64? {
        let st = notebookState
        guard let nid = st.notebookId else { return nil }
        do {
            let new = try db.insertBlocks([NotebookBlock(notebookId: nid, position: 0, kind: kind, text: text)],
                                          into: nid, after: after, atStart: atStart)
            st.blocks = (try? db.notebookBlocks(nid)) ?? st.blocks
            return new.first?.id
        } catch {
            report(error)
            return nil
        }
    }

    /// 4.1.2：插入札记块（显示札记的最新正文；加入时的正文留作底稿）
    func insertNotebookIdeaNote(_ noteId: Int64, after: Int64?, atStart: Bool = false) {
        let st = notebookState
        guard let nid = st.notebookId, !fullBackupBusy else { return }
        do {
            guard let note = try db.ideaNote(id: noteId) else { return }
            try db.insertBlocks([NotebookBlock(notebookId: nid, position: 0, kind: .note, text: note.body, noteId: noteId)],
                                into: nid, after: after, atStart: atStart)
            st.blocks = (try? db.notebookBlocks(nid)) ?? st.blocks
            refreshNotebookHighlights()
        } catch {
            report(error)
        }
    }

    func insertNotebookHighlights(_ ids: [Int64], after: Int64?, atStart: Bool = false) {
        let st = notebookState
        guard let nid = st.notebookId, !ids.isEmpty else { return }
        do {
            let byID = Dictionary(((try? db.highlights(ids: ids)) ?? []).compactMap { h in h.id.map { ($0, h) } },
                                  uniquingKeysWith: { a, _ in a })
            let hs = ids.compactMap { byID[$0] }
            try db.insertBlocks(hs.map { NotebookBlock(notebookId: nid, position: 0, kind: .highlight, highlightId: $0.id, text: $0.text) },
                                into: nid, after: after, atStart: atStart)
            for h in hs { if let id = h.id { st.highlights[id] = h } }
            st.blocks = (try? db.notebookBlocks(nid)) ?? st.blocks
            notebookQuoteCounts[nid] = st.quoteCount
        } catch {
            report(error)
        }
    }

    /// 文字改动：本地立即更新，0.6 秒后写库
    func updateNotebookBlockText(_ id: Int64, _ text: String) {
        let st = notebookState
        guard let i = st.blocks.firstIndex(where: { $0.id == id }), st.blocks[i].text != text else { return }
        st.blocks[i].text = text
        st.pendingSaves[id]?.cancel()
        let db = self.db
        st.pendingSaves[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            try? db.updateBlockText(id, text: text)
            st.pendingSaves[id] = nil
        }
    }

    /// 立刻写入所有未保存的文字（切换笔记本、导出前）
    func flushNotebookSaves() {
        let st = notebookState
        for (id, task) in st.pendingSaves {
            task.cancel()
            if let b = st.blocks.first(where: { $0.id == id }) { try? db.updateBlockText(id, text: b.text) }
        }
        st.pendingSaves = [:]
        for (id, task) in st.pendingNoteSaves {
            task.cancel()
            if let b = st.blocks.first(where: { $0.id == id }) {
                let t = (b.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try? db.updateBlockNote(id, note: t.isEmpty ? nil : b.note)
            }
        }
        st.pendingNoteSaves = [:]
    }

    func moveNotebookBlock(_ id: Int64, by delta: Int) {
        let st = notebookState
        guard let i = st.blocks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard st.blocks.indices.contains(j) else { return }
        st.blocks.swapAt(i, j)
        persistNotebookOrder()
    }

    /// 拖放：把 id 移到 target 之前（target 为 nil 时移到末尾）
    func moveNotebookBlock(_ id: Int64, before target: Int64?) {
        let st = notebookState
        guard id != target, let i = st.blocks.firstIndex(where: { $0.id == id }) else { return }
        let b = st.blocks.remove(at: i)
        if let target, let j = st.blocks.firstIndex(where: { $0.id == target }) {
            st.blocks.insert(b, at: j)
        } else {
            st.blocks.append(b)
        }
        persistNotebookOrder()
    }

    private func persistNotebookOrder() {
        let st = notebookState
        for k in st.blocks.indices { st.blocks[k].position = Double(k + 1) }
        do { try db.reorderBlocks(st.blocks.compactMap(\.id)) } catch { report(error) }
    }

    /// 删除一块；可 ⌘Z 撤销
    func deleteNotebookBlock(_ id: Int64) {
        let st = notebookState
        guard let i = st.blocks.firstIndex(where: { $0.id == id }), let nid = st.notebookId else { return }
        st.pendingSaves[id]?.cancel()
        st.pendingSaves[id] = nil
        let snapshot = st.blocks[i]
        let afterID = i > 0 ? st.blocks[i - 1].id : nil
        do { try db.deleteBlocks([id]) } catch { report(error); return }
        st.blocks.remove(at: i)
        notebookQuoteCounts[nid] = st.quoteCount
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard store.notebookState.notebookId == nid else { return }
                var b = snapshot
                b.id = nil
                if let new = try? store.db.insertBlocks([b], into: nid, after: afterID, atStart: afterID == nil, logsWriting: false).first,
                   let newID = new.id, snapshot.kind != .highlight {
                    try? store.db.updateBlockText(newID, text: snapshot.text)
                }
                store.notebookState.blocks = (try? store.db.notebookBlocks(nid)) ?? store.notebookState.blocks
                store.notebookQuoteCounts[nid] = store.notebookState.quoteCount
            }
        }
        undoManager?.setActionName("删除笔记本中的一块")
    }

    // MARK: 插入摘录面板

    func openNotebookPicker(after: Int64?, atStart: Bool = false) {
        var p = NotebookPicker(after: after, atStart: atStart)
        p.results = (try? db.highlights(HighlightQuery(text: ""), limit: 60)) ?? []
        notebookState.picker = p
    }

    func searchNotebookPicker(_ q: String) {
        guard notebookState.picker != nil else { return }
        notebookState.picker?.query = q
        notebookState.picker?.results = (try? db.highlights(HighlightQuery(text: q), limit: 60)) ?? []
    }

    func commitNotebookPicker() {
        guard let p = notebookState.picker else { return }
        notebookState.picker = nil
        insertNotebookHighlights(p.selected, after: p.after, atStart: p.atStart)
    }

    // MARK: 导出用的内容

    func notebookPieces() -> [NotebookPiece] {
        let st = notebookState
        let notes = st.exportNotes
        return st.blocks.flatMap { b -> [NotebookPiece] in
            switch b.kind {
            case .heading:
                let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? [] : [NotebookPiece(.heading(t))]
            case .text:
                return [NotebookPiece(.text(b.text))]
            case .highlight:
                let h = b.highlightId.flatMap { st.highlights[$0] }
                let text = h?.text ?? b.text
                let cite = h.map { notebookCitation(for: $0) } ?? ""
                var out = [NotebookPiece(.quote(text, cite: cite))]
                if notes, let n = h?.note, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(NotebookPiece(.comment(n)))
                }
                // 1.5：本文批注一律导出（它是这篇文字的一部分）
                if let n = b.note, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(NotebookPiece(.comment(n)))
                }
                return out
            case .note:
                // 4.1.2：札记按普通段落输出，[[链接]] 只留文字；所引摘录的出处作脚注
                let n = b.noteId.flatMap { st.ideaNotes[$0] }
                let body = WikiLinks.plain(n?.body ?? b.text)
                let cites = (n?.highlightIDs ?? []).compactMap { st.highlights[$0] }.map { notebookCitation(for: $0) }.filter { !$0.isEmpty }
                return [NotebookPiece(.essay(body, cites: cites))]
            }
        }
    }

    func notebookBibliography() -> [String] {
        let st = notebookState
        var ids: [Int64] = []
        for hid in st.quotedHighlightIDs {
            // 2.1：参考文献表也按导出所用的版本；4.1.2：含札记块所引的摘录
            if let h = st.highlights[hid],
               let sid = editionChoice(for: h).flatMap({ $0.location == nil ? nil : $0.source.id }) ?? h.sourceId,
               !ids.contains(sid) { ids.append(sid) }
        }
        let list = ids.compactMap { id in sources.first { $0.id == id } }
        return Bibliography.entries(list, order: .numbered)
    }

    // MARK: 每周小结

    static let digestEnabledKey = "digest.enabled"
    static let digestDismissedKey = "digest.dismissedWeek"
    static let digestNotifiedKey = "digest.notifiedWeek"

    var weeklyDigestEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.digestEnabledKey) as? Bool ?? true
    }

    /// 上周小结（本周还没点“知道了”时；上周没有任何回顾、录入时为 nil）
    func currentWeeklyDigest(now: Date = Date()) -> WeeklyDigest? {
        guard weeklyDigestEnabled else { return nil }
        let key = WeeklyDigest.dayKey(WeeklyDigest.previousWeek(of: now).start)
        guard UserDefaults.standard.string(forKey: Self.digestDismissedKey) != key else { return nil }
        if weeklyDigestCache?.key != key {
            weeklyDigestCache = try? db.weeklyDigest(now: now)
        }
        guard let d = weeklyDigestCache, !d.isEmpty else { return nil }
        return d
    }

    func dismissWeeklyDigest() {
        if let d = weeklyDigestCache { UserDefaults.standard.set(d.key, forKey: Self.digestDismissedKey) }
        revisionBump()
    }
}
