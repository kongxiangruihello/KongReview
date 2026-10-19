import Foundation
import KongReviewCore

/// 编辑中的副本与正式数据库分开保存。每次输入原子落盘，关闭或退出无需等待计时器。
/// 调用方只在保存成功或用户明确放弃时删除；仅关闭编辑面板会保留草稿。
final class EditorDraftPersistence {
    private struct FileContents: Codable {
        var version = 1
        var highlights: [SavedHighlightDraft] = []
        var cards: [SavedCardDraft] = []
    }

    let fileURL: URL
    private var contents: FileContents
    // 未改动的表单无需写磁盘，但仍记住打开时的原值，不能把第一次输入误当作基线。
    private var highlightSessions: [UUID: SavedHighlightDraft] = [:]
    private var cardSessions: [UUID: SavedCardDraft] = [:]

    init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("editor-drafts.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            contents = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL))
            guard contents.version == 1 else { throw DraftError.unsupportedVersion }
        } else {
            contents = FileContents()
        }
    }

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
            .appendingPathComponent("KongReview", isDirectory: true)
            .appendingPathComponent("EditorDrafts", isDirectory: true)
    }

    var highlightDrafts: [SavedHighlightDraft] {
        contents.highlights.filter(\.hasUnsavedChanges).sorted { $0.savedAt > $1.savedAt }
    }
    var cardDrafts: [SavedCardDraft] {
        contents.cards.filter(\.hasUnsavedChanges).sorted { $0.savedAt > $1.savedAt }
    }

    /// 首次收到草稿时取数据库原值作比较基线；后续输入始终沿用该基线。
    /// 不存放未修改的记录和空白新建表单，避免打开/取消就产生恢复提示。
    func recordHighlight(_ draft: HighlightDraft, original: Highlight? = nil,
                         originalEditionPages: [Int64: String]? = nil,
                         reviewMode: ReviewEditorMode? = nil) throws {
        let existing = highlightSessions[draft.id] ?? contents.highlights.first { $0.id == draft.id }
        var value = SavedHighlightDraft(draft: draft,
            original: existing?.original ?? original ?? (draft.isNew ? nil : draft.highlight),
            originalEditionPages: existing?.originalEditionPages ?? originalEditionPages ?? draft.editionPages)
        value.reviewMode = reviewMode ?? existing?.reviewMode
        var next = contents
        next.highlights.removeAll { $0.id == draft.id }
        if value.hasUnsavedChanges { next.highlights.append(value) }
        try replace(with: next)
        highlightSessions[draft.id] = value
    }

    func recordCard(_ draft: CardDraft, original: Card? = nil) throws {
        let existing = cardSessions[draft.id] ?? contents.cards.first { $0.id == draft.id }
        let value = SavedCardDraft(draft: draft,
            original: existing?.original ?? original ?? (draft.isNew ? nil : draft.card))
        var next = contents
        next.cards.removeAll { $0.id == draft.id }
        if value.hasUnsavedChanges { next.cards.append(value) }
        try replace(with: next)
        cardSessions[draft.id] = value
    }

    func removeHighlight(id: UUID) throws {
        var next = contents
        next.highlights.removeAll { $0.id == id }
        try replace(with: next)
        highlightSessions[id] = nil
    }

    /// 进入完整编辑面板后，草稿可包含出处、标签等额外修改，不再由回顾的小编辑器自动接管。
    func detachReviewHighlight(id: UUID) throws {
        var next = contents
        guard let index = next.highlights.firstIndex(where: { $0.id == id }),
              next.highlights[index].reviewMode != nil else { return }
        next.highlights[index].reviewMode = nil
        try replace(with: next)
        if var session = highlightSessions[id] {
            session.reviewMode = nil
            highlightSessions[id] = session
        }
    }

    func removeCard(id: UUID) throws {
        var next = contents
        next.cards.removeAll { $0.id == id }
        try replace(with: next)
        cardSessions[id] = nil
    }

    /// 输入已同步写入；供窗口关闭和应用退出时显式确认最后一份完整快照。
    func flush() throws {
        if !contents.highlights.isEmpty || !contents.cards.isEmpty { try write(contents) }
    }

    /// 完整恢复后重新读取文件，并丢弃与恢复前数据库对应的编辑基线。
    func reloadFromDisk() throws {
        let next = try Self.readContents(at: fileURL)
        contents = next
        highlightSessions = [:]
        cardSessions = [:]
    }

    /// 仅校验导入副本，绝不写入当前草稿目录。
    static func validateBackupFile(at url: URL) throws -> (highlights: Int, cards: Int) {
        let value = try readContents(at: url)
        return (value.highlights.filter(\.hasUnsavedChanges).count,
                value.cards.filter(\.hasUnsavedChanges).count)
    }

    private static func readContents(at url: URL) throws -> FileContents {
        guard FileManager.default.fileExists(atPath: url.path) else { return FileContents() }
        let value = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw DraftError.unsupportedVersion }
        guard Set(value.highlights.map(\.id)).count == value.highlights.count,
              Set(value.cards.map(\.id)).count == value.cards.count else { throw DraftError.invalidContents }
        return value
    }

    private func replace(with next: FileContents) throws {
        // 不因打开未改动的表单创建目录或文件。
        if contents.highlights.isEmpty, contents.cards.isEmpty,
           next.highlights.isEmpty, next.cards.isEmpty { return }
        try write(next)
        contents = next
    }

    private func write(_ value: FileContents) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private enum DraftError: LocalizedError {
        case unsupportedVersion
        case invalidContents
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "草稿文件来自较新版本，请先升级 KongReview。原文件已保留。"
            case .invalidContents: return "草稿文件包含重复记录，无法恢复。原文件已保留。"
            }
        }
    }
}

