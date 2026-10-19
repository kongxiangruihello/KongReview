import Foundation
import KongReviewCore

// MARK: - 1.7：笔记本 ↔ 记忆卡、按书回顾、按页码范围批量

extension LibraryStore {

    func notebookTitle(_ id: Int64) -> String {
        notebooks.first { $0.id == id }?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "专题笔记本"
    }

    /// 笔记本里有多少条摘录、其中多少条已经有记忆卡
    func notebookCardStatus(_ id: Int64) -> (quotes: Int, withCards: Int, cards: Int) {
        let ids = ((try? db.notebookHighlights(id)) ?? []).compactMap(\.id)
        let cs = (try? db.cards(highlightIds: ids)) ?? []
        return (ids.count, Set(cs.compactMap(\.highlightId)).count, cs.count)
    }

    /// 把笔记本里的摘录做成问答卡，放进以笔记本命名的牌组（已有卡片的摘录不重复做）
    func makeNotebookCards(_ id: Int64) {
        flushNotebookSaves()
        let deck = notebookTitle(id)
        perform {
            let ids = try db.notebookHighlights(id).compactMap(\.id)
            guard !ids.isEmpty else { infoMessage = "这本笔记本里还没有摘录。"; return }
            let r = try db.makeCardsReport(fromHighlights: ids, deck: deck, style: CitationSettings.style)
            if r.made == 0 {
                infoMessage = "笔记本里的 \(ids.count) 条摘录都已经有记忆卡了。可以点“学习这本的记忆卡”。"
            } else {
                infoMessage = "已做成 \(r.made) 张记忆卡，放在牌组“\(deck)”。"
                    + (r.existing > 0 ? "另有 \(r.existing) 条原来就有卡片（在各自的牌组），没有重复做。" : "")
            }
        }
    }

    // MARK: 逐条做填空卡

    /// 依次为笔记本里的摘录打开填空卡面板（已经做过填空卡的跳过）；牌组默认用笔记本名
    func startNotebookCloze(_ id: Int64) {
        flushNotebookSaves()
        let hs = (try? db.notebookHighlights(id)) ?? []
        let existing = (try? db.cards(highlightIds: hs.compactMap(\.id))) ?? []
        let done = Set(existing.filter { $0.front.contains("class=\"cloze\"") }.compactMap(\.highlightId))
        let queue = hs.compactMap(\.id).filter { !done.contains($0) }
        guard !queue.isEmpty else {
            infoMessage = hs.isEmpty ? "这本笔记本里还没有摘录。" : "笔记本里的摘录都已经做过填空卡了。"
            return
        }
        clozeQueue = queue
        clozeQueueTotal = queue.count
        clozeQueueDeck = notebookTitle(id)
        clozeQueueMade = 0
        advanceClozeQueue()
    }

    /// 打开队列里的下一条；队列空了给出小结
    func advanceClozeQueue() {
        while !clozeQueue.isEmpty {
            let hid = clozeQueue.removeFirst()
            guard let h = try? db.highlights(ids: [hid]).first, h.deletedAt == nil else { continue }
            startCloze(for: h)
            clozeDraft?.deck = clozeQueueDeck
            clozeDraft?.progress = "第 \(clozeQueueTotal - clozeQueue.count) / \(clozeQueueTotal) 条"
            return
        }
        if clozeQueueTotal > 0 {
            infoMessage = clozeQueueMade > 0
                ? "逐条做填空卡结束：共生成 \(clozeQueueMade) 张，放在牌组“\(clozeQueueDeck)”。"
                : "逐条做填空卡结束，没有生成卡片。"
        }
        clozeQueueTotal = 0
        clozeQueueMade = 0
    }

    func skipCloze() {
        clozeDraft = nil
        advanceClozeQueue()
    }

    func endClozeQueue() {
        clozeDraft = nil
        clozeQueue = []
        advanceClozeQueue()
    }

    // MARK: 按笔记本学习

    /// 学习由笔记本里的摘录做成的卡片（不论在哪个牌组）；新卡、复习按“设置 → 记忆卡”的全局每日上限
    func startNotebookStudy(_ id: Int64) {
        clearCardRatingUndo()
        flushNotebookSaves()
        study.notebookId = id
        study.deck = "《\(notebookTitle(id))》"
        study.browsingDeck = nil
        selection = .cards
        nextCard()
        // 一张卡都没有时不进入学习界面，只提示
        if study.current == nil, notebookCardStatus(id).cards == 0 {
            study.deck = nil
            study.notebookId = nil
            study.finished = false
            infoMessage = "这本笔记本里的摘录还没有做成记忆卡。先点“做成问答卡”或“逐条做填空卡”。"
        }
        refreshDerived()
    }

