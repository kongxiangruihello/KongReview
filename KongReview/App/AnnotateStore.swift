import Foundation
import KongReviewCore

// MARK: - 6.0.4：每天标注文章

/// 打开一篇来标注（在今日试卷上以面板打开）
struct AnnotateRequest: Identifiable, Equatable {
    var id: Int64 { articleId }
    var articleId: Int64
    /// 6.4.1：从摘录的右键菜单打开的（不在今天的篇目里）：标完就关，不接着打开下一篇
    var fromMenu = false
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

    /// 6.4.1：右键菜单“标注…”——任何一条摘录都可以打开来划要点
    func openAnnotation(of highlight: Highlight) {
        guard !fullBackupBusy, let id = highlight.id else { return }
        annotating = AnnotateRequest(articleId: id, fromMenu: true)
    }

    /// 6.4.1：标注面板里“编辑”——先收起标注面板，打开原来的摘录编辑窗口；编辑窗口关掉后回到标注面板
    func editFromAnnotation(_ request: AnnotateRequest) {
        guard !fullBackupBusy, let h = try? db.highlight(id: request.articleId) else { return }
        annotateAfterEdit = request
        annotating = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.edit(h)
        }
    }

    /// 编辑窗口关掉了：有等着回去的标注面板就打开
    func resumeAnnotationAfterEdit() {
        guard let request = annotateAfterEdit, editorDraft == nil else { return }
        annotateAfterEdit = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.editorDraft == nil, self.annotating == nil else { return }
            self.annotating = request
        }
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
