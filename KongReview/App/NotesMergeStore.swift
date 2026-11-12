import Foundation
import KongReviewCore

// MARK: - 6.4.0：问题簿、专题笔记本并入札记之后

extension LibraryStore {
    static let notesMergeNoticeKey = "notesMerge640.noticed"

    /// 并入后札记每天的题数：原来札记、进展题、解答题、复述题四项之和（至多 20）
    nonisolated static func mergedNotesPerDay(_ defaults: UserDefaults) -> Int {
        func value(_ key: String) -> Int { max(0, min(10, defaults.object(forKey: key) as? Int ?? 2)) }
        return min(20, value(RevisitLimits.notesKey) + value(RevisitLimits.questionsKey)
                   + value(RevisitLimits.answersKey) + value(RevisitLimits.blocksKey))
    }

    /// 库里有并入的问题或笔记本时：改一次题数、说明一次。没有并入过的库不记“已说明”，以后恢复旧备份时还会走到这里。
    func runNotesMergeNoticeIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.notesMergeNoticeKey) else { return }
        guard let totals = try? db.notesMergeTotals(), totals.questions + totals.notebooks > 0 else { return }
        let perDay = Self.mergedNotesPerDay(defaults)
        defaults.set(perDay, forKey: RevisitLimits.notesKey)
        defaults.set(true, forKey: Self.notesMergeNoticeKey)
        refreshIdeaNotes()
        refreshRevisit()
        infoMessage = "6.4.0：问题簿里的 \(totals.questions) 个问题、\(totals.notebooks) 本专题笔记本已并入札记，侧栏只留“札记”。"
            + "日课上原来的进展题、解答题、复述题都改出论证题，札记每天的题数改为 \(perDay) 道（设置 → 日课里可改）。原来的数据另存了一份，没有删。"
    }
}