    /// 出处被删除或合并后，指向它的“按书回顾”范围回到全部摘录
    func clearSourceReviewScope(_ ids: [Int64]) {
        if let sc = ReviewScope.sourceScope(review.theme), ids.contains(sc.id) { review.theme = nil }
        if let sc = ReviewScope.chapterScope(review.theme), ids.contains(sc.id) { review.theme = nil }
    }

    func nextNotebookCard(_ id: Int64, now: Date = Date()) {
        let ids = ((try? db.notebookHighlights(id)) ?? []).compactMap(\.id)
        let cards = (try? db.cards(highlightIds: ids)) ?? []
        let done = (try? db.studiedToday(cardIds: cards.compactMap(\.id), now: now)) ?? (new: 0, review: 0)
        let newLeft = CardSettings.newPerDay - done.new
        let reviewLeft = CardSettings.reviewsPerDay - done.review
        study.current = StudyQueue.next(from: cards, now: now, newLimitLeft: newLeft, reviewLimitLeft: reviewLeft)
        study.notebookCounts = StudyQueue.counts(cards, now: now, newLimitLeft: newLeft, reviewLimitLeft: reviewLeft)
        study.showingAnswer = false
        study.finished = study.current == nil
    }

    // MARK: 按书回顾

    /// 在“今日回顾”里按页码把这本书（或其中一段）过一遍；每次都从头开始
    func reviewSource(_ id: Int64, pages: ClosedRange<Int>? = nil) {
        let theme = ReviewScope.source(id, pages: pages)
        // 与 ReviewSessionRecord.key(theme:) 相同（那个类型在界面层）
        UserDefaults.standard.removeObject(forKey: "review.session." + theme)
        review.theme = theme
        review.sessionToken += 1
        selection = .review
    }

    /// 回顾范围的显示名：《书名》或《书名》第 10–20 页
    func sourceScopeLabel(_ theme: String?) -> String? {
        guard let sc = ReviewScope.sourceScope(theme) else { return nil }
        let title = sources.first { $0.id == sc.id }.map { "《\($0.title)》" } ?? "这本书"
        return title + (sc.pages.map { " " + Self.pageLabel($0) } ?? "")
    }

    static func pageLabel(_ r: ClosedRange<Int>) -> String {
        if r.lowerBound == Int.min && r.upperBound == Int.max { return "全部页" }
        if r.lowerBound == Int.min { return "第 \(r.upperBound) 页以前" }
        if r.upperBound == Int.max { return "第 \(r.lowerBound) 页以后" }
        return r.lowerBound == r.upperBound ? "第 \(r.lowerBound) 页" : "第 \(r.lowerBound)–\(r.upperBound) 页"
    }

    // MARK: 按页码范围批量

    func openPageRange(_ sourceId: Int64) {
        let st = (try? db.sourcePageStats(sourceId)) ?? SourcePageStats()
        pageRange = PageRangeDraft(sourceId: sourceId, from: st.firstPage, to: st.lastPage)
    }

    /// 在列表里选中这一段的摘录（之后可用工具栏“批量操作”加标签、移出处、弃置等）
    func selectPageRange(_ sourceId: Int64, _ r: ClosedRange<Int>) {
        let ids = ((try? db.sourceHighlights(sourceId, pages: r)) ?? []).compactMap(\.id)
        pageRange = nil
        // 列表换成按页码排序、清掉搜索词后会重新载入并清空选择，所以先记下，载入后再选中
        list.query = ""
        list.sourceByPage = true
        list.pendingSelection = Set(ids)
        revisionBump()
        infoMessage = ids.isEmpty ? "这个页码范围内没有摘录。" : "已选中 \(Self.pageLabel(r))的 \(ids.count) 条摘录，可用工具栏的“批量操作”。"
    }

    func makeCardsForPageRange(_ sourceId: Int64, _ r: ClosedRange<Int>) {
        let title = sources.first { $0.id == sourceId }?.title ?? "摘录"
        pageRange = nil
        perform {
            let ids = try db.sourceHighlights(sourceId, pages: r).compactMap(\.id)
            guard !ids.isEmpty else { infoMessage = "这个页码范围内没有摘录。"; return }
            let res = try db.makeCardsReport(fromHighlights: ids, deck: title, style: CitationSettings.style)
            infoMessage = res.made > 0
                ? "已把\(Self.pageLabel(r))的 \(res.made) 条摘录做成记忆卡（牌组“\(title)”）。" + (res.existing > 0 ? "\(res.existing) 条原来就有卡片。" : "")
                : "这一段的摘录都已经有记忆卡了。"
        }
    }
}

