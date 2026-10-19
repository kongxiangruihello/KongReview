import Foundation
import GRDB
import KongReviewCore

enum ReviewEditorMode: String, Codable { case note, inline }

struct ReviewEditorSession {
    var id: UUID
    var mode: ReviewEditorMode
    var original: Highlight
    var editionPages: [Int64: String]
}

enum ReviewEditorError: LocalizedError {
    case missing, changed, empty
    var errorDescription: String? {
        switch self {
        case .missing: return "原摘录已删除。草稿已保留，请从首页的草稿列表恢复。"
        case .changed: return "原摘录的编辑内容已更新。为避免覆盖新内容，草稿已保留，请从首页的草稿列表恢复。"
        case .empty: return "摘录原文不能为空。"
        }
    }
}

extension SavedHighlightDraft {
    func canResumeReview(over current: Highlight) -> Bool {
        guard let original, current.id == original.id, current.deletedAt == nil else { return false }
        return Self.sameEditedFields(current, original, mode: reviewMode ?? .inline)
    }

    static func sameEditedFields(_ lhs: Highlight, _ rhs: Highlight, mode: ReviewEditorMode) -> Bool {
        if mode == .note { return (lhs.note ?? "") == (rhs.note ?? "") }
        return lhs.text == rhs.text && (lhs.translation ?? "") == (rhs.translation ?? "")
            && (lhs.note ?? "") == (rhs.note ?? "")
    }
}

extension AppDatabase {
    /// 在一个事务里核对并合并正在编辑的字段，保留收藏、回顾进度、标签等最新值。
    func saveReviewEditor(original: Highlight, mode: ReviewEditorMode, text: String,
                          translation: String, note: String) throws -> Highlight {
        try writer.write { db in
            guard let id = original.id, var current = try Highlight.fetchOne(db, key: id),
                  current.deletedAt == nil else { throw ReviewEditorError.missing }
            guard SavedHighlightDraft.sameEditedFields(current, original, mode: mode) else {
                throw ReviewEditorError.changed
            }
            if mode == .inline {
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ReviewEditorError.empty }
                current.text = text
                current.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            }
            current.note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            current.updatedAt = Date()
            try current.update(db)
            return current
        }
    }
}

@MainActor
extension ReviewState {
    var editorHighlightID: Int64? { editorSession?.original.id }

    func beginNote(for highlight: Highlight) { beginEditor(for: highlight, mode: .note) }
    func beginInline(for highlight: Highlight) { beginEditor(for: highlight, mode: .inline) }

    /// 返回上一条、重新进入菜单和重启后都使用同一份草稿，不会用旧原文覆盖数据库。
    func resumeEditor(for highlight: Highlight) {
        if editorHighlightID == highlight.id, noteDraft != nil || inlineDraft != nil { return }
        leaveCurrentEditor()
        draftNotice = nil
        guard let saved = recoverableDraft(for: highlight.id) else { return }
        guard saved.canResumeReview(over: highlight) else {
            draftNotice = "这条摘录有一份未保存草稿，原内容已有变化。可从首页草稿列表恢复，现有内容已保留。"
            return
        }
        installEditor(for: highlight, mode: saved.reviewMode ?? .inline, saved: saved)
        draftNotice = "已恢复上次未保存的回顾草稿。保存后才会更新正式内容。"
    }

    private func beginEditor(for highlight: Highlight, mode: ReviewEditorMode) {
        leaveCurrentEditor()
        draftNotice = nil
        let current = highlight.id.flatMap { try? database?.highlight(id: $0) } ?? highlight
        if let saved = recoverableDraft(for: highlight.id) {
            guard saved.canResumeReview(over: current) else {
                draftNotice = "这条摘录有一份未保存草稿，原内容已有变化。请先从首页草稿列表恢复。"
                return
            }
            // 按语草稿进入就地编辑时一起带入；反向操作仍打开完整草稿，避免丢失原文修改。
            let effectiveMode: ReviewEditorMode = saved.reviewMode == .inline ? .inline : mode
            installEditor(for: current, mode: effectiveMode, saved: saved)
        } else {
            installEditor(for: current, mode: mode, saved: nil)
        }
    }

    private func installEditor(for original: Highlight, mode: ReviewEditorMode, saved: SavedHighlightDraft?) {
        let pages = original.id.flatMap { try? database?.editionPages($0) } ?? [:]
        editorSession = ReviewEditorSession(id: saved?.id ?? UUID(), mode: mode, original: original, editionPages: pages)
        suppressEditorRecording = true
        if mode == .note {
            noteDraft = saved?.highlight.note ?? original.note ?? ""
            inlineDraft = nil
        } else {
            let content = saved?.highlight ?? original
            inlineDraft = InlineEditDraft(id: original.id, text: content.text,
                translation: content.translation ?? "", note: content.note ?? "")
            noteDraft = nil
        }
        suppressEditorRecording = false
        recordCurrentEditor()
    }

