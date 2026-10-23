import Foundation
import KongReviewCore

// MARK: - 5.0.0：重温（今日功课第三步）

extension LibraryStore {
    func refreshRevisit() {
        revisitCounts = (try? db.revisitCounts()) ?? RevisitCounts()
        revisitRevision += 1
        // 5.0.2：重温、札记与问题的改动都可能记下小胜
        refreshProgress()
    }

    func openRevisit() {
        checkDayChange()
        refreshRevisit()
        selection = .revisit
    }

    /// 札记重温的三个选择；“要修订”随即打开札记
    func revisitNote(_ id: Int64, _ outcome: RevisitOutcome) {
        guard !fullBackupBusy else { return }
        do {
            try db.recordNoteRevisit(noteId: id, outcome: outcome)
            refreshRevisit()
            if outcome == .revise { selection = .ideaNote(id) }
        } catch { report(error) }
    }

    /// 问题重温的三个选择；“写解答”随即打开问题
    func revisitQuestion(_ id: Int64, _ outcome: RevisitOutcome, highlightIDs: [Int64] = [], remark: String = "") {
        guard !fullBackupBusy else { return }
        do {
            try db.recordQuestionRevisit(questionId: id, outcome: outcome, highlightIDs: highlightIDs, remark: remark)
            refreshQuestions()
            refreshRevisit()
            researchProjectRevision += 1
            journeyRevision += 1
            if outcome == .answer { selection = .question(id) }
        } catch { report(error) }
    }

    /// 重温卡上“可能相关的新摘录”：某一刻之后新录、与文字用词相近的几条（沿用相关摘录的余弦相似度），排除已引用、已挂上的
    func revisitNewHighlights(text: String, since: Date, excluding: Set<Int64>, limit: Int = 3) -> [Highlight] {
        guard let idx = relatedIndex,
              let fresh = try? db.highlightIDsCreated(after: since), !fresh.isEmpty else { return [] }
        let hits = idx.related(toText: text, excluding: excluding, limit: 2_000).filter { fresh.contains($0.id) }.prefix(limit)
        let byId = Dictionary(((try? db.highlights(ids: hits.map(\.id))) ?? []).compactMap { h in h.id.map { ($0, h) } },
                              uniquingKeysWith: { a, _ in a })
        return hits.compactMap { byId[$0.id] }
    }
}
