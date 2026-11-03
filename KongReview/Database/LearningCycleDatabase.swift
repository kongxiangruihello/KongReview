import Foundation
import GRDB
import KongReviewCore

struct PlanEvidence: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable { case highlight, block, card }
    var kind: Kind
    var recordID: Int64
    var title: String
    var id: String { "\(kind.rawValue).\(recordID)" }
}
struct PlanOutcome: Codable, Equatable, Sendable {
    var gains = ""
    var evidence: PlanEvidence?
}
struct TopicTimelineEntry: Identifiable, Sendable {
    var id: String
    var at: Date
    var kind: String
    var title: String
    var target: GlobalSearchTarget?
}
struct TopicCardEdit: Codable, Sendable {
    var id = UUID()
    var cardID: Int64
    var notebookIDs: [Int64]
    var at: Date
    var title: String
}
extension AppDatabase {
    static func recordTopicCardEdit(before: Card, after: Card, in db: Database) throws {
        guard let id = after.id, before.deletedAt == nil, after.deletedAt == nil,
              before.front != after.front || before.back != after.back || before.fields != after.fields || before.sections != after.sections || before.noteType != after.noteType else { return }
        let ids = try Int64.fetchAll(db,sql:"SELECT DISTINCT notebookId FROM notebook_block WHERE highlightId IN (?,?)",arguments:[before.highlightId,after.highlightId])
        guard !ids.isEmpty else { return }
        let edit = TopicCardEdit(cardID:id,notebookIDs:ids,at:after.updatedAt,title:after.front)
        try Self.putProgress(edit,key:"topic-card-edit.\(edit.id.uuidString)",in:db)
    }
    func topicTimeline(notebookID: Int64, offset: Int = 0) async throws -> GrowthPage<TopicTimelineEntry> {
        try await writer.read { db in
            // SQL pages the union; duplicate excerpt references do not duplicate its creation event.
            let sql = """
                WITH members AS (SELECT DISTINCT highlightId FROM notebook_block WHERE notebookId=? AND highlightId IS NOT NULL), events AS (
                SELECT 'h.'||h.id AS id,h.createdAt AS at,'新增摘录' AS kind,h.text AS title,'highlight' AS targetKind,h.id AS targetID FROM highlight h JOIN members m ON m.highlightId=h.id WHERE h.deletedAt IS NULL
                UNION ALL
                SELECT 'n.'||b.id,b.updatedAt,'笔记／批注（最近修改）',CASE WHEN b.kind='text' THEN b.text ELSE b.note END,NULL,NULL FROM notebook_block b WHERE b.notebookId=? AND (b.kind='text' OR trim(coalesce(b.note,''))!='')
                UNION ALL
                SELECT 'hn.'||h.id,h.updatedAt,'摘录按语（条目最近修改）',h.note,'highlight',h.id FROM highlight h JOIN members m ON m.highlightId=h.id WHERE h.deletedAt IS NULL AND trim(coalesce(h.note,''))!=''
                UNION ALL
                SELECT p.key,datetime(json_extract(CAST(p.payload AS TEXT),'$.at')+978307200,'unixepoch'),'修改记忆卡',json_extract(CAST(p.payload AS TEXT),'$.title'),'card',c.id FROM app_progress p LEFT JOIN card c ON c.id=json_extract(CAST(p.payload AS TEXT),'$.cardID') AND c.deletedAt IS NULL WHERE p.key LIKE 'topic-card-edit.%' AND EXISTS(SELECT 1 FROM json_each(json_extract(CAST(p.payload AS TEXT),'$.notebookIDs')) WHERE value=?)
                UNION ALL
                SELECT p.key,datetime(json_extract(CAST(p.payload AS TEXT),'$.completedAt')+978307200,'unixepoch'),'完成计划',json_extract(CAST(p.payload AS TEXT),'$.title')||CASE WHEN coalesce(json_extract(CAST(p.payload AS TEXT),'$.outcome.gains'),'')!='' THEN char(10)||json_extract(CAST(p.payload AS TEXT),'$.outcome.gains') ELSE '' END,NULL,NULL FROM app_progress p WHERE p.key LIKE 'learning-plan.%' AND json_extract(CAST(p.payload AS TEXT),'$.completedAt') IS NOT NULL AND json_extract(CAST(p.payload AS TEXT),'$.cancelledAt') IS NULL AND (
                  (json_extract(CAST(p.payload AS TEXT),'$.link.kind')='notebook' AND json_extract(CAST(p.payload AS TEXT),'$.link.recordID')=?) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.link.kind')='card' AND json_extract(CAST(p.payload AS TEXT),'$.link.recordID') IN (SELECT id FROM card WHERE highlightId IN (SELECT highlightId FROM members))) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='highlight' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT highlightId FROM members)) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='card' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT id FROM card WHERE highlightId IN (SELECT highlightId FROM members))) OR
                  (json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.kind')='block' AND json_extract(CAST(p.payload AS TEXT),'$.outcome.evidence.recordID') IN (SELECT id FROM notebook_block WHERE notebookId=?))
                ))
                """
            let args: [any DatabaseValueConvertible] = [notebookID,notebookID,notebookID,notebookID,notebookID]
            let count = try Int.fetchOne(db,sql:sql + " SELECT COUNT(*) FROM events",arguments:StatementArguments(args)) ?? 0
            let rows = try Row.fetchAll(db,sql:sql + " SELECT * FROM events ORDER BY at DESC,id LIMIT 50 OFFSET ?",arguments:StatementArguments(args + [max(0,offset)]))
            return .init(items:rows.map { row in
                let kind: String? = row["targetKind"], id: Int64? = row["targetID"]
                return .init(id:row["id"],at:row["at"],kind:row["kind"],title:Markdown.plainText(fromHTML:Card.renderHTML(row["title"])),target:id.flatMap { id in kind.flatMap(GlobalSearchKind.init(rawValue:)).map { .init(kind:$0,recordID:id) } })
            },total:count)
        }
    }
}
