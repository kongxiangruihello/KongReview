import Foundation
import Observation
import KongGleanCore

/// 侧边栏导航
enum SidebarItem: Hashable {
    case review
    case all
    case favorites
    case mastery
    case unsorted
    case source(Int64)
    case tag(String)
}

/// 全局状态：持有数据库，缓存出处与标签列表，并在写入后通知界面刷新。
@MainActor
@Observable
final class LibraryStore {
    let db: AppDatabase

    var sources: [Source] = []
    var highlightCounts: [Int64: Int] = [:]
    var tags: [String] = []

    var selection: SidebarItem? = .review
    /// 正在编辑/新建的摘录草稿；非空时弹出编辑面板
    var editorDraft: HighlightDraft?
    var editingSource: Source?
    var errorMessage: String?

    /// 每次写入后递增，列表视图据此重新查询
    private(set) var revision = 0

    init(db: AppDatabase) {
        self.db = db
        reload()
    }

    func reload() {
        do {
            sources = try db.allSources()
            highlightCounts = try db.highlightCounts()
            tags = try db.allTags()
            revision += 1
        } catch {
            report(error)
        }
    }

    func source(for highlight: Highlight) -> Source? {
        guard let id = highlight.sourceId else { return nil }
        return sources.first { $0.id == id }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    // MARK: 写操作（统一在这里做，写完刷新）

    func perform(_ work: () throws -> Void) {
        do {
            try work()
            reload()
        } catch {
            report(error)
        }
    }

    func save(_ highlight: Highlight) {
        perform { try db.save(highlight) }
    }

    func save(_ source: Source) {
        perform { try db.save(source) }
    }

    func delete(_ highlight: Highlight) {
        perform { try db.delete(highlight) }
    }

    func delete(_ source: Source) {
        perform { try db.delete(source) }
        if case .source(let id) = selection, id == source.id { selection = .all }
    }

    // MARK: 新建与捕获

    func newHighlight(in sourceId: Int64? = nil) {
        editorDraft = HighlightDraft(highlight: Highlight(sourceId: sourceId, text: ""))
    }

    func edit(_ highlight: Highlight) {
        editorDraft = HighlightDraft(highlight: highlight, tagsText: TagParser.format(highlight.tags))
    }

    /// kongglean://add 链接：先放进编辑面板，让用户补页码、标签后再保存
    func handle(url: URL) {
        guard let capture = CaptureRequest(url: url) else { return }
        var draft = HighlightDraft(highlight: Highlight(
            text: capture.text,
            note: capture.note,
            location: capture.location,
            tags: capture.tags
        ))
        draft.tagsText = TagParser.format(capture.tags)
        if let url = capture.url,
           let existing = sources.first(where: { $0.url == url }) {
            draft.highlight.sourceId = existing.id
        } else if let title = capture.title ?? capture.url {
            draft.newSourceTitle = title
            draft.newSourceAuthor = capture.author ?? ""
            draft.newSourceURL = capture.url ?? ""
            draft.newSourceKind = capture.url == nil ? .book : .web
        }
        editorDraft = draft
    }

    /// 保存编辑面板的内容
    func commit(_ draft: HighlightDraft) {
        perform {
            var h = draft.highlight
            h.tags = TagParser.parse(draft.tagsText)
            h.text = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
            h.translation = h.translation?.nilIfBlank
            h.note = h.note?.nilIfBlank
            h.location = h.location?.nilIfBlank
            let title = draft.newSourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let s = try db.findOrCreateSource(
                    title: title,
                    author: draft.newSourceAuthor.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: draft.newSourceKind,
                    url: draft.newSourceURL.nilIfBlank
                )
                h.sourceId = s.id
            }
            try db.save(h)
        }
        editorDraft = nil
    }
}

/// 编辑面板的草稿
struct HighlightDraft: Identifiable {
    let id = UUID()
    var highlight: Highlight
    var tagsText: String = ""
    // 新建出处（填写了标题时优先于下拉选择）
    var newSourceTitle: String = ""
    var newSourceAuthor: String = ""
    var newSourceURL: String = ""
    var newSourceKind: SourceKind = .book

    var isNew: Bool { highlight.id == nil }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
