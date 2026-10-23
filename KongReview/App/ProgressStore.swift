import Foundation
import KongReviewCore

// MARK: - 5.0.2：自测与进展

extension LibraryStore {
    /// 今日收获（首页功课做完时显示）与改动计数
    func refreshProgress() {
        todayGains = (try? db.todayGains()) ?? []
        progressRevision += 1
    }

    func openSelfTest() {
        checkDayChange()
        selection = .selfTest
    }

    func recordSelfTest(_ item: SelfTestItem, _ result: SelfTestResult, week: GrowthWindow) {
        guard !fullBackupBusy else { return }
        do {
            try db.recordSelfTest(item, result: result, week: week)
            refreshProgress()
        } catch { report(error) }
    }
}