// MARK: - 1.8：复习热力图

extension LibraryStore {
    /// 过去约一年每天的记忆卡复习（数据变化或换日时重新查询）
    func reviewHeatmap(now: Date = Date()) -> [String: ReviewHeatmap.Day] {
        let key = "\(revision)|\(ReviewHeatmap.dayKey(now))"
        if let c = heatmapCache, c.key == key { return c.days }
        let since = Calendar.current.date(byAdding: .day, value: -380, to: Calendar.current.startOfDay(for: now)) ?? now
        let days = (try? db.cardReviewDays(since: since)) ?? [:]
        heatmapCache = (key, days)
        return days
    }
}

// MARK: - 1.9：引文核对

extension LibraryStore {
    /// 核对当前打开的笔记本里的引文；没有问题返回 nil
    func notebookCitationCheck(export: CitationCheckRequest.Export? = nil) -> CitationCheckRequest? {
        flushNotebookSaves()
        let st = notebookState
        let items: [CitationCheck.Item] = st.blocks.compactMap { b in
            guard b.kind == .highlight, let hid = b.highlightId, let h = st.highlights[hid] else { return nil }
            // 2.1：改用别的版本且有该版页码时，按那个版本核对
            if let c = editionChoice(for: h), let loc = c.location {
                var alt = h
                alt.location = loc
                return CitationCheck.Item(highlight: alt, source: c.source)
            }
            return CitationCheck.Item(highlight: h, source: source(for: h))
        }
        var issues = CitationCheck.check(items)
        // 2.1：选了别的版本出注，但这条没有该版页码（导出时仍按原出处）
        for it in items {
            if let c = editionChoice(for: it.highlight), c.location == nil, let hid = it.highlight.id {
                issues.append(CitationCheck.Issue(kind: .editionPage, highlightId: hid, sourceId: c.source.id,
                                                  message: "导出改用《\(c.source.title)》出注，这条还没有该版页码，暂按原出处引用。"))
            }
        }
        guard !issues.isEmpty else { return nil }
        var snippets: [Int64: String] = [:]
        for it in items {
            guard let id = it.highlight.id else { continue }
            let t = it.highlight.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            snippets[id] = t.count > 36 ? String(t.prefix(36)) + "…" : t
        }
        var r = CitationCheckRequest(issues: issues, snippets: snippets, export: export)
        for it in items { if let id = it.highlight.id { r.locations[id] = it.highlight.location ?? "" } }
        return r
    }

    /// 菜单“引文核对…”：有问题弹出清单，没有问题给一句提示
    func runNotebookCitationCheck() {
        if let r = notebookCitationCheck() {
            citationCheck = r
        } else {
            infoMessage = "引文核对：笔记本里的引文都有出处，页码、篇名齐全。"
        }
    }

    /// 从核对清单里去改某条摘录 / 某个出处（先关掉清单）
    func fixCitationIssue(_ issue: CitationCheck.Issue) {
        citationCheck = nil
        if let hid = issue.highlightId, let h = try? db.highlights(ids: [hid]).first {
            if issue.kind != .sourceInfo {
                edit(h)
                return
            }
        }
        if let sid = issue.sourceId, let s = sources.first(where: { $0.id == sid }) {
            editingSource = s
        }
    }
}

// MARK: - 2.0：按篇回顾、清单里补页码

extension LibraryStore {
    /// 按篇做卡、回顾时用的书名：古籍用原典书名
    func chapterBookTitle(_ sourceId: Int64) -> String {
        guard let s = sources.first(where: { $0.id == sourceId }) else { return "摘录" }
        return s.classicTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? s.title
    }

    func reviewChapter(_ sourceId: Int64, _ chapter: String) {
        let theme = ReviewScope.chapter(sourceId, chapter)
        // 与 ReviewSessionRecord.key(theme:) 相同：每次都从头开始
        UserDefaults.standard.removeObject(forKey: "review.session." + theme)
        review.theme = theme
        review.sessionToken += 1
        selection = .review
    }