struct HighlightDraftRecovery {
    var draft: HighlightDraft
    var notice: String?
}

struct CardDraftRecovery {
    var draft: CardDraft
    var notice: String?
}

struct SavedHighlightDraft: Codable, Identifiable {
    var id: UUID
    var savedAt: Date
    var highlight: Highlight
    var tagsText: String
    var newSourceTitle: String
    var newSourceAuthor: String
    var newSourceURL: String
    var newSourceKind: SourceKind
    var showNewSource: Bool
    var editionPages: [Int64: String]
    var original: Highlight?
    var originalEditionPages: [Int64: String]
    /// 可选字段兼容 2.5/2.6 的草稿文件；回顾里的编辑也出现在同一个恢复列表。
    var reviewMode: ReviewEditorMode?

    init(draft: HighlightDraft, original: Highlight?, originalEditionPages: [Int64: String]) {
        id = draft.id
        savedAt = Date()
        highlight = draft.highlight
        tagsText = draft.tagsText
        newSourceTitle = draft.newSourceTitle
        newSourceAuthor = draft.newSourceAuthor
        newSourceURL = draft.newSourceURL
        newSourceKind = draft.newSourceKind
        showNewSource = draft.showNewSource
        editionPages = draft.editionPages
        self.original = original
        self.originalEditionPages = originalEditionPages
    }

    var title: String {
        highlight.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? newSourceTitle.nilIfBlank ?? "未命名摘录"
    }

    var hasUnsavedChanges: Bool {
        let extra = !newSourceTitle.isEmpty || !newSourceAuthor.isEmpty || !newSourceURL.isEmpty || showNewSource
        if let original {
            return highlight != original || tagsText != TagParser.format(original.tags)
                || extra || editionPages != originalEditionPages
        }
        return !highlight.text.isEmpty || !(highlight.translation ?? "").isEmpty
            || !(highlight.note ?? "").isEmpty || !(highlight.location ?? "").isEmpty
            || !tagsText.isEmpty || extra || !editionPages.isEmpty
    }

    /// 原条目在草稿之后有变化（含删除、回顾状态变化或版次页码变化）时恢复成新摘录。
    /// 用户仍可继续编辑，正式数据及其回顾进度不会被旧快照覆盖。
    func restored(current: Highlight?, currentEditionPages: [Int64: String] = [:],
                  now: Date = Date()) -> HighlightDraftRecovery {
        var recovered = highlight
        var notice: String?
        if highlight.id != nil,
           original == nil || current != original || currentEditionPages != originalEditionPages {
            recovered.id = nil
            recovered.createdAt = now
            recovered.updatedAt = now
            recovered.deletedAt = nil
            recovered.lastSurfacedAt = nil
            recovered.surfacedCount = 0
            recovered.masteryHalfLifeDays = nil
            recovered.masteryLastReviewedAt = nil
            notice = "原摘录已更新或删除。为保留现有数据，这份草稿已作为新摘录打开。"
        }
        var draft = HighlightDraft(highlight: recovered, tagsText: tagsText)
        draft.id = id
        draft.newSourceTitle = newSourceTitle
        draft.newSourceAuthor = newSourceAuthor
        draft.newSourceURL = newSourceURL
        draft.newSourceKind = newSourceKind
        draft.showNewSource = showNewSource
        draft.editionPages = editionPages
        return HighlightDraftRecovery(draft: draft, notice: notice)
    }
}

struct SavedCardDraft: Codable, Identifiable {
    var id: UUID
    var savedAt: Date
    var card: Card
    var tagsText: String
    var original: Card?

    init(draft: CardDraft, original: Card?) {
        id = draft.id
        savedAt = Date()
        card = draft.card
        tagsText = draft.tagsText
        self.original = original
    }

    var title: String {
        (card.fields.first ?? card.front).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "未命名记忆卡"
    }

    var hasUnsavedChanges: Bool {
        if let original { return card != original || tagsText != TagParser.format(original.tags) }
        return !card.front.isEmpty || !card.back.isEmpty || card.fields.contains { !$0.isEmpty }
            || !tagsText.isEmpty || (card.sections ?? []).contains { !$0.name.isEmpty || !$0.text.isEmpty }
    }

    func restored(current: Card?, now: Date = Date()) -> CardDraftRecovery {
        var recovered = card
        var notice: String?
        if card.id != nil, original == nil || current != original {
            recovered.id = nil
            recovered.createdAt = now
            recovered.updatedAt = now
            recovered.deletedAt = nil
            recovered.ankiGuid = nil
            recovered.state = .new
            recovered.step = 0
            recovered.interval = 0
            recovered.ease = 2.5
            recovered.due = now
            recovered.reps = 0
            recovered.lapses = 0
            recovered.isSuspended = false
            recovered.stability = nil
            recovered.difficulty = nil
            recovered.lastReview = nil
            notice = "原记忆卡已更新或删除。草稿已作为新卡打开，原卡及其学习进度已保留。"
        }
        var draft = CardDraft(card: recovered, tagsText: tagsText)
        draft.id = id
        return CardDraftRecovery(draft: draft, notice: notice)
    }
}
