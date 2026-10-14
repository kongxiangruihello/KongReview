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
    }

    /// 出处被删除或合并后，指向它的“按书回顾”范围回到全部摘录
    func clearSourceReviewScope(_ ids: [Int64]) {
        if let sc = ReviewScope.sourceScope(review.theme), ids.contains(sc.id) { review.theme = nil }
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
