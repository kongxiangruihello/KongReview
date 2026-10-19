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
    case highlights, cards, ratings, difficult, newHighlights, newCards, days
    var id: String { rawValue }
    var title: String { switch self {
    case .highlights: "回顾摘录（条）"; case .cards: "学习记忆卡（张）"; case .ratings: "评分次数"
    case .difficult: "反复重来的卡片"; case .newHighlights: "新增摘录"; case .newCards: "新增记忆卡"; case .days: "学习天数"
    } }
}
struct GrowthSummary: Sendable {
    var values: [GrowthMetric:Int] = [:]
    subscript(_ metric: GrowthMetric) -> Int { values[metric] ?? 0 }
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
    func growthSummary(start: Date, end: Date) async throws -> GrowthSummary {
        try await writer.read { db in
            let args: StatementArguments = [start,end]
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT CASE WHEN kind NOT IN ('card','note') THEN highlightId END) AS highlights,
                    COUNT(DISTINCT CASE WHEN kind='card' THEN cardId END) AS cards,
                    COUNT(CASE WHEN kind='card' AND cardId IS NOT NULL THEN 1 END) AS ratings,
                    COUNT(DISTINCT CASE WHEN (kind='card' AND cardId IS NOT NULL) OR (kind NOT IN ('card','note') AND highlightId IS NOT NULL) THEN date(at,'localtime') END) AS days
                FROM review_event WHERE at>=? AND at<?
                """, arguments: args)!
            var values: [GrowthMetric:Int] = [.highlights:row["highlights"],.cards:row["cards"],.ratings:row["ratings"],.days:row["days"]]
            values[.difficult] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT cardId FROM review_event WHERE kind='card' AND answer=1 AND cardId IS NOT NULL AND at>=? AND at<? GROUP BY cardId HAVING COUNT(*)>=3)", arguments: args) ?? 0
            for (metric,table) in [(GrowthMetric.newHighlights,"highlight"),(.newCards,"card")] {
                values[metric] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE createdAt>=? AND createdAt<?", arguments: args) ?? 0
            }
            return .init(values: values)
        }
    }
    func growthDetails(metric: GrowthMetric, start: Date, end: Date, offset: Int) async throws -> LearningExplorerPage {
        try await writer.read { db in
            let query: String
            switch metric {
            case .newHighlights, .newCards:
                let card = metric == .newCards
                query = "SELECT id AS rowID, id AS targetID, '\(card ? "card" : "highlight")' AS targetKind, \(card ? "front" : "text") AS title, deletedAt, '新增记录' AS detail FROM \(card ? "card" : "highlight") WHERE createdAt>=? AND createdAt<? ORDER BY createdAt DESC,id DESC"
            case .days:
                query = "SELECT MIN(id) AS rowID, NULL AS targetID, 'highlight' AS targetKind, date(at,'localtime') AS title, NULL AS deletedAt, CAST(COUNT(*) AS TEXT)||' 次操作／评分' AS detail FROM review_event WHERE at>=? AND at<? AND ((kind='card' AND cardId IS NOT NULL) OR (kind NOT IN ('card','note') AND highlightId IS NOT NULL)) GROUP BY date(at,'localtime') ORDER BY title DESC"
            case .highlights, .cards, .difficult, .ratings:
                let card = metric != .highlights
                let identifier = card ? "cardId" : "highlightId"
                let condition = card ? "e.kind='card' AND e.cardId IS NOT NULL" : "e.kind NOT IN ('card','note') AND e.highlightId IS NOT NULL"
                let rating = metric == .ratings
                query = "SELECT \(rating ? "e.id" : "e.\(identifier)") AS rowID,c.id AS targetID,'\(card ? "card" : "highlight")' AS targetKind,coalesce(c.\(card ? "front" : "text"),'原条目已删除') AS title,c.deletedAt,\(rating ? "CASE e.answer WHEN 1 THEN '重来' WHEN 2 THEN '困难' WHEN 3 THEN '良好' WHEN 4 THEN '简单' ELSE '评分' END" : "CAST(COUNT(*) AS TEXT)||' 次记录'") AS detail FROM review_event e LEFT JOIN \(card ? "card" : "highlight") c ON c.id=e.\(identifier) WHERE e.at>=? AND e.at<? AND \(condition)" + (metric == .difficult ? " AND e.answer=1" : "") + (rating ? "" : " GROUP BY e.\(identifier)") + (metric == .difficult ? " HAVING COUNT(*)>=3" : "") + " ORDER BY MAX(e.at) DESC,rowID DESC"
            }
            // 单条评分不能使用聚合排序，否则 SQLite 会把全部评分压成一行。
            let sql = metric == .ratings ? query.replacingOccurrences(of: "MAX(e.at)", with: "e.at") : query
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(sql))", arguments: [start,end]) ?? 0
            let rows = try Row.fetchAll(db, sql: sql + " LIMIT 50 OFFSET ?", arguments: [start,end,max(0,offset)])
            return .init(rows: rows.map { row in
                let id: Int64? = row["targetID"], deleted: Date? = row["deletedAt"]
                let target = id.flatMap { deleted == nil ? GlobalSearchTarget(kind: GlobalSearchKind(rawValue: row["targetKind"])!, recordID: $0) : nil }
                let text: String = row["title"]
                return .init(id: row["rowID"], target: target, title: String(Markdown.plainText(fromHTML: Card.renderHTML(text)).prefix(180)), detail: (row["detail"] as String) + (metric != .days && target == nil ? " · 原条目已删除" : ""))
            }, total: total)
        }
    }
}
