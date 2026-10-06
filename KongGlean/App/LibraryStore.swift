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
    case trash
    case articles
    case sourceManager
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
    var trashCount = 0
    var articleCount = 0

    var selection: SidebarItem? = .review
    /// 正在编辑/新建的摘录草稿；非空时弹出编辑面板
    var editorDraft: HighlightDraft?
    var editingSource: Source?
    /// 等待确认删除的出处
    var sourcePendingDeletion: Source?
    /// 是否正在确认“清空最近删除”
    var confirmingEmptyTrash = false
    /// 待确认的 Readwise 导入（非空时弹出预览面板）
    var pendingImport: ImportPreview?
    /// 导入时给每条摘录加上 #Readwise 标签
    var importAddTag = true
    /// 操作完成后的提示
    var infoMessage: String?
    /// 后台导入进行中时的状态文字（非空表示正忙）
    var importProgress: String?

    // 网页存档
    /// 正在阅读的文章（非空时“网页存档”页显示阅读器）
    var openArticle: Article?
    /// “添加网页”面板里输入的网址（非空时弹出面板）
    var addArticleDraft: AddArticleDraft?
    /// 抓取进行中的状态文字
    var articleProgress: String?
    var articlePendingDeletion: Article?

    // 批量与导出
    var batchPrompt: BatchPrompt?
    var exportRequest: ExportRequest?
    var mergeRequest: MergeRequest?
    var sourcesPendingDeletion: [Source] = []
    var sourceSort: SourceSort = SourceSort.current {
        didSet { SourceSort.current = sourceSort; sortSources() }
    }
    var errorMessage: String?

    /// 各界面的局部状态放在这里（见 ViewState.swift），避免使用 @State
    let review = ReviewState()
    let list = ListState()

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
            sortSources()
            tags = try db.allTags()
            trashCount = try db.trashCount()
            articleCount = try db.articleCount()
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

    /// 删除 = 移入“最近删除”，30 天内可恢复
    func delete(_ highlight: Highlight) {
        perform { try db.moveToTrash(highlight) }
    }

    func restore(_ highlight: Highlight) {
        perform { try db.restore(highlight) }
    }

    func deletePermanently(_ highlight: Highlight) {
        perform { try db.deletePermanently(highlight) }
    }

    func emptyTrash() {
        perform { try db.emptyTrash() }
    }

    /// 执行待确认的 Readwise 导入：先自动备份，再在一个事务里导入
    ///（上万条时需要十几秒，所以放到后台线程，界面不会卡住）
    func confirmImport() {
        guard let preview = pendingImport, importProgress == nil else { return }
        let db = self.db
        let tag = importAddTag ? "Readwise" : nil
        importProgress = "正在备份现有数据…"
        Task.detached(priority: .userInitiated) {
            do {
                try BackupService.backupNow(db: db)
                await MainActor.run {
                    self.importProgress = "正在导入 \(preview.result.highlightCount) 条摘录，请稍候…"
                }
                let r = try db.importReadwise(preview.result, extraTag: tag)
                await MainActor.run { self.finishImport(r, preview: preview) }
            } catch {
                await MainActor.run {
                    self.importProgress = nil
                    self.report(error)
                }
            }
        }
    }

    private func finishImport(_ r: ImportReport, preview: ImportPreview) {
        var lines = ["导入 \(r.highlightsImported) 条摘录。"]
        lines.append("新建出处 \(r.sourcesCreated) 个，并入已有出处 \(r.sourcesReused) 个。")
        if r.duplicatesSkipped > 0 { lines.append("跳过重复摘录 \(r.duplicatesSkipped) 条（已存在，或文件内重复）。") }
        if preview.result.skippedRows > 0 { lines.append("跳过没有正文的行 \(preview.result.skippedRows) 行。") }
        lines.append("导入前的数据已自动备份。")
        importProgress = nil
        pendingImport = nil
        reload()
        selection = .all
        infoMessage = lines.joined(separator: "\n")
    }

    // MARK: 出处排序

    func sortSources() {
        switch sourceSort {
        case .recent:
            sources.sort { $0.createdAt > $1.createdAt }
        case .count:
            sources.sort { (highlightCounts[$0.id ?? -1] ?? 0) > (highlightCounts[$1.id ?? -1] ?? 0) }
        case .title:
            sources.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: 批量操作

    func batch(_ action: BatchAction, ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let scheduler = ReviewScheduler()
        perform {
            switch action {
            case .favorite(let on):
                try db.modifyHighlights(ids: ids) { $0.isFavorite = on }
            case .discard(let on):
                try db.modifyHighlights(ids: ids) { $0.isDiscarded = on }
            case .addTags(let tags):
                try db.modifyHighlights(ids: ids) { h in
                    for t in tags where !h.tags.contains(t) { h.tags.append(t) }
                }
            case .removeTags(let tags):
                try db.modifyHighlights(ids: ids) { h in h.tags.removeAll { tags.contains($0) } }
            case .move(let sourceId):
                try db.modifyHighlights(ids: ids) { $0.sourceId = sourceId }
            case .addToMastery:
                try db.modifyHighlights(ids: ids) { h in
                    if !h.isInMastery { h = scheduler.addToMastery(h) }
                }
            case .delete:
                let now = Date()
                try db.modifyHighlights(ids: ids) { $0.deletedAt = now }
            }
        }
        if case .delete = action { list.selection.subtract(ids) }
        if case .move = action { list.selection.subtract(ids) }
    }

    func commitBatchPrompt() {
        guard let p = batchPrompt else { return }
        switch p.kind {
        case .addTags: batch(.addTags(TagParser.parse(p.text)), ids: p.ids)
        case .removeTags: batch(.removeTags(TagParser.parse(p.text)), ids: p.ids)
        case .move: break   // 移动在选择出处时直接执行
        }
        batchPrompt = nil
    }

    /// 被选摘录共有的标签（去标签时作为候选）
    func tags(of ids: [Int64]) -> [String] {
        let hs = (try? db.highlights(ids: ids)) ?? []
        var seen: [String] = []
        for h in hs { for t in h.tags where !seen.contains(t) { seen.append(t) } }
        return seen
    }

    // MARK: 出处管理

    func requestMerge(_ ids: [Int64]) {
        let all = (try? db.sourcesWithCounts()) ?? []
        let chosen = all.filter { ids.contains($0.source.id ?? -1) }.sorted { $0.count > $1.count }
            .map { MergeRequest.Candidate(source: $0.source, count: $0.count) }
        guard chosen.count >= 2, let target = chosen.first?.source.id else { return }
        mergeRequest = MergeRequest(sources: chosen, target: target)
    }

    func commitMerge() {
        guard let m = mergeRequest else { return }
        let ids = m.sources.compactMap(\.source.id)
        do {
            try BackupService.backupNow(db: db)
        } catch {
            report(error)
            return
        }
        perform { try db.mergeSources(ids, into: m.target) }
        mergeRequest = nil
        if case .source(let id) = selection, ids.contains(id), id != m.target { selection = .source(m.target) }
    }

    func setKind(_ kind: SourceKind, for ids: [Int64]) {
        perform { try db.setKind(kind, forSources: ids) }
    }

    func commitDeleteSources() {
        let ids = sourcesPendingDeletion.compactMap(\.id)
        perform { try db.deleteSources(ids) }
        sourcesPendingDeletion = []
        if case .source(let id) = selection, ids.contains(id) { selection = .sourceManager }
    }

    // MARK: 网页存档

    func open(_ article: Article) {
        selection = .articles
        // 列表里的条目不含正文，打开时取全文
        openArticle = article.id.flatMap { try? db.article(id: $0) } ?? article
        if let id = article.id { try? db.markArticleOpened(id: id) }
    }

    func closeArticle() {
        openArticle = nil
        revisionBump()
    }

    /// 在阅读器里划线：存为该文章出处下的一条摘录
    func addHighlight(from article: Article, text raw: String) {
        let text = ArticleText.cleanSelection(raw)
        guard !text.isEmpty else { return }
        perform {
            try db.save(Highlight(sourceId: article.sourceId, text: text))
        }
    }

    func deleteArticle(_ article: Article) {
        guard let id = article.id else { return }
        perform { try db.deleteArticle(id: id) }
        if openArticle?.id == id { openArticle = nil }
    }

    func revisionBump() { revision += 1 }

    /// 启动时的例行维护：清除过期的“最近删除”，并做当天的自动备份
    func runStartupMaintenance() {
        perform { try db.purgeTrash(olderThan: TrashPolicy.cutoff(now: Date())) }
        do {
            try BackupService.backupIfNeeded(db: db)
        } catch {
            report(error)
        }
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

    /// 保存编辑面板的内容并关闭面板
    func commit(_ draft: HighlightDraft) {
        if save(draft: draft) { editorDraft = nil }
    }

    /// 保存一份草稿（主窗口编辑器与快速录入浮窗共用）；成功返回 true
    @discardableResult
    func save(draft: HighlightDraft) -> Bool {
        var ok = false
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
            ok = true
        }
        return ok
    }
}

/// “添加网页”面板
struct AddArticleDraft: Identifiable {
    let id = UUID()
    var urlText = ""
    var error: String?
}

/// Readwise 导入预览
struct ImportPreview: Identifiable {
    let id = UUID()
    var fileName: String
    var result: ReadwiseCSVImporter.Result
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
    /// 是否展开“新建出处”表单
    var showNewSource = false

    var isNew: Bool { highlight.id == nil }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
