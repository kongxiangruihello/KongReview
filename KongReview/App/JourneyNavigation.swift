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

