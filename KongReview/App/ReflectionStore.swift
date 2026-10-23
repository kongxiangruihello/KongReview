import Foundation
import KongReviewCore

// MARK: - 5.0.1：复盘

extension LibraryStore {
    /// 打开某一周期的复盘（默认本周；周初而上周未复盘时为上周）
    func openReflection(period: GrowthPeriod = .week, date: Date? = nil) {
        guard period != .day else { return }
        checkDayChange()
        reflectionPeriod = period
        if let date { reflectionDate = date }
        else if period == .week { reflectionDate = db.reflectionTargetWeek().start }
        else { reflectionDate = Date() }
        selection = .reflection
    }

    /// 完成这一期的复盘
    func completeReflection(_ window: GrowthWindow) {
        guard !fullBackupBusy else { return }
        do {
            try db.completeReflection(window)
            reflectionRevision += 1
            journeyRevision += 1
            onReflectionChanged?()
        } catch { report(error) }
    }

    func saveReflectionStep(_ progress: ReflectionProgress, window: GrowthWindow) {
        guard !fullBackupBusy else { return }
        do { try db.saveReflectionProgress(progress, window: window) } catch { report(error) }
    }
}
