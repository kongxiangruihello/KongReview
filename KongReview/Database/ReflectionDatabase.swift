import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.0.1：复盘——每周五步，月度、年度
//
// 每周：① 看数字 ② 看新材料 ③ 看自己的想法 ④ 过一遍常念问题 ⑤ 写三句话（收获、困难、下一步）。
// 月度同上，数字与材料按月；年度另加“观点的变化”（今年修订过的札记，年初或初写时与现在并排）与“一年的问题”。
// 三句话与学习小结的“复盘”是同一份（app_progress 中 GrowthReflection，键为周期的 key）；
// 复盘走到哪一步、是否完成另存在 app_progress“reflection.<周期 key>”。不新增表。

/// 复盘的一步
enum ReflectionStep: String, Codable, CaseIterable, Identifiable, Sendable {
    case numbers, materials, thoughts, questions, views, sentences
    var id: String { rawValue }
    var title: String {
        switch self {
        case .numbers: "看数字"
        case .materials: "看新材料"
        case .thoughts: "看自己的想法"
        case .questions: "过一遍常念问题"
        case .views: "观点的变化"
        case .sentences: "写三句话"
        }
    }
    static func steps(for period: GrowthPeriod) -> [ReflectionStep] {
        period == .year ? [.numbers, .materials, .thoughts, .questions, .views, .sentences]
                        : [.numbers, .materials, .thoughts, .questions, .sentences]
    }
}

/// 复盘的进度：走到第几步、看过哪几步、何时完成
struct ReflectionProgress: Codable, Equatable, Sendable {
    var step = 0
    var visited: [Int] = []
    var completedAt: Date?
    static func key(_ window: GrowthWindow) -> String { "reflection." + window.key }
}

extension AppDatabase {
    // MARK: 进度

    func reflectionProgress(_ window: GrowthWindow) throws -> ReflectionProgress {
        try progressValue(ReflectionProgress.self, key: ReflectionProgress.key(window)) ?? ReflectionProgress()
    }

    func saveReflectionProgress(_ p: ReflectionProgress, window: GrowthWindow) throws {
        try saveProgress(p, key: ReflectionProgress.key(window))
    }

    func reflectionCompleted(_ window: GrowthWindow) -> Bool {
        ((try? reflectionProgress(window))?.completedAt) != nil
    }

    // MARK: 第一步：数字

    // MARK: 第三步：自己的想法

    // MARK: 第四步：问题

    // MARK: 年度：观点的变化

    // MARK: 完成

    func completeReflection(_ window: GrowthWindow, now: Date = Date()) throws {
        var p = try reflectionProgress(window)
        p.completedAt = now
        p.visited = Array(Set(p.visited + Array(0..<ReflectionStep.steps(for: window.period).count))).sorted()
        try saveReflectionProgress(p, window: window)
    }

}

// MARK: - 每周复盘提醒

enum ReflectionReminderPlan {
    static let enabledKey = "reflection.reminderEnabled"
    static let weekdayKey = "reflection.reminderWeekday"
    static let hourKey = "reflection.reminderHour"
    static let minuteKey = "reflection.reminderMinute"
    static let prefix = "kongreview.reflection."

    /// 之后几次提醒的时间（weekday：1 为星期日）；提醒的那一周已复盘就跳过。
    /// 提醒所对应的“那一周”取提醒时刻前一天所在的周，星期日为一周之首或之末都对得上。
    static func fires(now: Date, weekday: Int, hour: Int, minute: Int, count: Int = 4,
                      calendar: Calendar = .current, completed: (GrowthWindow) -> Bool) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        var guardCount = 0
        while out.count < count && guardCount < 7 * (count + 2) {
            guardCount += 1
            if calendar.component(.weekday, from: day) == weekday,
               let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire > now,
               !completed(targetWeek(for: fire, calendar: calendar)) {
                out.append(fire)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return out
    }

    static func targetWeek(for fire: Date, calendar: Calendar = .current) -> GrowthWindow {
        let d = calendar.date(byAdding: .day, value: -1, to: fire) ?? fire
        return GrowthPeriod.week.window(containing: d, now: fire, calendar: calendar)
    }
}
