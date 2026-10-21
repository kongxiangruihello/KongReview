import Foundation
import KongReviewCore

// MARK: - 4.1：札记

/// “记札记”面板：新写一条，或把摘录加入已有札记
struct IdeaNoteComposer: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var body = ""
    /// 要引用的摘录（回顾时的当前摘录、按语所属的摘录）
    var highlightID: Int64?
    /// 摘录原文的开头，面板上显示
    var highlightPreview = ""
    /// 从按语发展而来
    var fromAnnotation = false
}

extension LibraryStore {
    func refreshIdeaNotes() {
        ideaNoteCount = (try? db.ideaNoteCount()) ?? 0
        ideaNoteRevision += 1
    }

    private func afterIdeaNoteChange() {
        refreshIdeaNotes()
        // 当前项目的札记所引摘录计入回顾加权
        refreshLearningFocus()
        researchProjectRevision += 1
        revisionBump()
    }

    /// 新写一条札记（可带要引用的摘录与正文底稿）
    func composeIdeaNote(highlight: Highlight? = nil, body: String = "", fromAnnotation: Bool = false) {
        guard !fullBackupBusy else { return }
        ideaNoteComposer = Self.ideaNoteComposer(highlight: highlight, body: body, fromAnnotation: fromAnnotation)
    }

    nonisolated static func ideaNoteComposer(highlight: Highlight?, body: String = "", fromAnnotation: Bool = false) -> IdeaNoteComposer {
        let preview = highlight.map { String(Markdown.plainText(fromHTML: $0.text).prefix(60)) } ?? ""
        return IdeaNoteComposer(body: body, highlightID: highlight?.id, highlightPreview: preview, fromAnnotation: fromAnnotation)
    }

    /// 按语“发展为札记”：以按语为正文底稿，并引用这条摘录；按语本身不动
    func developAnnotation(_ highlight: Highlight) {
        composeIdeaNote(highlight: highlight, body: highlight.note ?? "", fromAnnotation: true)
    }

    @discardableResult
    func createIdeaNote(title: String, body: String = "", highlightIDs: [Int64] = [], open: Bool = false) -> Int64? {
        guard !fullBackupBusy else { return nil }
        do {
            let note = try db.createIdeaNote(title: title, body: body, highlightIDs: highlightIDs)
            afterIdeaNoteChange()
            if open, let id = note.id { selection = .ideaNote(id) }
            return note.id
        } catch { report(error); return nil }
    }

    @discardableResult
    func saveIdeaNote(id: Int64, title: String, body: String) -> Bool {
        guard !fullBackupBusy else { return false }
        do { try db.saveIdeaNote(id: id, title: title, body: body); afterIdeaNoteChange(); return true }
        catch { report(error); return false }
    }

    func setIdeaNoteDeleted(_ id: Int64, _ deleted: Bool) {
        guard !fullBackupBusy else { return }
        do {
            try db.setIdeaNoteDeleted(id, deleted: deleted)
            if deleted, selection == .ideaNote(id) { selection = .ideaNotes }
            afterIdeaNoteChange()
        } catch { report(error) }
    }

    func purgeIdeaNote(_ id: Int64) {
        guard !fullBackupBusy else { return }
        do {
            try db.purgeIdeaNote(id)
            if selection == .ideaNote(id) { selection = .ideaNotes }
            afterIdeaNoteChange()
        } catch { report(error) }
    }

    func addHighlights(_ ids: [Int64], toIdeaNote noteId: Int64) {
        guard !fullBackupBusy, !ids.isEmpty else { return }
        do { try db.addHighlights(ids, toIdeaNote: noteId); afterIdeaNoteChange() } catch { report(error) }
    }

    func removeHighlight(_ highlightId: Int64, fromIdeaNote noteId: Int64) {
        guard !fullBackupBusy else { return }
        do { try db.removeHighlight(highlightId, fromIdeaNote: noteId); afterIdeaNoteChange() } catch { report(error) }
    }

    func reorderHighlights(_ ids: [Int64], inIdeaNote noteId: Int64) {
        guard !fullBackupBusy else { return }
        do { try db.reorderHighlights(ids, inIdeaNote: noteId); afterIdeaNoteChange() } catch { report(error) }
    }

    /// 札记正文里的链接：kongreview://note/编号 打开札记；kongreview://note-new?title=… 新建同名札记并打开
    func openIdeaNoteLink(_ url: URL) -> Bool {
        guard url.scheme == "kongreview" else { return false }
        if url.host == "note", let id = Int64(url.lastPathComponent) {
            selection = .ideaNote(id)
            return true
        }
        if url.host == "note-new" {
            let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value ?? ""
            if let existing = try? db.resolveIdeaNoteID(title: title) { selection = .ideaNote(existing) }
            else { createIdeaNote(title: title, open: true) }
            return true
        }
        return false
    }

    /// 回顾、编辑面板用：引用了这些摘录的札记
    func ideaNotesCiting(_ highlightIDs: [Int64]) -> [Int64: [IdeaNoteRef]] {
        _ = ideaNoteRevision
        return (try? db.ideaNotesCiting(highlightIDs: highlightIDs)) ?? [:]
    }
}
