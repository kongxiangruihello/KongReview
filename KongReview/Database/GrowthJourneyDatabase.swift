import Foundation
import GRDB
import KongReviewCore

enum GrowthTrendRange: String, CaseIterable, Identifiable {
    case days, weeks, months
    var id: String { rawValue }
    var title: String { switch self { case .days: "近30天"; case .weeks: "近12周"; case .months: "近12个月" } }
    var period: GrowthPeriod { switch self { case .days: .day; case .weeks: .week; case .months: .month } }
    func windows(now: Date = Date(), calendar: Calendar = .current) -> [GrowthWindow] {
        let start = calendar.dateInterval(of: period.component, for: now)!.start
        return (0..<(self == .days ? 30 : 12)).reversed().map {
            period.window(containing: calendar.date(byAdding: period.component, value: -$0, to: start)!, now: now, calendar: calendar)
        }
    }
}
struct GrowthTrendPoint: Identifiable, Sendable {
    let window: GrowthWindow
    let summary: GrowthSummary
    var id: String { window.key }
}
struct GrowthHistoryEntry: Identifiable, Sendable {
    let id: String
    let period: GrowthPeriod
    let date: Date
    let reflection: GrowthReflection
    static func parse(key: String, reflection: GrowthReflection, calendar: Calendar = .current) -> Self? {
        let parts = key.split(separator: ".")
        guard parts.count == 3, let period = GrowthPeriod(rawValue: String(parts[1])) else { return nil }
        let numbers = parts[2].split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3, let date = calendar.date(from: .init(year: numbers[0], month: numbers[1], day: numbers[2])) else { return nil }
        return .init(id: key, period: period, date: date, reflection: reflection)
    }
}
struct GrowthPage<T: Sendable>: Sendable { var items: [T]; var total: Int }

