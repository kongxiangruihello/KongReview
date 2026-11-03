import Foundation
import KongReviewCore

// MARK: - 5.2.0：今日检查

extension LibraryStore {
    /// 各组此刻的进度：回顾与记忆卡取首页统计，重温取今天的重温队列，自测取本周题中今天的份额
    /// 6.0.3：每周自测并入今日试卷，不再单列
    func dailyCheckCounts(now: Date = Date()) -> [DailyCheckGroup: DailyCheckCount] {
        let h = homeLearningSummary
        return [
            .review: DailyCheckCount(done: h.reviewCompletedCount, left: h.reviewPendingCount),
            .cards: DailyCheckCount(done: h.cardsStudiedCount, left: h.cardsDueCount),
            .revisit: DailyCheckCount(done: revisitCounts.done, left: revisitCounts.left),
        ]
    }

    /// 重算今日检查。今天的学习统计还没算出来（或正在重算、或还是昨天的）时只显示、不定应做数，免得把 0 或昨天的数当成今天的应做。
    func refreshDailyCheck() {
        let snapshot = derivedDayKey == ReminderPlan.dayKey(Date()) && !derivedIsLoading
        dailyCheck = (try? db.dailyCheck(current: dailyCheckCounts(), groups: DailyCheckGroup.exam, snapshot: snapshot)) ?? .empty
        refreshCheckin()
        dailyCheckRevision += 1
    }

    /// 5.2.2：重算打卡天数；今天的打卡状态变了就通知提醒模块
    func refreshCheckin() {
        let before = checkin.todayChecked
        checkin = (try? db.checkinSummary()) ?? .empty
        if checkin.todayChecked != before { onCheckinChanged?() }
    }

    /// 6.0.3：今日检查即今日试卷
    func openDailyCheck() { openExam() }

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
            refreshCheckin()
            dailyCheckRevision += 1
        } catch { report(error) }
    }
}

// MARK: - 5.2.2：打卡

extension LibraryStore {
    /// 自今天起设定每周的休息日（nil 为不设）
    func setRestWeekday(_ weekday: Int?) {
        guard !fullBackupBusy else { return }
        do {
            try db.setRestWeekday(weekday)
            refreshCheckin()
            dailyCheckRevision += 1
        } catch { report(error) }
    }

    /// 补签某一天；不成时返回原因
    @discardableResult
    func makeUpCheckin(day: String, score: SelfScore, note: String) -> String? {
        guard !fullBackupBusy else { return "正在处理完整备份，请稍后再试。" }
        do {
            try db.makeUpCheckin(day: day, score: score, note: note)
            refreshCheckin()
            dailyCheckRevision += 1
            return nil
        } catch let e as CheckinMakeupError {
            return e.message
        } catch {
            report(error)
            return error.localizedDescription
        }
    }

    /// 记下连续中断的原因
    func recordStreakBreak(_ reason: StreakBreakReason) {
        guard !fullBackupBusy, let day = checkin.brokenOn else { return }
        do {
            try db.recordStreakBreak(day: day, reason: reason)
            refreshCheckin()
        } catch { report(error) }
    }
}
