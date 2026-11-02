import Foundation
import KongReviewCore

// MARK: - 5.2.0：今日检查

extension LibraryStore {
    /// 各组此刻的进度：回顾与记忆卡取首页统计，重温取今天的重温队列，自测取本周题中今天的份额
    func dailyCheckCounts(now: Date = Date()) -> [DailyCheckGroup: DailyCheckCount] {
        let h = homeLearningSummary
        let selfTest = (try? db.selfTestToday(now: now)) ?? DailyCheckCount()
        return [
            .review: DailyCheckCount(done: h.reviewCompletedCount, left: h.reviewPendingCount),
            .cards: DailyCheckCount(done: h.cardsStudiedCount, left: h.cardsDueCount),
            .revisit: DailyCheckCount(done: revisitCounts.done, left: revisitCounts.left),
            .selfTest: selfTest,
        ]
    }

    /// 重算今日检查。今天的学习统计还没算出来（或正在重算、或还是昨天的）时只显示、不定应做数，免得把 0 或昨天的数当成今天的应做。
    func refreshDailyCheck() {
        let snapshot = derivedDayKey == ReminderPlan.dayKey(Date()) && !derivedIsLoading
        dailyCheck = (try? db.dailyCheck(current: dailyCheckCounts(), snapshot: snapshot)) ?? .empty
        dailyCheckRevision += 1
    }

    func openDailyCheck() {
        checkDayChange()
        refreshRevisit()
        selection = .dailyCheck
    }

    /// 从今日检查进入某一组
    func openDailyCheckGroup(_ group: DailyCheckGroup) {
        switch group {
        case .review: openTodayReview()
        case .cards:
            guard todayCardPending.total > 0 else { openCardsHome(); return }
            if deckSummaryCache.filter({ $0.counts.total > 0 }).count > 1 { startStudyAllDecks() } else { startSuggestedStudy() }
            selection = .cards
        case .revisit: openRevisit()
        case .selfTest: openSelfTest()
        }
    }

    /// 今天跳过或恢复一组
    func setDailyCheckGroup(_ group: DailyCheckGroup, skipped: Bool) {
        guard !fullBackupBusy else { return }
        do {
            try db.setDailyCheckGroup(group, skipped: skipped)
            refreshDailyCheck()
        } catch { report(error) }
    }
}

// MARK: - 5.2.1：日评分

extension LibraryStore {
    /// 写今天的自评与一句话
    func saveSelfScore(_ score: SelfScore?, note: String) {
        guard !fullBackupBusy else { return }
        do {
            try db.saveSelfScore(score, note: note)
            dailyCheckRevision += 1
        } catch { report(error) }
    }
}
