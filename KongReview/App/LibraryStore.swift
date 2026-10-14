import Foundation
import Observation
import KongReviewCore

/// 侧边栏导航
enum SidebarItem: Hashable {
    case review
    case all
    case favorites
    case cards
    case stats
    case unsorted
    case trash
    case articles
    case sourceManager
    case help
    case saved(String)
    case notebook(Int64)
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
    /// 1.1：分层标签树（“儒家/孟子”），含各标签摘录数
    var tagTree: [TagNode] = []
    var tagCountMap: [String: Int] = [:]
    var tagEditor: TagEditRequest?
    var showTagManager = false
    /// 1.2：参考文献表
    var bibliographyRequest: BibliographyRequest?
    /// 1.3：专题笔记本列表、各本摘录数、当前打开的笔记本
    var notebooks: [Notebook] = []
    var notebookQuoteCounts: [Int64: Int] = [:]
    var notebookState = NotebookState()
    /// 1.3：新建笔记本对话框（输入标题）；附带要放进去的摘录
    var newNotebookRequest: NewNotebookRequest?
    /// 1.3：确认删除笔记本
    var notebookPendingDeletion: Notebook?
    /// 1.5：查找重复摘录的结果（非 nil 时显示整理面板）
    var duplicateReview: DuplicateReview?
    /// 1.5：久未回顾的统计（数据变化时刷新）
    var staleSummary = AppDatabase.StaleSummary()
    @ObservationIgnored var mergeBackupDone = false
    /// 1.3：每周小结（按周缓存）
    @ObservationIgnored var weeklyDigestCache: WeeklyDigest?
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
    /// LiquidText 导入：跳过很短的摘录
    var importSkipShort = false
    /// 1.2：LiquidText 文件夹正在后台检查
    @ObservationIgnored var liquidTextChecking = false
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
    let study = StudyState()

