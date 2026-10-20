import Foundation
import KongReviewCore

// MARK: - 3.15：本期焦点、今日功课

extension LibraryStore {
    func refreshLearningFocus() {
        learningFocus = try? db.validatedLearningFocus()
        if let focus = learningFocus {
            focusHighlightIDs = (try? db.focusHighlightIDs(focus)) ?? []
            focusDeckCounts = (try? db.focusDeckCounts(focus)) ?? [:]
        } else {
            focusHighlightIDs = []
            focusDeckCounts = [:]
        }
    }

    /// 设定或取消本期焦点。改变后今天的全库回顾不重抽（已开始的进度保留），从明天或“再抽一组”起生效；记忆卡立即优先。
    func setLearningFocus(_ focus: LearningFocus?) {
        guard !fullBackupBusy else { return }
        do {
            try db.setLearningFocus(focus)
            refreshLearningFocus()
            journeyRevision += 1
            revisionBump()
        } catch { report(error) }
    }

    /// 可选的焦点：专题笔记本与有摘录的出处
    var focusChoices: [LearningFocus] {
        let notebooksChoices = notebooks.compactMap { n in n.id.map { LearningFocus(kind: .notebook, id: $0, title: n.title) } }
        let sourceChoices = sources.filter { s in (s.id.flatMap { highlightCounts[$0] } ?? 0) > 0 }
            .compactMap { s in s.id.map { LearningFocus(kind: .source, id: $0, title: s.title) } }
        return notebooksChoices + sourceChoices
    }

    // MARK: 今日功课：先回顾，再记忆卡

    /// 回顾约 30 秒一条；记忆卡沿用牌组页的估算
    static func todayWorkMinutes(reviewPending: Int, cards: StudyQueue.Counts) -> Int {
        let seconds = reviewPending * 30 + DeckOverview.estimatedMinutes(cards) * 60
        return seconds == 0 ? 0 : max(1, Int((Double(seconds) / 60).rounded()))
    }

    /// 按顺序进入今天还没完成的功课：先回顾，回顾完成后进入记忆卡（两个以上牌组有卡时混合学习）
    func startTodayWork() {
        checkDayChange()
        refreshDerived()
        if homeLearningSummary.reviewPendingCount > 0 {
            openTodayReview()
        } else if todayCardPending.total > 0 {
            if deckSummaryCache.filter({ $0.counts.total > 0 }).count > 1 { startStudyAllDecks() } else { startSuggestedStudy() }
            selection = .cards
        } else {
            openTodayReview()
        }
    }
}
