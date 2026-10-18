import Foundation
import GRDB
import KongReviewCore

enum GrowthGrouping: String, CaseIterable, Identifiable {
    case source, notebook, deck
    var id: String { rawValue }
    var title: String { switch self { case .source: "按出处"; case .notebook: "按专题"; case .deck: "按牌组" } }
}
struct GrowthBreakdownGroup: Identifiable, Sendable {
    var key: String?
    var title: String
    var count: Int
    var id: String { key.map { "value:" + $0 } ?? "unassigned" }
}
extension GrowthMetric {
    var isCardMetric: Bool { [.cards,.ratings,.difficult,.newCards].contains(self) }
}
private struct GrowthBreakdownQuery {
    let cte: String
    let joins: String
    let key: String
    let title: String
    init(metric: GrowthMetric, grouping: GrowthGrouping) {
        let card = metric.isCardMetric
        let query: String
        if metric == .newCards || metric == .newHighlights {
            query = "SELECT id AS rowID,id AS targetID,'\(card ? "card" : "highlight")' AS kind,\(card ? "front" : "text") AS title,deletedAt,\(card ? "highlightId" : "id") AS highlightID,\(card ? "deck" : "NULL") AS deck,createdAt AS at FROM \(card ? "card" : "highlight") WHERE createdAt>=? AND createdAt<?"
        } else {
            let ratings = metric == .ratings
            let id = card ? "cardId" : "highlightId"
            let conditions = card ? "e.kind='card' AND e.cardId IS NOT NULL" : "e.kind NOT IN ('card','note') AND e.highlightId IS NOT NULL"
            query = "SELECT \(ratings ? "e.id" : "e.\(id)") AS rowID,c.id AS targetID,'\(card ? "card" : "highlight")' AS kind,coalesce(c.\(card ? "front" : "text"),'原条目已删除') AS title,c.deletedAt,\(card ? "c.highlightId" : "c.id") AS highlightID,\(card ? "c.deck" : "NULL") AS deck,\(ratings ? "e.at" : "MAX(e.at)") AS at FROM review_event e LEFT JOIN \(card ? "card" : "highlight") c ON c.id=e.\(id) WHERE e.at>=? AND e.at<? AND \(conditions)" + (metric == .difficult ? " AND e.answer=1" : "") + (ratings ? "" : " GROUP BY e.\(id)") + (metric == .difficult ? " HAVING COUNT(*)>=3" : "")
        }
        cte = "WITH activity AS (\(query)) "
        switch grouping {
        case .source:
            joins = " FROM activity a LEFT JOIN highlight h ON h.id=a.highlightID LEFT JOIN source s ON s.id=h.sourceId"
            key = "CAST(s.id AS TEXT)"; title = "coalesce(s.title,'未关联出处／原内容已删除')"
        case .notebook:
            joins = " FROM activity a LEFT JOIN (SELECT DISTINCT notebookId,highlightId FROM notebook_block WHERE highlightId IS NOT NULL) b ON b.highlightId=a.highlightID LEFT JOIN notebook n ON n.id=b.notebookId"
            key = "CAST(n.id AS TEXT)"; title = "coalesce(n.title,'未归入专题／原内容已删除')"
        case .deck:
            joins = " FROM activity a"
            key = "a.deck"; title = "coalesce(a.deck,'原卡片已删除')"
        }
    }
}
extension AppDatabase {
    func growthBreakdown(metric: GrowthMetric, grouping: GrowthGrouping, start: Date, end: Date, offset: Int = 0) async throws -> GrowthPage<GrowthBreakdownGroup> {
        guard metric != .days, grouping != .deck || metric.isCardMetric else { return .init(items: [], total: 0) }
        let q = GrowthBreakdownQuery(metric: metric, grouping: grouping)
        return try await writer.read { db in
            let grouped = "SELECT \(q.key) AS groupKey,\(q.title) AS title,COUNT(*) AS amount" + q.joins + " GROUP BY \(q.key)"
            let total = try Int.fetchOne(db, sql: q.cte + "SELECT COUNT(*) FROM (\(grouped))", arguments: [start,end]) ?? 0
            let rows = try Row.fetchAll(db, sql: q.cte + grouped + " ORDER BY amount DESC,title,groupKey LIMIT 50 OFFSET ?", arguments: [start,end,max(0,offset)])
            return .init(items: rows.map { .init(key: $0["groupKey"], title: $0["title"], count: $0["amount"]) }, total: total)
        }
    }
    func growthBreakdownDetails(metric: GrowthMetric, grouping: GrowthGrouping, key: String?, start: Date, end: Date, offset: Int = 0) async throws -> LearningExplorerPage {
        guard metric != .days, grouping != .deck || metric.isCardMetric else { return .init(rows: [], total: 0) }
        let q = GrowthBreakdownQuery(metric: metric, grouping: grouping)
        return try await writer.read { db in
            let from = q.joins + " WHERE \(q.key) IS ?"
            let total = try Int.fetchOne(db, sql: q.cte + "SELECT COUNT(*)" + from, arguments: [start,end,key]) ?? 0
            let rows = try Row.fetchAll(db, sql: q.cte + "SELECT a.*" + from + " ORDER BY a.at DESC,a.rowID DESC LIMIT 50 OFFSET ?", arguments: [start,end,key,max(0,offset)])
            return .init(rows: rows.map { row in
                let id: Int64? = row["targetID"], deleted: Date? = row["deletedAt"]
                let target = id.flatMap { deleted == nil ? GlobalSearchTarget(kind: GlobalSearchKind(rawValue: row["kind"])!, recordID: $0) : nil }
                let at: Date = row["at"]
                return .init(id: row["rowID"], target: target, title: String(Markdown.plainText(fromHTML: Card.renderHTML(row["title"])).prefix(220)), detail: at.formatted(date:.abbreviated,time:.shortened) + (target == nil ? " · 原条目已删除" : ""))
            }, total: total)
        }
    }
}