    /// 侧边栏“出处”分组是否展开（默认折叠，记住上次状态）
    var sourcesExpanded: Bool = UserDefaults.standard.bool(forKey: "sidebar.sourcesExpanded") {
        didSet { UserDefaults.standard.set(sourcesExpanded, forKey: "sidebar.sourcesExpanded") }
    }
    /// 侧边栏“标签”分组是否展开（默认折叠）
    var tagsExpanded: Bool = UserDefaults.standard.bool(forKey: "sidebar.tagsExpanded") {
        didSet { UserDefaults.standard.set(tagsExpanded, forKey: "sidebar.tagsExpanded") }
    }
    /// 当前日期（yyyy-MM-dd）；跨日时更新，回顾页据此换新
    var today: String = ReminderPlan.dayKey(Date())
    /// 已做成记忆卡的摘录
    var cardHighlightIDs: Set<Int64> = []
    var cardCount = 0
    var cardImport: CardImportPreview?
    var cardEditor: CardDraft?
    var articleSourceDraft: ArticleSourceDraft?
    /// 今天是否已回顾（决定是否还要提醒）
    var reviewedToday = false
    /// 笔记类型模板（多字段卡片按它显示）
    var noteTemplates: [String: NoteTemplate] = [:]
    var deckOptionsEditor: DeckOptions?
    var templateEditor: NoteTemplate?
    var apkgExport: ApkgExportRequest?
    var cardSyncOffer: CardSyncOffer?
    /// FSRS 优化、整理数据库等后台任务的状态文字
    var maintenanceProgress: String?
    /// 每次刷新后调用（菜单栏数字、提醒内容）
    var onReload: (() -> Void)?
    /// 有封面的出处
    var coverIDs: Set<Int64> = []
    /// 封面变化计数（界面据此重新加载图片）
    var coverRevision = 0
    /// 填空卡制作面板
    var clozeDraft: ClozeDraft?
    /// 生成分享图的摘录
    var shareImageHighlight: Highlight?
    /// 已存搜索
    var savedSearches: [SavedSearch] = SavedSearch.all()
    /// 正在保存当前搜索（非空时弹出命名框）
    var savingSearchName: String?

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
            tagCountMap = try db.tagCounts()
            tagTree = TagNode.tree(tagCountMap)
            trashCount = try db.trashCount()
            articleCount = try db.articleCount()
            cardHighlightIDs = try db.cardHighlightIDs()
            cardCount = try db.cardCount()
            reviewedToday = try db.reviewedToday()
            noteTemplates = try db.noteTemplates()
            coverIDs = try db.coverSourceIDs()
            notebooks = try db.notebooks()
            notebookQuoteCounts = try db.notebookQuoteCounts()
            refreshDerived()
            revision += 1
            onReload?()
            scheduleRelatedRebuild()
            scheduleObsidianSync()
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
        AppLog.write("错误：\(error.localizedDescription)（\(String(describing: error))）")
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
        undoable("删除摘录", highlights: highlight.id.map { [$0] } ?? []) {
            perform { try db.moveToTrash(highlight) }
        }
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
        let tag = importAddTag ? preview.tag : nil
        let result = preview.origin == .liquidText && importSkipShort ? preview.withoutShort() : preview.result
        importProgress = "正在备份现有数据…"
        Task.detached(priority: .userInitiated) {
            do {
                try BackupService.backupNow(db: db)
                await MainActor.run {
                    self.importProgress = "正在导入 \(result.highlightCount) 条摘录，请稍候…"
                }
                if !preview.media.isEmpty { try db.saveMedia(preview.media) }
                let r = try db.importReadwise(result, extraTag: tag,
                                              keyPrefix: preview.origin == .liquidText ? LiquidTextFolder.keyPrefix : nil)
                AppLog.write("导入\(preview.tag)：\(r.highlightsImported) 条，重复跳过 \(r.duplicatesSkipped) 条")
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
        if preview.result.skippedRows > 0 {
            lines.append(preview.origin == .readwise ? "跳过没有正文的行 \(preview.result.skippedRows) 行。"
                                                     : "文件内重复或没有内容的笔记 \(preview.result.skippedRows) 条未导入。")
        }
        if !preview.media.isEmpty { lines.append("图片 \(preview.media.count) 张。") }
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
        if case .addToMastery = action {} else {
            // 批量改动可撤销（做成记忆卡另有“删除卡片”）
            let before = try? db.snapshot(highlightIds: ids)
            defer { if let before { registerUndo("批量操作（\(ids.count) 条）", before, reviewPosition: nil) } }
            batchWork(action, ids: ids)
            return
        }
        batchWork(action, ids: ids)
    }

    private func batchWork(_ action: BatchAction, ids: [Int64]) {
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
                _ = scheduler
                let n = try db.makeCards(fromHighlights: ids, style: CitationSettings.style)
                infoMessage = n > 0 ? "已做成 \(n) 张记忆卡（牌组“摘录”）。" : "所选摘录都已经有记忆卡了。"
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
        let before = try? db.snapshot(sourceIds: ids)
        defer { if let before { registerUndo("合并出处", before, reviewPosition: nil) } }
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
        let before = try? db.snapshot(sourceIds: ids)
        defer { if let before { registerUndo("删除出处", before, reviewPosition: nil) } }
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

    // MARK: 1.1：记忆卡负荷预测与保留率（统计页打开时计算）

    struct CardInsights {
        var counts: CardStateCounts
        var load: CardForecast.Load
        var retention: CardForecast.Retention
        var target: Double
        var computedAt: Date
    }
    var cardInsights: CardInsights?

    func refreshCardInsights(now: Date = Date()) {
        do {
            let counts = try db.cardStateCounts()
            let load = CardForecast.load(dues: try db.studiedCardDues(), now: now, days: 30)
            // 取 13 周 + 半年的作答：半年内的上一次作答足以判断“隔天复习”
            let since = Calendar.current.date(byAdding: .day, value: -(12 * 7 + 7 + 180), to: now) ?? now
            let retention = CardForecast.retention(try db.cardAnswers(since: since), now: now, weeks: 12)
            cardInsights = CardInsights(counts: counts, load: load, retention: retention,
                                        target: try db.targetRetention(), computedAt: now)
        } catch {
            report(error)
        }
    }

    // MARK: 1.1：标签整理

    func beginRenameTag(_ tag: String) {
        let n = (try? db.highlightIDs(withTag: tag).count) ?? 0
        tagEditor = TagEditRequest(tag: tag, mode: .rename, newName: tag, affected: n)
    }

    func beginDeleteTag(_ tag: String) {
        let n = (try? db.highlightIDs(withTag: tag).count) ?? 0
        tagEditor = TagEditRequest(tag: tag, mode: .delete, newName: "", affected: n)
    }

    /// 改名或合并（新名已存在即合并）；子标签、已存搜索、当前选中项一并更新。可撤销。
    func renameTag(_ old: String, to newName: String) {
        let new = TagOps.normalize(newName)
        guard !new.isEmpty, new != old else { return }
        let ids = (try? db.highlightIDs(withTag: old)) ?? []
        let merging = tags.contains(new)
        undoable(merging ? "合并标签" : "标签改名", highlights: ids) {
            perform { try db.renameTag(old, to: new) }
        }
        for i in savedSearches.indices {
            savedSearches[i].filter.tags = TagOps.rename(savedSearches[i].filter.tags, from: old, to: new)
        }
        SavedSearch.save(savedSearches)
        if case .tag(let t)? = selection, TagOps.isWithin(t, old) {
            selection = .tag(TagOps.rename([t], from: old, to: new).first ?? new)
        }
        AppLog.write("标签\(merging ? "合并" : "改名")：\(ids.count) 条摘录")
        revisionBump()
    }

    /// 从所有摘录上去掉这个标签（及其子标签）；摘录保留。可撤销。
    func deleteTag(_ tag: String) {
        let ids = (try? db.highlightIDs(withTag: tag)) ?? []
        undoable("删除标签", highlights: ids) {
            perform { try db.deleteTag(tag) }
        }
        for i in savedSearches.indices {
            savedSearches[i].filter.tags = TagOps.remove(savedSearches[i].filter.tags, tag: tag)
        }
        SavedSearch.save(savedSearches)
        if case .tag(let t)? = selection, TagOps.isWithin(t, tag) { selection = .all }
        revisionBump()
    }

    func revisionBump() {
        refreshDerived()
        revision += 1
    }

    // MARK: 1.0：撤销（⌘Z / ⇧⌘Z，用窗口的撤销管理器，菜单“编辑”里会显示操作名）

    /// 由主窗口登记（@Environment(\.undoManager)）
    @ObservationIgnored weak var undoManager: UndoManager?

    /// 先记快照，再执行改动，最后登记撤销
    func undoable(_ name: String, highlights: [Int64] = [], sources: [Int64] = [], cards: [Int64] = [],
                  reviewPosition: Int? = nil, _ work: () -> Void) {
        let before = try? db.snapshot(highlightIds: highlights, sourceIds: sources, cardIds: cards)
        work()
        if let before { registerUndo(name, before, reviewPosition: reviewPosition) }
    }

    private func registerUndo(_ name: String, _ snap: UndoSnapshot, reviewPosition: Int?) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.applyUndo(name, snap, reviewPosition: reviewPosition) }
        }
        um.setActionName(name)
    }

    /// 写回快照；同时记下写回前的状态，供“重做”
    private func applyUndo(_ name: String, _ snap: UndoSnapshot, reviewPosition: Int?) {
        let current = try? db.snapshot(highlightIds: snap.highlightIds, sourceIds: snap.sourceIds, cardIds: snap.cardIds)
        let currentPosition = review.position
        perform { try db.restore(snap) }
        if let p = reviewPosition { review.position = max(0, min(p, review.cards.count)) }
        if let current { registerUndo(name, current, reviewPosition: reviewPosition == nil ? nil : currentPosition) }
    }

    // MARK: 1.0：从备份恢复

    /// 恢复面板（非空时弹出）
    var backupList: BackupListRequest?
    /// 等待确认恢复的备份
    var pendingRestore: BackupInfo?

    func showBackups() {
        backupList = BackupListRequest(items: nil)
        Task.detached(priority: .userInitiated) {
            let items = BackupInfo.all()
            await MainActor.run { if self.backupList != nil { self.backupList?.items = items } }
        }
    }

    /// 先把当前数据另存一份“恢复前”备份，再用所选备份替换
    func restoreBackup(_ info: BackupInfo) {
        let db = self.db
        maintenanceProgress = "正在恢复备份…"
        pendingRestore = nil
        backupList = nil
        Task.detached(priority: .userInitiated) {
            do {
                let dir = try BackupService.directory()
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let safety = dir.appendingPathComponent("恢复前-\(stamp).sqlite")
                try db.backup(to: safety)
                try db.restore(from: info.url)
                AppLog.write("从备份恢复：\(info.url.lastPathComponent)；恢复前的数据另存为 \(safety.lastPathComponent)")
                await MainActor.run {
                    self.maintenanceProgress = nil
                    self.reload()
                    self.infoMessage = "已恢复到 \(info.date.formatted(date: .abbreviated, time: .shortened)) 的备份（\(info.highlights) 条摘录、\(info.cards) 张卡）。\n恢复前的数据另存为“\(safety.lastPathComponent)”，在备份文件夹里，需要时可以再恢复回来。"
                }
            } catch {
                await MainActor.run { self.maintenanceProgress = nil; self.report(error) }
            }
        }
    }

    // MARK: 1.0：缓存的统计（每次数据变化算一次，界面直接读，不在每次重绘时查库）

    /// 回顾统计（最近 30 天）
    var stats: ReviewStats.Summary = .empty
    /// 各牌组今天的新卡 / 学习中 / 待复习
    var deckSummaryCache: [DeckSummary] = []

    func refreshDerived() {
        staleSummary = (try? db.staleSummary()) ?? AppDatabase.StaleSummary()
        stats = (try? db.reviewSummary(now: Date(), days: 30)) ?? .empty
        deckSummaryCache = (try? db.deckSummaries(now: Date(), newPerDay: CardSettings.newPerDay,
                                                  reviewsPerDay: CardSettings.reviewsPerDay)) ?? []
    }

    // MARK: 1.0：相关摘录

    /// 相关摘录索引（后台建立；数据变化 10 秒后重建）
    var relatedIndex: RelatedIndex?
    private var relatedTask: Task<Void, Never>?

    func scheduleRelatedRebuild(delay: UInt64 = 10) {
        relatedTask?.cancel()
        let db = self.db
        let wait = relatedIndex == nil ? 1 : delay
        relatedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .utility) { () -> RelatedIndex? in
                guard let docs = try? db.relatedDocs() else { return nil }
                return RelatedIndex(docs)
            }.value
            if let built { self.relatedIndex = built }
        }
    }

    /// 与某条摘录相关的几条（含共有标签、是否同一出处）
    func related(to h: Highlight, limit: Int = 5) -> [RelatedItem] {
        guard let id = h.id, let idx = relatedIndex else { return [] }
        let hits = idx.related(to: id, limit: limit)
        let byId = Dictionary(uniqueKeysWithValues: ((try? db.highlights(ids: hits.map(\.id))) ?? []).compactMap { x in x.id.map { ($0, x) } })
        return hits.compactMap { hit in byId[hit.id].map { RelatedItem(highlight: $0, hit: hit) } }
    }

    // MARK: 回顾日志与提醒

    /// 记一次回顾动作；当天第一次回顾时取消今天的提醒
    func logReview(_ kind: ReviewEvent.Kind, highlightId: Int64? = nil) {
        db.log(ReviewEvent(kind: kind, highlightId: highlightId))
        if kind != .note && !reviewedToday {
            reviewedToday = true
            onReviewedToday?()
        }
    }

    /// 由提醒模块设置：今天首次回顾后调用（重排提醒，跳过今天）
    var onReviewedToday: (() -> Void)?

    /// 跨日检查：日期变了就刷新（回顾换新、统计、提醒）
    func checkDayChange() {
        let key = ReminderPlan.dayKey(Date())
        guard key != today else { return }
        today = key
        reload()
        onReviewedToday?()
    }

    // MARK: 记忆卡

    /// 单条摘录做成记忆卡（牌组“摘录”）；不弹提示，界面上的脑形图标会变色
    func makeCard(from highlight: Highlight) {
        guard let id = highlight.id else { return }
        perform { _ = try db.makeCards(fromHighlights: [id], style: CitationSettings.style) }
    }

    /// 回顾页顶部提示：所有牌组今天待学的卡片数
    func dueCardCount() -> Int {
        deckSummaryCache.reduce(0) { $0 + $1.counts.total }
    }

    func deleteCards(_ ids: [Int64]) {
        undoable("删除记忆卡", cards: ids) {
            perform { try db.deleteCards(ids) }
        }
    }

    func saveCard(_ card: Card) {
        perform { _ = try db.save(card) }
    }

    func editCard(_ card: Card) {
        cardEditor = CardDraft(card: card, tagsText: TagParser.format(card.tags))
    }

    func newCard(deck: String?) {
        cardEditor = CardDraft(card: Card(deck: deck ?? study.lastDeck ?? "默认", front: ""))
    }

    /// 保存卡片编辑面板；若正在学习的就是这张卡，同步刷新
    func commitCardEditor() {
        guard var d = cardEditor else { return }
        d.card.front = d.card.front.trimmingCharacters(in: .whitespacesAndNewlines)
        d.card.back = d.card.back.trimmingCharacters(in: .whitespacesAndNewlines)
        d.card.deck = d.card.deck.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "默认"
        d.card.tags = TagParser.parse(d.tagsText)
        d.card.updatedAt = Date()
        // 1.2：背面栏目——去掉首尾空白，名称与内容都空的栏目丢弃；记住用过的栏目名
        if let secs = d.card.sections {
            let cleaned = secs.map { s -> CardSection in
                var s = s
                s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
                s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return s
            }.filter { !$0.name.isEmpty || !$0.text.isEmpty }
            d.card.sections = cleaned.isEmpty ? nil : cleaned
            CardSettings.rememberSectionNames(cleaned.map(\.name))
        }
        // 多字段卡片：正面 / 背面存一份字段内容的拼接，供搜索与列表预览（显示仍按模板）
        if d.card.noteType != nil, !d.card.fields.isEmpty {
            d.card.front = d.card.fields[0]
            d.card.back = d.card.fields.dropFirst().filter { !$0.isEmpty }.joined(separator: "<hr>")
        }
        guard !d.card.front.isEmpty else { return }
        do {
            let saved = try db.save(d.card)
            study.lastDeck = saved.deck
            if study.current?.id == saved.id { study.current = saved }
            cardEditor = nil
            reload()
        } catch {
            report(error)
        }
    }

    /// 暂停 / 恢复
    func setSuspended(_ on: Bool, cards ids: [Int64]) {
        perform {
            for id in ids {
                if var c = try db.card(id: id) { c.isSuspended = on; c.updatedAt = Date(); _ = try db.save(c) }
            }
        }
    }

    func moveCards(_ ids: [Int64], toDeck deck: String) {
        perform {
            for id in ids {
                if var c = try db.card(id: id) { c.deck = deck; c.updatedAt = Date(); _ = try db.save(c) }
            }
        }
    }

    func renameDeck(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        perform { try db.renameDeck(old, to: name) }
    }

    func startStudy(deck: String) {
        study.deck = deck
        study.lastDeck = deck
        study.browsingDeck = nil
        nextCard()
    }

    /// 学习：取下一张（按牌组自己的每日上限）
    func nextCard(now: Date = Date()) {
        guard let deck = study.deck else { return }
        let cards = (try? db.cards(deck: deck)) ?? []
        let done = (try? db.studiedToday(deck: deck, now: now)) ?? (new: 0, review: 0)
        let o = options(for: deck)
        study.current = StudyQueue.next(from: cards, now: now,
                                        newLimitLeft: (o.newPerDay ?? CardSettings.newPerDay) - done.new,
                                        reviewLimitLeft: (o.reviewsPerDay ?? CardSettings.reviewsPerDay) - done.review)
        study.showingAnswer = false
        study.finished = study.current == nil
    }

    /// 牌组的有效选项（未设置的项用全局默认）
    func options(for deck: String) -> DeckOptions {
        (try? db.effectiveOptions(deck, defaults: CardSettings.defaults)) ?? DeckOptions(deck: deck)
    }

    /// 这个牌组用的排程算法
    func scheduler(forDeck deck: String) -> any CardScheduling {
        options(for: deck).scheduler(parameters: CardSettings.fsrsParameters)
    }

    /// 卡片实际显示的正反面（多字段卡片按模板）
    func faces(of card: Card) -> (front: String, back: String) {
        card.faces(using: card.noteType.flatMap { noteTemplates[$0] })
    }

    func answerCurrent(_ a: CardAnswer) {
        guard let c = study.current else { return }
        do {
            _ = try db.answer(c, a, scheduler: scheduler(forDeck: c.deck))
            if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        } catch {
            report(error)
        }
        nextCard()
        revisionBump()
    }

    // MARK: 0.9：封面、频率、填空卡、已存搜索、Obsidian、收件箱

    func setCover(_ data: Data?, for sourceId: Int64) {
        perform { try db.setCover(sourceId: sourceId, data: data) }
        coverRevision += 1
    }

    /// 单条摘录的回顾频率：1 多出现、-1 少出现、nil 正常
    func setFrequency(_ value: Int?, for highlight: Highlight) {
        guard let id = highlight.id else { return }
        undoable("调整回顾频率", highlights: [id]) {
            perform { try db.setFrequency(value, highlightId: id) }
        }
    }

    func startCloze(for highlight: Highlight) {
        let src = source(for: highlight)
        var back: [String] = []
        if let t = highlight.translation, !t.isEmpty { back.append(t) }
        if let n = highlight.note, !n.isEmpty { back.append("按：" + n) }
        let cite = CitationFormatter.citation(for: highlight, source: src, style: CitationSettings.style)
        if !cite.isEmpty { back.append("—— " + cite) }
        clozeDraft = ClozeDraft(highlightId: highlight.id, text: highlight.text,
                                extra: back.joined(separator: "\n\n"), deck: study.lastDeck ?? "填空", tags: highlight.tags)
    }

    /// 按填空编号生成卡片（与 Anki 相同：c1、c2… 各一张）
    func commitCloze() {
        guard let d = clozeDraft else { return }
        let numbers = AnkiContent.clozeNumbers(d.text)
        guard !numbers.isEmpty else { return }
        let extra = Markdown.html(d.extra)
        perform {
            for n in numbers {
                let c = AnkiContent.cloze(Markdown.html(d.text), number: n)
                let back = extra.isEmpty ? c.back : c.back + "<hr>" + extra
                _ = try db.save(Card(deck: d.deck.nilIfBlank ?? "填空", front: c.front, back: back, tags: d.tags,
                                     highlightId: d.highlightId))
            }
        }
        study.lastDeck = d.deck
        clozeDraft = nil
        infoMessage = "已生成 \(numbers.count) 张填空卡（牌组“\(d.deck)”）。"
    }

    func saveCurrentSearch(named name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        savedSearches.append(SavedSearch(name: n, text: list.query, filter: list.extra))
        SavedSearch.save(savedSearches)
        savingSearchName = nil
    }

    func deleteSavedSearch(_ id: String) {
        savedSearches.removeAll { $0.id == id }
        SavedSearch.save(savedSearches)
        if case .saved(let cur) = selection, cur == id { selection = .all }
    }

    func renameSavedSearch(_ id: String, to name: String) {
        guard let i = savedSearches.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        savedSearches[i].name = name
        SavedSearch.save(savedSearches)
    }

    private var obsidianTask: Task<Void, Never>?

    /// 数据变化后 3 秒同步一次 Obsidian（连续修改只同步最后一次）
    func scheduleObsidianSync() {
        guard ObsidianSync.isEnabled, let folder = ObsidianSync.folder else { return }
        obsidianTask?.cancel()
        let db = self.db
        let style = CitationSettings.style
        obsidianTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                _ = try? ObsidianSync.run(db: db, to: folder, style: style)
            }.value
        }
    }

    /// 立即同步（设置里的按钮）
    func syncObsidianNow() {
        guard let folder = ObsidianSync.folder else { return }
        let db = self.db
        let style = CitationSettings.style
        maintenanceProgress = "正在同步到 Obsidian…"
        Task.detached(priority: .userInitiated) {
            let result = Result { try ObsidianSync.run(db: db, to: folder, style: style) }
            await MainActor.run {
                self.maintenanceProgress = nil
                switch result {
                case .success(let r): self.infoMessage = "已同步到 \(folder.lastPathComponent)：写入 \(r.written) 个文件，\(r.unchanged) 个没有变化。"
                case .failure(let e): self.report(e)
                }
            }
        }
    }

    /// 1.2：检查 LiquidText 导出文件夹（后台读取与导入，有新摘录时提示）
    func checkLiquidTextFolder(quiet: Bool = true, force: Bool = false) {
        guard LiquidTextFolder.isEnabled || force, LiquidTextFolder.folder != nil, !liquidTextChecking else {
            if !quiet && LiquidTextFolder.folder == nil { infoMessage = "还没有选择 LiquidText 导出文件夹。" }
            return
        }
        liquidTextChecking = true
        let db = self.db
        Task.detached(priority: .utility) {
            let r = LiquidTextFolder.process(db: db, force: force)
            await MainActor.run {
                self.liquidTextChecking = false
                if r.added > 0 { self.reload() }
                var lines: [String] = []
                if r.added > 0 {
                    lines.append("从 LiquidText 导入 \(r.added) 条新摘录：" + r.sources.map { "《\($0)》" }.joined(separator: "、") + "。"
                                 + (r.images > 0 ? "含图片。" : ""))
                }
                if r.duplicates > 0 && (!quiet || r.added > 0) { lines.append("\(r.duplicates) 条以前导入过，跳过。") }
                if !r.failed.isEmpty { lines.append("无法导入：\n" + r.failed.joined(separator: "\n")) }
                if lines.isEmpty && !quiet { lines.append(r.files == 0 ? "文件夹里没有新的或改动过的笔记文件。" : "没有新摘录。") }
                if !lines.isEmpty { self.infoMessage = lines.joined(separator: "\n") }
            }
        }
    }

    /// 检查收件箱；有新摘录时提示
    func checkInbox(quiet: Bool = true) {
        checkLiquidTextFolder(quiet: true)
        let r = InboxService.process(db: db)
        guard r.files > 0 else {
            if !quiet { infoMessage = "收件箱里没有新文件。" }
            return
        }
        reload()
        var lines: [String] = []
        if r.added > 0 { lines.append("从收件箱导入 \(r.added) 条摘录：" + r.sources.joined(separator: "、") + "。") }
        if r.duplicates > 0 { lines.append("\(r.duplicates) 条已导入过，跳过。") }
        if !r.failed.isEmpty { lines.append("无法导入（已移到“出错”文件夹）：\n" + r.failed.joined(separator: "\n")) }
        if !lines.isEmpty && (r.added > 0 || !r.failed.isEmpty || !quiet) { infoMessage = lines.joined(separator: "\n") }
    }

    // MARK: 牌组选项、模板、FSRS、整理

    func saveDeckOptions(_ o: DeckOptions) {
        let before = options(for: o.deck).algorithm
        perform {
            try db.save(o)
            // 从 SM-2 改用 FSRS：按复习记录算出各卡的记忆状态
            if before != .fsrs && o.algorithm == .fsrs {
                _ = try db.recomputeMemory(parameters: CardSettings.fsrsParameters, decks: [o.deck])
            }
        }
        deckOptionsEditor = nil
    }

    func saveTemplate(_ t: NoteTemplate) {
        perform { try db.save(t) }
        templateEditor = nil
    }

    /// 用全部复习记录优化 FSRS 参数（后台进行），然后重算使用 FSRS 的牌组的记忆状态
    func optimizeFSRS() {
        guard maintenanceProgress == nil else { return }
        maintenanceProgress = "正在用复习记录优化 FSRS 参数…"
        let db = self.db
        Task.detached(priority: .userInitiated) {
            do {
                let histories = Array(try db.fsrsHistories().values)
                let r = FSRSOptimizer.optimize(histories)
                let fsrsDecks = Set(try db.deckOptions().values.filter { $0.algorithm == .fsrs }.map(\.deck))
                let updated = r.improved ? try db.recomputeMemory(parameters: r.parameters, decks: fsrsDecks) : 0
                await MainActor.run {
                    self.maintenanceProgress = nil
                    let fmt = { (v: Double) in String(format: "%.4f", v) }
                    if r.reviewCount < FSRSOptimizer.minimumReviews {
                        self.infoMessage = "跨日复习记录只有 \(r.reviewCount) 条，至少要 \(FSRSOptimizer.minimumReviews) 条才能可靠地优化。先继续用默认参数。"
                    } else if r.improved {
                        CardSettings.fsrsParameters = r.parameters
                        let info = "\(Date().formatted(date: .abbreviated, time: .omitted)) 用 \(r.reviewCount) 条复习记录优化，对数损失 \(fmt(r.lossBefore)) → \(fmt(r.lossAfter))"
                        CardSettings.fsrsInfo = info
                        self.infoMessage = "FSRS 参数已优化。\n\(info)。\n已按新参数重算 \(updated) 张卡的记忆状态（只影响以后的间隔，不改已排好的到期日）。"
                    } else {
                        self.infoMessage = "用 \(r.reviewCount) 条复习记录试过，没找到比当前更好的参数（在留出的检验记录上没有改进），参数保持不变。"
                    }
                    self.reload()
                }
            } catch {
                await MainActor.run { self.maintenanceProgress = nil; self.report(error) }
            }
        }
    }

    func resetFSRS() {
        UserDefaults.standard.removeObject(forKey: CardSettings.fsrsParamsKey)
        CardSettings.fsrsInfo = nil
        let decks = Set(((try? db.deckOptions()) ?? [:]).values.filter { $0.algorithm == .fsrs }.map(\.deck))
        perform { _ = try db.recomputeMemory(parameters: FSRS.defaultParameters, decks: decks) }
        infoMessage = "已恢复 FSRS 默认参数。"
    }

    /// 整理数据库：先备份，再删掉没有卡片引用的图片、VACUUM 收回空间
    func compactDatabase() {
        guard maintenanceProgress == nil else { return }
        maintenanceProgress = "正在整理数据库…"
        let db = self.db
        Task.detached(priority: .userInitiated) {
            do {
                try BackupService.backupNow(db: db)
                let r = try db.compact()
                await MainActor.run {
                    self.maintenanceProgress = nil
                    let f = ByteCountFormatter()
                    self.infoMessage = "整理完成：\(f.string(fromByteCount: r.bytesBefore)) → \(f.string(fromByteCount: r.bytesAfter))。"
                        + (r.mediaRemoved > 0 ? "删除没有卡片使用的图片 \(r.mediaRemoved) 个。" : "")
                        + "\n整理前已自动备份。"
                    self.reload()
                }
            } catch {
                await MainActor.run { self.maintenanceProgress = nil; self.report(error) }
            }
        }
    }

    /// 菜单栏与提醒用：今天还没看的摘录条数、待学的卡数
    func todayCounts() -> (highlights: Int, cards: Int) {
        let rec = ReviewSessionRecordStore.load()
        let highlights: Int
        if let rec, rec.day == ReminderPlan.dayKey(Date()) {
            highlights = max(0, rec.total - rec.position)
        } else {
            highlights = reviewedToday ? 0 : (UserDefaults.standard.object(forKey: "review.dailyCount") as? Int ?? 10)
        }
        return (highlights, dueCardCount())
    }

    func confirmCardImport() {
        guard let p = cardImport else { return }
        do {
            try BackupService.backupNow(db: db)
            let r = try db.importAnki(p.notes, media: p.media)
            var lines = ["导入 \(r.imported) 张记忆卡。"]
            if r.duplicates > 0 { lines.append("已导入过的 \(r.duplicates) 张没有重复建卡\(r.upgraded > 0 ? "，其中 \(r.upgraded) 张补上了字段 / 记忆状态" : "")。") }
            if r.media > 0 { lines.append("图片等媒体文件 \(r.media) 个。") }
            if r.revlog > 0 { lines.append("复习记录 \(r.revlog) 条（用于统计与 FSRS 参数优化）。") }
            if r.templates > 0 { lines.append("新建笔记类型模板 \(r.templates) 个，可在“记忆卡 → 卡片模板”调整正反面显示哪些字段。") }
            if !r.fsrsDecks.isEmpty { lines.append("沿用 Anki 的设置，这些牌组使用 FSRS：" + r.fsrsDecks.joined(separator: "、")) }
            if !r.decks.isEmpty { lines.append("牌组：" + r.decks.joined(separator: "、")) }
            lines.append("导入前的数据已自动备份。")
            infoMessage = lines.joined(separator: "\n")
            cardImport = nil
            reload()
            selection = .cards
        } catch {
            report(error)
        }
    }

    func saveArticleSource() {
        guard let d = articleSourceDraft else { return }
        perform { try db.updateArticleContent(id: d.articleId, html: d.html) }
        if openArticle?.id == d.articleId { openArticle = try? db.article(id: d.articleId) }
        articleSourceDraft = nil
    }

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
        let before = source.id.flatMap { try? db.snapshot(sourceIds: [$0]) }
        defer { if let before { registerUndo("删除出处", before, reviewPosition: nil) } }
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

    /// kongreview://add 链接：先放进编辑面板，让用户补页码、标签后再保存
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
        guard save(draft: draft) else { return }
        editorDraft = nil
        offerCardSync(for: draft.highlight.id)
    }

    /// 1.2：回顾卡片上就地编辑后保存（与编辑面板一样，摘录已做成记忆卡时按设置同步或询问）
    func saveEdited(_ highlight: Highlight) {
        save(highlight)
        offerCardSync(for: highlight.id)
    }

    /// 改的是已做成记忆卡的摘录：按设置同步，或询问
    func offerCardSync(for highlightID: Int64?) {
        if let id = highlightID, cardHighlightIDs.contains(id) {
            switch CardSettings.syncFromHighlight {
            case "always": syncCards(fromHighlight: id)
            case "never": break
            default:
                let n = (try? db.cards(forHighlight: id).count) ?? 0
                if n > 0 { cardSyncOffer = CardSyncOffer(highlightId: id, cardCount: n) }
            }
        }
    }

    func syncCards(fromHighlight id: Int64) {
        perform { _ = try db.syncCards(fromHighlight: id, style: CitationSettings.style) }
    }

    /// 记忆卡对应的原摘录：打开编辑面板
    func openHighlight(of card: Card) {
        guard let id = card.highlightId, let h = try? db.highlights(ids: [id]).first else { return }
        edit(h)
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
    /// 网址从哪里自动填入的（浏览器当前页 / 剪贴板）
    var hint: String?
}

