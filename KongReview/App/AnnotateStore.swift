import Foundation
import KongReviewCore

// MARK: - 6.0.4：每天标注文章

/// 打开一篇来标注（在今日试卷上以面板打开）
struct AnnotateRequest: Identifiable, Equatable {
    var id: Int64 { articleId }
    var articleId: Int64
}

extension LibraryStore {
    /// 重算今天的篇目与进度（当天第一次时抽定篇目）
    func refreshAnnotate(now: Date = Date()) {
        let n = AnnotateSettings.perDay()
        annotate = n > 0 ? ((try? db.annotateToday(count: n, now: now)) ?? .empty) : .empty
    }

    func openAnnotation(_ id: Int64) {
        guard !fullBackupBusy else { return }
        annotating = AnnotateRequest(articleId: id)
    }

    /// 今天还没标的下一篇（没有则关闭面板）
    func openNextAnnotation(after id: Int64) {
        let items = annotate.items
        let start = (items.firstIndex { $0.id == id } ?? -1) + 1
        let next = (items[min(start, items.count)...] + items[..<min(start, items.count)]).first { !$0.doneToday && $0.id != id }
        annotating = next.map { AnnotateRequest(articleId: $0.id) }
    }

    /// 在文章里划出一段，存为同一出处下的新摘录
    func addAnnotationMark(articleId: Int64, text: String) {
        guard !fullBackupBusy else { return }
        checkDayChange()
        do {
            guard try db.addAnnotationMark(articleId: articleId, text: text) != nil else { return }
            if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        } catch { report(error); return }
        revisionBump()
        refreshDerived()
        refreshDailyCheck()
    }

    /// 这篇标完了
    func finishAnnotation(_ articleId: Int64) {
        guard !fullBackupBusy else { return }
        checkDayChange()
        do { try db.finishAnnotation(articleId: articleId) } catch { report(error); return }
        if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        refreshDailyCheck()
    }
}