    /// 把一篇的摘录做成记忆卡，牌组“书名::篇名”
    func makeCardsForChapter(_ sourceId: Int64, _ chapter: String) {
        let deck = chapterBookTitle(sourceId) + "::" + chapter
        perform {
            let ids = try db.sourceChapterHighlights(sourceId, chapter: chapter).compactMap(\.id)
            guard !ids.isEmpty else { infoMessage = "《\(chapter)》里没有摘录。"; return }
            let r = try db.makeCardsReport(fromHighlights: ids, deck: deck, style: CitationSettings.style)
            infoMessage = r.made > 0
                ? "已把《\(chapter)》的 \(r.made) 条摘录做成记忆卡（牌组“\(deck)”）。" + (r.existing > 0 ? "\(r.existing) 条原来就有卡片。" : "")
                : "《\(chapter)》的摘录都已经有记忆卡了。"
        }
    }

    /// 回顾范围显示名：按篇
    func chapterScopeLabel(_ theme: String?) -> String? {
        guard let sc = ReviewScope.chapterScope(theme) else { return nil }
        return "《\(chapterBookTitle(sc.id))·\(sc.chapter)》"
    }

    /// 核对清单里填好的页码一次写进摘录（可撤销），然后重新核对
    func applyCitationPages() {
        guard var req = citationCheck else { return }
        var changes: [Int64: String] = [:]
        // 2.1：缺“所选版本页码”的，填的是那个版本的页码
        var editionChanges: [Int64: (sourceId: Int64, page: String)] = [:]
        for (id, raw) in req.pageDrafts {
            let kinds = req.issues.filter { $0.highlightId == id }
            if kinds.contains(where: { $0.kind == .noPage }) {
                if let loc = CitationCheck.addingPage(raw, to: req.locations[id]) { changes[id] = loc }
            } else if let ed = kinds.first(where: { $0.kind == .editionPage })?.sourceId,
                      let p = CitationCheck.pageText(raw) {
                editionChanges[id] = (ed, p)
            }
        }
        guard !changes.isEmpty || !editionChanges.isEmpty else { return }
        let ids = Array(changes.keys)
        if !ids.isEmpty {
            undoable("补页码（\(ids.count) 条）", highlights: ids) {
                perform {
                    try db.modifyHighlights(ids: ids) { h in
                        if let id = h.id, let loc = changes[id] { h.location = loc }
                    }
                }
            }
        }
        for (hid, c) in editionChanges {
            perform {
                var pages = try db.editionPages(hid)
                pages[c.sourceId] = c.page
                try db.setEditionPages(hid, pages)
            }
        }
        refreshNotebookHighlights()
        if var again = notebookCitationCheck(export: req.export) {
            again.id = req.id
            req = again
            citationCheck = req
            infoMessage = "已补 \(ids.count + editionChanges.count) 条页码，还有 \(again.issues.count) 处需要留意。"
        } else {
            let export = req.export
            citationCheck = nil
            infoMessage = "已补 \(ids.count + editionChanges.count) 条页码，引文都齐了。"
            if let export { DispatchQueue.main.async { self.pendingCitationExport = export } }
        }
    }
}

// MARK: - 2.1：同一古籍的不同版本

/// 每本笔记本记住各部古籍用哪个版本出注
enum NotebookEditionChoice {
    static func key(_ notebookId: Int64) -> String { "notebook.editions.\(notebookId)" }
    static func load(_ notebookId: Int64) -> [String: Int64] {
        guard let d = UserDefaults.standard.dictionary(forKey: key(notebookId)) else { return [:] }
        return d.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }
    static func save(_ map: [String: Int64], _ notebookId: Int64) {
        UserDefaults.standard.set(map.mapValues { NSNumber(value: $0) }, forKey: key(notebookId))
    }
}

extension LibraryStore {
    /// 古籍的原典书名（去掉书名号、空白）；不是古籍为 nil
    func classicKey(_ s: Source?) -> String? {
        guard let s, s.isClassic, let t = s.classicTitle else { return nil }
        let k = t.trimmingCharacters(in: CharacterSet(charactersIn: "《》 　\n"))
        return k.isEmpty ? nil : k
    }

    /// 与这个出处同属一部古籍的其他出处（不含它自己）
    func editions(for sourceId: Int64?) -> [Source] {
        guard let sid = sourceId, let key = classicKey(sources.first { $0.id == sid }) else { return [] }
        return sources.filter { $0.id != sid && classicKey($0) == key }
    }