/// 摘录导入预览（Readwise CSV、LiquidText 笔记共用）
struct ImportPreview: Identifiable {
    enum Origin { case readwise, liquidText }
    let id = UUID()
    var fileName: String
    var result: ReadwiseCSVImporter.Result
    var origin: Origin = .readwise
    /// 导入时一并存进数据库的图片（文件名 → 数据），正文里以 kr-media:// 引用
    var media: [String: Data] = [:]

    var title: String { origin == .readwise ? "从 Readwise 导入" : "从 LiquidText 导入" }
    var tag: String { origin == .readwise ? "Readwise" : "LiquidText" }

    /// 很短的摘录（如只摘了一个人名，不足 minLength 个字、且不含图片）的条数
    static let shortLength = 4
    var shortCount: Int {
        result.sources.reduce(0) { $0 + $1.highlights.filter(Self.isShort).count }
    }
    static func isShort(_ h: ReadwiseCSVImporter.ImportedHighlight) -> Bool {
        !h.text.contains("kr-media://") && h.text.count < shortLength
    }
    /// 去掉很短摘录后的结果
    func withoutShort() -> ReadwiseCSVImporter.Result {
        var r = result
        for i in r.sources.indices { r.sources[i].highlights.removeAll(where: Self.isShort) }
        r.sources.removeAll { $0.highlights.isEmpty }
        return r
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

/// 一条相关摘录
struct RelatedItem: Identifiable {
    var highlight: Highlight
    var hit: RelatedIndex.Hit
    var id: Int64 { hit.id }
}

/// 备份列表（items 为 nil 表示正在读取）
struct BackupListRequest: Identifiable {
    let id = UUID()
    var items: [BackupInfo]?
}
