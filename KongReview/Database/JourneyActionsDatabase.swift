import Foundation
import GRDB
import KongReviewCore

enum PlanStatus: String, CaseIterable, Identifiable {
    case pending, completed, cancelled
    var id: String { rawValue }
    var title: String { switch self { case .pending: "待完成"; case .completed: "已完成"; case .cancelled: "已取消" } }
}
struct CareAdjustment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var cardID: Int64
    var at: Date
    var before: Card
    var after: Card
    var key: String { "care-adjustment.\(id.uuidString)" }
}
struct RelatedCareCard: Identifiable, Sendable {
    var id: Int64
    var title: String
    var available: Bool
    var ratings: Int
    var again: Int
}
enum JourneyError: LocalizedError {
    case missingCard, changedPlan, invalidLink, emptyPlan
    var errorDescription: String? {
        switch self {
        case .missingCard: "原卡片已删除，处理记录仍保留。"
        case .changedPlan: "计划已被其他操作更新。输入已暂存，请重新打开最新计划后再修改。"
        case .invalidLink: "请选择仍存在的其他卡片，不能关联自身。"
        case .emptyPlan: "请至少填写一条学习计划。"
        }
    }
}
extension AppDatabase {
    static func putProgress<T: Encodable>(_ value: T, key: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt", arguments: [key,try JSONEncoder().encode(value),Date()])
    }
    static func readProgress<T: Decodable>(_ type: T.Type, key: String, in db: Database) throws -> T? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key=?", arguments: [key]) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    func planPage(status: PlanStatus, offset: Int = 0) async throws -> GrowthPage<LearningPlan> {
        if status != .cancelled { return try await learningPlans(completed: status == .completed, offset: offset) }
        return try await writer.read { db in
            let from = " FROM app_progress WHERE key LIKE 'learning-plan.%' AND json_extract(CAST(payload AS TEXT),'$.cancelledAt') IS NOT NULL"
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*)" + from) ?? 0
            let data = try Data.fetchAll(db, sql: "SELECT payload" + from + " ORDER BY updatedAt DESC,key LIMIT 50 OFFSET ?", arguments: [max(0,offset)])
            return .init(items: try data.map { try JSONDecoder().decode(LearningPlan.self, from: $0) }, total: total)
        }
    }
    /// Capture content changes only; scheduling and deck moves do not create adjustment records.
    static func recordCareAdjustment(before: Card, after: Card, in db: Database) throws {
        try recordCardContentHistory(before:before,after:after,in:db)
        guard let id = before.id, before.deletedAt == nil, after.deletedAt == nil,
              before.front != after.front || before.back != after.back || before.fields != after.fields || before.sections != after.sections || before.noteType != after.noteType,
              var care = try readProgress(DifficultCardCare.self, key: "difficult-care.\(id)", in: db) else { return }
        let change = CareAdjustment(cardID: id, at: after.updatedAt, before: before, after: after)
        try putProgress(change, key: change.key, in: db)
        if care.baseline == nil { care.baseline = before }
        care.adjustedAt = after.updatedAt; care.resolvedAt = nil
        try putProgress(care, key: care.key, in: db)
    }
    func saveCare(cardID: Int64, reason: DifficultReason, note: String, startTracking: Bool = false, toggleResolved: Bool = false) throws -> DifficultCardCare {
        try writer.write { db in
            var value = try Self.readProgress(DifficultCardCare.self, key: "difficult-care.\(cardID)", in: db) ?? DifficultCardCare(cardID: cardID)
            if value.baseline == nil { value.baseline = try Card.fetchOne(db, key: cardID) }
            value.reason = reason; value.note = note
            if startTracking { value.adjustedAt = Date(); value.resolvedAt = nil }
            if toggleResolved { value.resolvedAt = value.resolvedAt == nil ? Date() : nil }
            try Self.putProgress(value, key: value.key, in: db)
            return value
        }
    }
    func linkCareCard(parent: Int64, child: Int64, remove: Bool = false) throws {
        try writer.write { db in
            guard var care = try Self.readProgress(DifficultCardCare.self, key: "difficult-care.\(parent)", in: db) else { throw JourneyError.missingCard }
            var ids = care.relatedCardIDs ?? []
            if remove { ids.removeAll { $0 == child } }
            else {
                guard parent != child, let card = try Card.fetchOne(db, key: child), card.deletedAt == nil else { throw JourneyError.invalidLink }
                if !ids.contains(child) { ids.append(child) }
            }
            care.relatedCardIDs = ids
            try Self.putProgress(care, key: care.key, in: db)
        }
    }
    func careAdjustments(cardID: Int64, offset: Int = 0) async throws -> GrowthPage<CareAdjustment> {
        try await writer.read { db in
            let from = " FROM app_progress WHERE key LIKE 'care-adjustment.%' AND json_extract(CAST(payload AS TEXT),'$.cardID')=?"
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*)" + from, arguments: [cardID]) ?? 0
            let data = try Data.fetchAll(db, sql: "SELECT payload" + from + " ORDER BY json_extract(CAST(payload AS TEXT),'$.at') DESC,key LIMIT 50 OFFSET ?", arguments: [cardID,max(0,offset)])
            return .init(items: try data.map { try JSONDecoder().decode(CareAdjustment.self, from: $0) }, total: total)
        }
    }
    func careRelatedCards(cardID: Int64, now: Date = Date(), offset: Int = 0) async throws -> GrowthPage<RelatedCareCard> {
        try await writer.read { db in
            guard let care = try Self.readProgress(DifficultCardCare.self, key: "difficult-care.\(cardID)", in: db) else { return .init(items: [], total: 0) }
            let ids = care.relatedCardIDs ?? []
            let start = care.adjustedAt ?? care.startedAt
            let end = min(now,Calendar.current.date(byAdding:.day,value:14,to:start)!)
            let rows = try Array(ids.dropFirst(max(0,offset)).prefix(50)).map { id -> RelatedCareCard in
                let card = try Card.fetchOne(db, key: id)
                let counts = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS total,COUNT(CASE WHEN answer=1 THEN 1 END) AS again FROM review_event WHERE kind='card' AND cardId=? AND at>=? AND at<?", arguments: [id,start,end])!
                return .init(id: id, title: card.map { String(Markdown.plainText(fromHTML: Card.renderHTML($0.front)).prefix(180)) } ?? "原卡片已删除", available: card != nil && card?.deletedAt == nil, ratings: counts["total"], again: counts["again"])
            }
            return .init(items: rows, total: ids.count)
        }
    }
}
