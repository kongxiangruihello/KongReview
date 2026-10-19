import Foundation
import GRDB
import KongReviewCore

enum LearningExplorerRoute: Equatable, Sendable {
    case day(Date)
    case difficult
    case related(Int64)
    case document(GlobalSearchTarget, String)
}
struct LearningExplorerRequest: Identifiable {
    let id = UUID()
    let route: LearningExplorerRoute
}
struct LearningExplorerRow: Identifiable, Sendable {
    let id: Int64
    let target: GlobalSearchTarget?
    let title: String
    let detail: String
}
struct LearningExplorerPage: Sendable {
    let rows: [LearningExplorerRow]
    let total: Int
}
extension AppDatabase {
    func learningExplorerPage(_ route: LearningExplorerRoute, deck: String = "", offset: Int = 0,
                              now: Date = Date(), calendar: Calendar = .current) async throws -> LearningExplorerPage {
        try await writer.read { db in
            let from: String, title: String, detail: String, targetKind: String, order: String
            var args: [any DatabaseValueConvertible] = []
            switch route {
            case .day(let date):
                let start = calendar.startOfDay(for: date)
                let end = calendar.date(byAdding: .day, value: 1, to: start)!
                from = "FROM review_event e LEFT JOIN card c ON e.cardId=c.id LEFT JOIN highlight h ON e.highlightId=h.id WHERE e.at >= ? AND e.at < ?"
                args = [start, end]
                title = "CASE WHEN e.kind='card' THEN coalesce(c.front,'已删除的记忆卡') ELSE coalesce(h.text,'已删除的摘录') END"
                detail = "e.kind AS kind, e.answer AS answer, e.at AS at"
                targetKind = "CASE WHEN e.kind='card' THEN 'card' ELSE 'highlight' END AS targetKind, CASE WHEN e.kind='card' AND c.deletedAt IS NULL THEN c.id WHEN e.kind!='card' AND h.deletedAt IS NULL THEN h.id END AS targetID"
                order = "e.at DESC, e.id DESC"
            case .difficult:
                let start = calendar.date(byAdding: .day, value: -30, to: now)!
                from = "FROM card c JOIN (SELECT cardId, COUNT(*) AS failures FROM review_event WHERE kind='card' AND answer=1 AND at>=? AND at<=? GROUP BY cardId HAVING COUNT(*)>=3) e ON e.cardId=c.id WHERE c.deletedAt IS NULL" + (deck.isEmpty ? "" : " AND c.deck=?")
                args = [start, now]; if !deck.isEmpty { args.append(deck) }
                title = "c.front"; detail = "c.deck AS deck, e.failures AS failures, c.isSuspended AS suspended"
                targetKind = "'card' AS targetKind, c.id AS targetID"; order = "e.failures DESC, c.id DESC"
            case .related(let id):
                from = "FROM card c WHERE c.deletedAt IS NULL AND c.highlightId=?"; args = [id]
                title = "c.front"; detail = "c.deck AS deck, c.reps AS reps"
                targetKind = "'card' AS targetKind, c.id AS targetID"; order = "c.id DESC"
            case .document: return .init(rows: [], total: 0)
            }
            let idColumn: String = { if case .day = route { return "e.id" }; return "c.id" }()
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + from, arguments: StatementArguments(args)) ?? 0
            let rows = try Row.fetchAll(db, sql: "SELECT \(idColumn) AS rowID, \(title) AS title, \(detail), \(targetKind) " + from + " ORDER BY " + order + " LIMIT 50 OFFSET ?", arguments: StatementArguments(args + [max(0,offset)]))
            return .init(rows: rows.map { row in
                let targetID: Int64? = row["targetID"]
                let kind = GlobalSearchKind(rawValue: row["targetKind"]) ?? .highlight
                let description: String
                switch route {
                case .day:
                    let action: String = row["kind"]
                    let rating: Int? = row["answer"]
                    let labels = [1:"重来", 2:"困难", 3:"良好", 4:"简单"]
                    let actions = ["keep":"保留", "discard":"弃置", "favorite":"收藏", "note":"按语"]
                    let date: Date = row["at"]
                    description = date.formatted(date: .omitted, time: .shortened) + " · " + (action == "card" ? "评分：" + (labels[rating ?? 0] ?? "未记录") : actions[action] ?? "回顾") + (targetID == nil ? " · 原条目已删除" : "")
                case .difficult:
                    let count: Int = row["failures"]; let suspended: Bool = row["suspended"]
                    description = "\(row["deck"] as String) · 近30天重来 \(count) 次" + (suspended ? " · 已暂停" : "")
                default: description = "\(row["deck"] as String) · 已学习 \(row["reps"] as Int) 次"
                }
                return .init(id: row["rowID"], target: targetID.map { .init(kind: kind, recordID: $0) },
                    title: String(Markdown.plainText(fromHTML: Card.renderHTML(row["title"])).prefix(180)), detail: description)
            }, total: total)
        }
    }
}
