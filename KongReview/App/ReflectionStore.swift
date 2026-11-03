import Foundation
import KongReviewCore

// MARK: - 5.0.1：复盘

extension LibraryStore {

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

}