    /// 笔记本里出现的古籍，以及每部可选的版本（至少两个版本才列出）
    func notebookClassics() -> [(title: String, editions: [Source])] {
        var order: [String] = []
        for h in notebookState.highlights.values.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            if let k = classicKey(source(for: h)), !order.contains(k) { order.append(k) }
        }
        return order.compactMap { k in
            let eds = sources.filter { classicKey($0) == k }
            return eds.count >= 2 ? (k, eds) : nil
        }
    }

    func setNotebookEdition(_ classic: String, _ sourceId: Int64?) {
        let st = notebookState
        st.exportEditions[classic] = sourceId
        if let nid = st.notebookId { NotebookEditionChoice.save(st.exportEditions, nid) }
    }

    /// 导出这条摘录时改用的版本与位置；不需要换（没选版本、选的就是原出处）时为 nil；
    /// 选了别的版本但这条没有该版页码时 location 为 nil
    func editionChoice(for h: Highlight) -> (source: Source, location: String?)? {
        let st = notebookState
        guard let key = classicKey(source(for: h)), let eid = st.exportEditions[key], eid != h.sourceId,
              let ed = sources.first(where: { $0.id == eid }), let hid = h.id else { return nil }
        guard let page = st.editionPages[hid]?[eid] else { return (ed, nil) }
        return (ed, ClassicCitation.location(h.location, withPage: page))
    }

    /// 笔记本导出用的出处文字（按所选版本）
    func notebookCitation(for h: Highlight) -> String {
        if let c = editionChoice(for: h), let loc = c.location {
            var alt = h
            alt.location = loc
            return CitationFormatter.citation(for: alt, source: c.source, style: CitationSettings.style)
        }
        return CitationFormatter.citation(for: h, source: source(for: h), style: CitationSettings.style)
    }
}

// MARK: - 2.2：版本页码批量导入、统计页的古籍进度

extension LibraryStore {
    func openEditionImport(_ sourceId: Int64) {
        editionImport = EditionImportDraft(sourceId: sourceId, editionId: editions(for: sourceId).first?.id)
    }

    /// 按当前对照表预览：这本书的摘录能对上几条
    func editionImportPreview(_ d: EditionImportDraft) -> EditionPageImport.Result {
        let hs = (try? db.sourceHighlightsByPage(d.sourceId)) ?? []
        return EditionPageImport.match(hs, rows: d.rows)
    }

    func commitEditionImport() {
        guard let d = editionImport, let eid = d.editionId else { return }
        let r = editionImportPreview(d)
        guard !r.matches.isEmpty else { return }
        let name = sources.first { $0.id == eid }.map { "《\($0.title)》" } ?? "该版本"
        perform {
            let res = try db.applyEditionPages(r.matches, editionId: eid, overwrite: d.overwrite)
            infoMessage = "已导入 \(res.written) 条摘录在\(name)里的页码"
                + (res.skipped > 0 ? "，\(res.skipped) 条原来就有、未覆盖" : "")
                + (r.unmatched.isEmpty ? "。" : "；\(r.unmatched.count) 条在对照表里找不到页码。")
        }
        editionImport = nil
        refreshNotebookHighlights()
    }

    struct ClassicOverview: Identifiable {
        var source: Source
        var chapters: [ChapterProgress]
        /// 最近一周回顾过的篇（按书中顺序）
        var recent: [String]
        var id: Int64 { source.id ?? 0 }
        var total: Int { chapters.reduce(0) { $0 + $1.total } }
        var reviewed: Int { chapters.reduce(0) { $0 + $1.reviewed } }
        var finished: Int { chapters.filter { $0.total > 0 && $0.reviewed == $0.total }.count }
    }

    /// 统计页：设了古籍体例、位置里有篇名的出处，各篇进度与最近一周回顾了哪些篇（最近读的排前）
    func classicOverview(now: Date = Date()) -> [ClassicOverview] {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let recentIds = (try? db.reviewedHighlightIds(since: weekAgo)) ?? []
        var out: [ClassicOverview] = []
        for s in sources where s.isClassic {
            guard let sid = s.id, let groups = try? db.sourceChapters(sid), !groups.isEmpty else { continue }
            let ids = groups.flatMap { $0.highlights.compactMap(\.id) }
            let carded = Set(((try? db.cards(highlightIds: ids)) ?? []).compactMap(\.highlightId))
            let recent = groups.filter { g in g.highlights.contains { $0.id.map(recentIds.contains) ?? false } }.map(\.name)
            out.append(ClassicOverview(source: s, chapters: ChapterProgress.compute(groups, carded: carded), recent: recent))
        }
        return out.sorted { a, b in
            a.recent.count != b.recent.count ? a.recent.count > b.recent.count : a.source.title < b.source.title
        }
    }
}
