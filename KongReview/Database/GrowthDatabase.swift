import Foundation
import GRDB
import KongReviewCore

enum GrowthPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String { switch self { case .day: "每日"; case .week: "每周"; case .month: "每月"; case .year: "每年" } }
    var component: Calendar.Component { switch self { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year } }
    func window(containing date: Date, now: Date = Date(), calendar: Calendar = .current) -> GrowthWindow {
        let interval = calendar.dateInterval(of: component, for: date)!
        let end = min(interval.end, max(interval.start, now))
        let previousStart = calendar.date(byAdding: component, value: -1, to: interval.start)!
        let previousEnd: Date
        if end >= interval.end { previousEnd = interval.start }
        else {
            let delta = calendar.dateComponents([.day, .hour, .minute, .second], from: interval.start, to: end)
            previousEnd = min(interval.start, calendar.date(byAdding: delta, to: previousStart)!)
        }
        let components = calendar.dateComponents([.year,.month,.day], from: interval.start)
        let key = "growth.\(rawValue).\(components.year!)-\(components.month!)-\(components.day!)"
        return .init(start: interval.start, end: end, previousStart: previousStart, previousEnd: previousEnd,
                     fullEnd: interval.end, key: key, period: self)
    }
}
struct GrowthWindow: Sendable {
    let start: Date, end: Date, previousStart: Date, previousEnd: Date, fullEnd: Date
    let key: String
    let period: GrowthPeriod
}
enum GrowthMetric: String, CaseIterable, Identifiable, Sendable {
    case highlights, notes, cards, ratings, difficult, newHighlights, newCards, days
    var id: String { rawValue }
    var title: String { switch self {
    case .highlights: "回顾摘录（条）"; case .notes: "写按语（条）"; case .cards: "学习记忆卡（张）"; case .ratings: "评分次数"
    case .difficult: "反复重来的卡片"; case .newHighlights: "新增摘录"; case .newCards: "新增记忆卡"; case .days: "学习天数"
    } }
}
struct GrowthReflection: Codable, Equatable, Sendable {
    var goalHighlights = 0
    var goalCards = 0
    var gains = ""
    var challenges = ""
    var nextSteps = ""
}
extension AppDatabase {
    func progressValue<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try writer.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key=?", arguments: [key]) else { return nil }
            return try JSONDecoder().decode(type, from: data)
        }
    }
    func saveProgress<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        try writer.write { try $0.execute(sql: "INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload, updatedAt=excluded.updatedAt", arguments: [key,data,Date()]) }
    }
    func deleteProgress(key: String) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM app_progress WHERE key=?", arguments: [key]) }
    }
}
