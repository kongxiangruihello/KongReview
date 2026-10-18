import Foundation
import Observation

@MainActor @Observable final class JourneyNavigation {
    var topicPages: [Int64:Int] = [:]
    var selectedNotebookID: Int64?
    var topicTimelineIDs: Set<Int64> = []
    var outcomesQuery = ""
    var outcomesNotebookID: Int64?
    var outcomesPage = 0
    var outcomesUseDates = false
    var outcomesStart = Calendar.current.date(byAdding:.month,value:-1,to:Date())!
    var outcomesEnd = Date()
    var showTopicQuestions = false
    var questionPages: [Int64:Int] = [:]
    var questionQueries: [Int64:String] = [:]
    var questionSolved: [Int64:Bool] = [:]
    var tab = 0
    var period: GrowthPeriod = .week
    var date = Date()
    var planStatus: PlanStatus = .pending
    var planPage = 0
    var historyQuery = ""
    var historyPeriod: GrowthPeriod?
    var historyPage = 0
    var carePage = 0
    var anchors: [String:String] = [:]
    var reportMetrics: [String:GrowthMetric] = [:]
    var reportPages: [String:Int] = [:]
}
extension LibraryStore {
    func openLearningPlanLink(_ link: LearningPlanLink) {
        let generation = growthGeneration
        Task { @MainActor in
            do {
                guard try await db.planLinkExists(link) else { errorMessage = "关联内容已删除；计划仍保留，可编辑后重新关联。"; return }
                guard generation == growthGeneration, !fullBackupBusy else { return }
                switch link.kind {
                case .notebook: selection = .notebook(link.recordID)
                case .source: learningExplorer = .init(route: .document(.init(kind:.source,recordID:link.recordID),""))
                case .card: learningExplorer = .init(route: .document(.init(kind:.card,recordID:link.recordID),""))
                }
            } catch { report(error) }
        }
    }
    func openLearningPlans() {
        journeyNavigation.tab = 5; journeyNavigation.planStatus = .pending
        journeyNavigation.planPage = 0; journeyNavigation.anchors["plans"] = nil; selection = .growth
    }
}

extension LibraryStore {
    func openPlanEvidence(_ evidence: PlanEvidence) {
        let generation = growthGeneration
        Task { @MainActor in
            do {
                let (target, notebook) = try await db.evidenceTarget(evidence)
                guard generation == growthGeneration, !fullBackupBusy else { return }
                if let target { learningExplorer = .init(route:.document(target,"")) }
                else if let notebook { selection = .notebook(notebook) }
                else { errorMessage = "关联的摘录或笔记已删除，收获记录仍保留。" }
            } catch { report(error) }
        }
    }
}

extension LibraryStore {
    func refreshWeeklyPlans() {
        guard !fullBackupBusy else { return }
        do { if try db.materializeWeeklyPlans() > 0 { journeyRevision += 1 } }
        catch { report(error) }
    }
}
