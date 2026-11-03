import Foundation
import KongReviewCore

// MARK: - 6.0.5：成绩册

extension LibraryStore {
    /// 打开成绩册（报告默认本周）
    func openGradebook(period: GrowthPeriod? = nil, date: Date? = nil) {
        checkDayChange()
        if let period, period != .day { reflectionPeriod = period }
        if reflectionPeriod == .day { reflectionPeriod = .week }
        reflectionDate = date ?? (period == nil ? reflectionDate : Date())
        refreshCheckin()
        selection = .gradebook
    }

    /// 写这一期的一句话
    func saveGradebookRemark(_ text: String, window: GrowthWindow) {
        guard !fullBackupBusy else { return }
        do {
            try db.saveGradebookRemark(text, periodKey: window.key)
            reflectionRevision += 1
            onReflectionChanged?()
        } catch { report(error) }
    }

    /// 打开一道常错的题
    func openWeakItem(_ item: WeakItem) {
        switch item.kind {
        case .highlight:
            if let h = try? db.highlights(ids: [item.recordId]).first { edit(h) }
        case .card:
            if let c = try? db.card(id: item.recordId) { editCard(c) }
        case .note:
            selection = .ideaNote(item.recordId)
        case .block:
            if let n = item.notebookId { selection = .notebook(n) }
        }
    }
}
