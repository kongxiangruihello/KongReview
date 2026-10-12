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
    let study = StudyState()

    /// 侧边栏“出处”分组是否展开（默认折叠，记住上次状态）
    var sourcesExpanded: Bool = UserDefaults.standard.bool(forKey: "sidebar.sourcesExpanded") {
        didSet { UserDefaults.standard.set(sourcesExpanded, forKey: "sidebar.sourcesExpanded") }
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
            cardHighlightIDs = try db.cardHighlightIDs()
            cardCount = try db.cards().count
            reviewedToday = try db.reviewedToday()
            noteTemplates = try db.noteTemplates()
            revision += 1
            onReload?()
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
        let s = (try? db.deckSummaries(now: Date(), newPerDay: CardSettings.newPerDay,
                                       reviewsPerDay: CardSettings.reviewsPerDay)) ?? []
        return s.reduce(0) { $0 + $1.counts.total }
    }

    func deleteCards(_ ids: [Int64]) {
        perform { try db.deleteCards(ids) }
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
        // 改的是已做成记忆卡的摘录：按设置同步，或询问
        if let id = draft.highlight.id, cardHighlightIDs.contains(id) {
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