enum LearningPlanLinkKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case notebook, source, card
    var id: String { rawValue }
    var title: String { switch self { case .notebook: "笔记本"; case .source: "出处"; case .card: "记忆卡" } }
}
struct LearningPlanLink: Codable, Equatable, Identifiable, Sendable {
    var kind: LearningPlanLinkKind
    var recordID: Int64
    var title: String
    var id: String { "\(kind.rawValue).\(recordID)" }
}
struct LearningPlan: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
    var dueDate = Date()
    var createdAt = Date()
    var completedAt: Date?
    var cancelledAt: Date?
    var recurrenceID: UUID?
    var outcome: PlanOutcome?
    var originKey: String?
    var link: LearningPlanLink?
    var key: String { "learning-plan.\(id.uuidString)" }
}
enum DifficultReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case split, context, shelved
    var id: String { rawValue }
    var title: String { switch self { case .split: "需要拆分"; case .context: "需要补充背景"; case .shelved: "暂缓处理" } }
}
struct DifficultCardCare: Codable, Equatable, Sendable {
    let cardID: Int64
    var reason: DifficultReason = .split
    var note = ""
    var startedAt = Date()
    var adjustedAt: Date?
    var resolvedAt: Date?
    var baseline: Card?
    var relatedCardIDs: [Int64]?
    var key: String { "difficult-care.\(cardID)" }
}
struct CardCareComparison: Sendable {
    let beforeRatings: Int, beforeAgain: Int, afterRatings: Int, afterAgain: Int
    let days: Int
    var interpretation: String {
        guard beforeRatings >= 3, afterRatings >= 3 else { return "评分样本不足：前后各至少3次评分后再比较。" }
        let before = Double(beforeAgain)/Double(beforeRatings), after = Double(afterAgain)/Double(afterRatings)
        if after < before { return "重来比例下降，可继续观察；这不等于已经掌握。" }
        if after > before { return "重来比例上升，建议再次检查问题是否清楚、答案是否过长。" }
        return "重来比例持平，继续观察。"
    }
}
extension AppDatabase {
    func growthTrend(_ range: GrowthTrendRange, now: Date = Date(), calendar: Calendar = .current) async throws -> [GrowthTrendPoint] {
        let windows = range.windows(now: now, calendar: calendar)
        return try await writer.read { db in
            try windows.map { window in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT CASE WHEN kind NOT IN ('card','note') THEN highlightId END) AS highlights,
                    COUNT(DISTINCT CASE WHEN kind='card' THEN cardId END) AS cards,
                    COUNT(CASE WHEN kind='card' AND cardId IS NOT NULL THEN 1 END) AS ratings
                    FROM review_event WHERE at>=? AND at<?
                    """, arguments: [window.start, window.end])!
                return .init(window: window, summary: .init(values: [.highlights: row["highlights"], .cards: row["cards"], .ratings: row["ratings"]]))
            }
        }
    }
    func growthHistory(query: String = "", period: GrowthPeriod? = nil, offset: Int = 0) async throws -> GrowthPage<GrowthHistoryEntry> {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key,payload FROM app_progress WHERE key LIKE 'growth.%'")
            let needle = ChineseFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
            let entries = try rows.compactMap { row -> GrowthHistoryEntry? in
                let reflection = try JSONDecoder().decode(GrowthReflection.self, from: row["payload"] as Data)
                guard let entry = GrowthHistoryEntry.parse(key: row["key"], reflection: reflection), period == nil || entry.period == period else { return nil }
                guard !reflection.gains.isEmpty || !reflection.challenges.isEmpty || !reflection.nextSteps.isEmpty || reflection.goalCards > 0 || reflection.goalHighlights > 0 else { return nil }
                let text = ChineseFold.fold(Markdown.plainText(fromHTML: [reflection.gains, reflection.challenges, reflection.nextSteps].joined(separator: "\n"))).lowercased()
                return needle.isEmpty || text.contains(needle) ? entry : nil
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            return .init(items: Array(entries.dropFirst(max(0,offset)).prefix(50)), total: entries.count)
        }
    }
    func saveLearningPlan(_ plan: LearningPlan) throws {
        var value = plan
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { throw NSError(domain: "LearningPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写学习计划。"] ) }
        try saveProgress(value, key: value.key)
    }
    /// Independent records avoid one window overwriting changes to other plans.
    func learningPlans(completed: Bool? = nil, start: Date? = nil, end: Date? = nil, offset: Int = 0) async throws -> GrowthPage<LearningPlan> {
        try await writer.read { db in
            var conditions = ["key LIKE 'learning-plan.%'", "json_extract(CAST(payload AS TEXT),'$.cancelledAt') IS NULL"]
            var args: [any DatabaseValueConvertible] = []
            let completion = "json_extract(CAST(payload AS TEXT),'$.completedAt')"
            if let completed { conditions.append(completion + (completed ? " IS NOT NULL" : " IS NULL")) }
            if let start { conditions.append(completion + ">=?"); args.append(start.timeIntervalSinceReferenceDate) }
            if let end { conditions.append(completion + "<?"); args.append(end.timeIntervalSinceReferenceDate) }
            let clause = " FROM app_progress WHERE " + conditions.joined(separator: " AND ")
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*)" + clause, arguments: StatementArguments(args)) ?? 0
            let order = completed == true ? completion + " DESC,key" : "json_extract(CAST(payload AS TEXT),'$.dueDate'),key"
            let rows = try Data.fetchAll(db, sql: "SELECT payload" + clause + " ORDER BY \(order) LIMIT 50 OFFSET ?", arguments: StatementArguments(args + [max(0,offset)]))
            return .init(items: try rows.map { try JSONDecoder().decode(LearningPlan.self, from: $0) }, total: total)
        }
    }
    func planLinkChoices(kind: LearningPlanLinkKind, query: String, offset: Int = 0) async throws -> GrowthPage<LearningPlanLink> {
        try await writer.read { db in
            let column = kind == .card ? "front" : "title"
            let whereSQL = (kind == .card ? "deletedAt IS NULL" : "1=1") + " AND instr(lower(\(column)),lower(?))>0"
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(kind.rawValue) WHERE \(whereSQL)", arguments: [query]) ?? 0
            let rows = try Row.fetchAll(db, sql: "SELECT id,\(column) AS title FROM \(kind.rawValue) WHERE \(whereSQL) ORDER BY id DESC LIMIT 50 OFFSET ?", arguments: [query,max(0,offset)])
            return .init(items: rows.map { .init(kind: kind, recordID: $0["id"], title: String(Markdown.plainText(fromHTML: Card.renderHTML($0["title"])).prefix(160))) }, total: total)
        }
    }
    func planLinkExists(_ link: LearningPlanLink) async throws -> Bool {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(link.kind.rawValue) WHERE id=?" + (link.kind == .card ? " AND deletedAt IS NULL" : ""), arguments: [link.recordID]) == 1
        }
    }
    func difficultCareList(offset: Int = 0) async throws -> GrowthPage<(DifficultCardCare, String)> {
        try await writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_progress WHERE key LIKE 'difficult-care.%'") ?? 0
            let rows = try Row.fetchAll(db, sql: "SELECT p.payload,c.front FROM app_progress p LEFT JOIN card c ON c.id=CAST(substr(p.key,16) AS INTEGER) AND c.deletedAt IS NULL WHERE p.key LIKE 'difficult-care.%' ORDER BY p.updatedAt DESC,p.key LIMIT 50 OFFSET ?", arguments: [max(0,offset)])
            return .init(items: try rows.map { (try JSONDecoder().decode(DifficultCardCare.self, from: $0["payload"] as Data), $0["front"] as String? ?? "原卡片已删除") }, total: total)
        }
    }
    func cardCareComparison(_ care: DifficultCardCare, now: Date = Date(), calendar: Calendar = .current) async throws -> CardCareComparison? {
        guard let adjusted = care.adjustedAt, now > adjusted else { return nil }
        let cap = calendar.date(byAdding: .day, value: 14, to: adjusted)!
        let end = min(now, cap)
        let elapsed = end.timeIntervalSince(adjusted)
        let start = adjusted.addingTimeInterval(-elapsed)
        return try await writer.read { db in
            func counts(_ a: Date, _ b: Date) throws -> (Int,Int) {
                let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS total,COUNT(CASE WHEN answer=1 THEN 1 END) AS again FROM review_event WHERE kind='card' AND cardId=? AND at>=? AND at<?", arguments: [care.cardID,a,b])!
                return (row["total"],row["again"])
            }
            let before = try counts(start,adjusted), after = try counts(adjusted,end)
            return .init(beforeRatings: before.0, beforeAgain: before.1, afterRatings: after.0, afterAgain: after.1, days: min(14,max(1,Int(ceil(elapsed/86400)))))
        }
    }
}