    private func recoverableDraft(for id: Int64?) -> SavedHighlightDraft? {
        guard let id else { return nil }
        let values = Array(volatileDrafts.values) + (editorPersistence?.highlightDrafts ?? [])
        return values.filter { $0.highlight.id == id && $0.reviewMode != nil }
            .sorted { $0.savedAt > $1.savedAt }.first
    }

    func recordCurrentEditor() {
        guard !suppressEditorRecording, let session = editorSession else { return }
        var highlight = session.original
        if session.mode == .note {
            guard let noteDraft else { return }
            highlight.note = noteDraft.nilIfBlank
        } else {
            guard let inlineDraft else { return }
            highlight.text = inlineDraft.text
            highlight.translation = inlineDraft.translation.nilIfBlank
            highlight.note = inlineDraft.note.nilIfBlank
        }
        var draft = HighlightDraft(highlight: highlight, tagsText: TagParser.format(highlight.tags))
        draft.id = session.id
        draft.editionPages = session.editionPages
        var snapshot = SavedHighlightDraft(draft: draft, original: session.original, originalEditionPages: session.editionPages)
        snapshot.reviewMode = session.mode
        if snapshot.hasUnsavedChanges { volatileDrafts[session.id] = snapshot }
        else { volatileDrafts[session.id] = nil }
        do {
            try editorPersistence?.recordHighlight(draft, original: session.original,
                originalEditionPages: session.editionPages, reviewMode: session.mode)
            if editorPersistence != nil { volatileDrafts[session.id] = nil }
            onDraftChange?(nil)
        } catch {
            draftNotice = "草稿暂未能保存到磁盘，请暂时不要退出应用。" + error.localizedDescription
            onDraftChange?(draftNotice)
        }
    }

    /// 切换条目/范围/菜单只收起编辑器，输入已经逐次保存；失败时仍在内存中保留副本。
    func leaveCurrentEditor() {
        recordCurrentEditor()
        suppressEditorRecording = true
        noteDraft = nil
        inlineDraft = nil
        editorSession = nil
        suppressEditorRecording = false
        scrollRestoreToken += 1
    }

    func discardCurrentEditor() {
        guard let session = editorSession else { return }
        do {
            try editorPersistence?.removeHighlight(id: session.id)
            volatileDrafts[session.id] = nil
            suppressEditorRecording = true
            noteDraft = nil; inlineDraft = nil; editorSession = nil
            suppressEditorRecording = false
            draftNotice = nil
            scrollRestoreToken += 1
            onDraftChange?(nil)
        } catch { onDraftChange?("草稿暂未能移除：" + error.localizedDescription) }
    }

    func saveCurrentEditor() throws -> Highlight? {
        guard let session = editorSession, let database else { return nil }
        recordCurrentEditor()
        let saved = try database.saveReviewEditor(original: session.original, mode: session.mode,
            text: inlineDraft?.text ?? session.original.text,
            translation: inlineDraft?.translation ?? session.original.translation ?? "",
            note: session.mode == .note ? noteDraft ?? "" : inlineDraft?.note ?? "")
        do { try editorPersistence?.removeHighlight(id: session.id); onDraftChange?(nil) }
        catch { onDraftChange?("正式内容已保存，旧草稿暂未能清除：" + error.localizedDescription) }
        volatileDrafts[session.id] = nil
        suppressEditorRecording = true
        noteDraft = nil; inlineDraft = nil; editorSession = nil
        suppressEditorRecording = false
        draftNotice = nil
        scrollRestoreToken += 1
        return saved
    }
}

/// 像素位置按日期、范围和摘录分别保存；没有读过的新摘录默认从顶部开始。
@MainActor
final class ReviewReadingPositions {
    private let defaults: UserDefaults?
    private var positions: [String: Double] = [:]
    init(defaults: UserDefaults?) { self.defaults = defaults }
    static func owner(day: String, scope: String?, highlightID: Int64) -> String {
        "reviewReading.v1.\(day).\(scope ?? "__all").\(highlightID)"
    }
    func offset(for owner: String) -> Double {
        let value = positions[owner] ?? (defaults?.object(forKey: owner) as? Double) ?? 0
        return value.isFinite ? max(0, value) : 0
    }
    func save(_ offset: Double, for owner: String) {
        guard offset.isFinite else { return }
        let value = max(0, offset)
        guard positions[owner] != value else { return }
        positions[owner] = value
        defaults?.set(value, forKey: owner)
    }
}
