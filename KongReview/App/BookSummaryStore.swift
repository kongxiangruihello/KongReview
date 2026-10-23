import Foundation
import KongReviewCore

// MARK: - 5.1：精简提要

/// 提要面板：一本书（出处）的一句话、正文与读完日期
struct BookSummaryEditorRequest: Identifiable, Sendable {
    var id = UUID()
    var sourceId: Int64
    /// 打开时就把“已读完”勾上（书页“标为读完”）
    var markFinished = false
}

extension LibraryStore {
    func editBookSummary(_ sourceId: Int64, markFinished: Bool = false) {
        guard !fullBackupBusy else { return }
        bookSummaryEditor = BookSummaryEditorRequest(sourceId: sourceId, markFinished: markFinished)
    }

    @discardableResult
    func saveBookSummary(sourceId: Int64, oneLine: String, body: String, finishedAt: Date?) -> Bool {
        guard !fullBackupBusy else { return false }
        do {
            try db.saveBookSummary(sourceId: sourceId, oneLine: oneLine, body: body, finishedAt: finishedAt)
            bookSummaryRevision += 1
            refreshRevisit()
            return true
        } catch { report(error); return false }
    }

    /// 书的重温：“要修订”随即打开提要
    func revisitBook(_ sourceId: Int64, _ outcome: RevisitOutcome) {
        guard !fullBackupBusy else { return }
        do {
            try db.recordBookRevisit(sourceId: sourceId, outcome: outcome)
            refreshRevisit()
            if outcome == .revise { editBookSummary(sourceId) }
        } catch { report(error) }
    }
}
