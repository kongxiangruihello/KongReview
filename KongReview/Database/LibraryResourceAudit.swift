import Foundation
import GRDB
import KongReviewCore

struct AuditField: Sendable { var name: String; var text: String }
struct AuditDocument: Sendable {
    var kind: String
    var key: String
    var recordID: Int64
    var title: String
    var parentID: Int64?
    var fields: [AuditField]
}
struct AuditScope: Sendable {
    var kind: String
    var maximum: Int64
    var total: Int
    var cursor: Int64 = 0
}
struct AuditIssue: Identifiable, Sendable {
    var id: Int64
    var kind: String
    var key: String
    var recordID: Int64
    var parentID: Int64?
    var title: String
    var field: String
    var value: String
    var message: String
}
extension AppDatabase {
    static let resourceAuditTables = ["highlight","card","article","notebook_block","source","app_progress"]
    static func auditCondition(_ kind: String) -> String {
        switch kind {
        case "highlight","card": return "deletedAt IS NULL"
        case "app_progress": return "(key LIKE 'growth.%' OR key LIKE 'learning-plan.%' OR key LIKE 'topic-question.%' OR key LIKE 'weekly-schedule.%' OR key LIKE 'difficult-care.%')"
        default: return "1"
        }
    }
    func resourceAuditScopes() async throws -> [AuditScope] {
        try await writer.read { db in
            try Self.resourceAuditTables.map { kind in
                let r = try Row.fetchOne(db,sql:"SELECT COALESCE(MAX(rowid),0) AS maximum,COUNT(*) AS total FROM \(kind) WHERE \(Self.auditCondition(kind))")!
                return .init(kind:kind,maximum:r["maximum"],total:r["total"])
            }
        }
    }
    func resourceAuditBatch(_ scope: AuditScope,limit: Int = 32) async throws -> [AuditDocument] {
        guard Self.resourceAuditTables.contains(scope.kind) else { return [] }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db,sql:"SELECT rowid AS auditID,* FROM \(scope.kind) WHERE rowid>? AND rowid<=? AND \(Self.auditCondition(scope.kind)) ORDER BY rowid LIMIT ?",arguments:[scope.cursor,scope.maximum,max(1,limit)])
            return try rows.map { row in
                let id: Int64 = row["auditID"]
                var result = AuditDocument(kind:scope.kind,key:String(id),recordID:id,title:"",fields:[])
                func field(_ column: String,_ label: String) -> AuditField { .init(name:label,text:(row[column] as String?) ?? "") }
                switch scope.kind {
                case "highlight": result.fields = [field("text","原文"),field("translation","译文"),field("note","按语")]
                case "card":
                    let card = try Card(row:row)
                    result.title = card.deck
                    result.fields = [.init(name:"正面",text:card.front),.init(name:"背面",text:card.back)]
                    result.fields += card.fields.enumerated().map { .init(name:"模板字段 \($0.offset+1)",text:$0.element) }
                    result.fields += (card.sections ?? []).map { .init(name:$0.name,text:$0.text) }
                case "article": result.title = row["title"]; result.fields = [field("contentHTML","网页正文")]
                case "notebook_block": result.parentID = row["notebookId"]; result.fields = [field("text","专题文字"),field("note","本文批注")]
                case "source":
                    result.title = row["title"]
                    if let url: String = row["url"],!url.isEmpty { result.fields = [.init(name:"出处网址",text:"<a href=\""+HTMLSourceCodec.attribute(url)+"\">网址</a>")] }
                case "app_progress":
                    result.key = row["key"]; result.title = "个人成长"
                    let data: Data = row["payload"]
                    if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                        let labels = ["gains":"收获","challenges":"困难","nextSteps":"下一步","title":"计划／安排","question":"问题","answer":"解答","note":"处理说明"]
                        for key in labels.keys.sorted() { if let value = object[key] as? String { result.fields.append(.init(name:labels[key]!,text:value)) } }
                        if let outcome = object["outcome"] as? [String:Any],let gains = outcome["gains"] as? String { result.fields.append(.init(name:"计划收获",text:gains)) }
                        if let notebook: Int64 = (object["notebookID"] as? NSNumber)?.int64Value { result.parentID = notebook }
                    }
                default: break
                }
                if result.title.isEmpty { result.title = String(Markdown.plainText(fromHTML:result.fields.first?.text ?? "").prefix(70)) }
                return result
            }
        }
    }
}

/// Results live in a separate in-memory SQLite database, and are paged independently of scanning.
final class AuditResultStore: @unchecked Sendable {
    let queue: DatabaseQueue
    init() throws {
        queue = try DatabaseQueue()
        try queue.write { db in try db.execute(sql:"CREATE TABLE issue(id INTEGER PRIMARY KEY,kind TEXT,recordKey TEXT,recordID INTEGER,parentID INTEGER,title TEXT,field TEXT,value TEXT,message TEXT,UNIQUE(kind,recordKey,field,value,message))") }
    }
    func append(_ documents: [AuditDocument],mediaNames: Set<String>) throws -> Int {
        try queue.write { db in
            var count = 0
            for document in documents {
                try Task.checkCancellation()
                for field in document.fields where !field.text.isEmpty {
                    let source = HTMLSourceCodec.editable(field.text)
                    for reference in EditorResourceCheck.references(source,localExists:{mediaNames.contains($0)}) where reference.problem {
                        try db.execute(sql:"INSERT OR IGNORE INTO issue(kind,recordKey,recordID,parentID,title,field,value,message) VALUES(?,?,?,?,?,?,?,?)",arguments:[document.kind,document.key,document.recordID,document.parentID,document.title,field.name,reference.value,reference.message]); count += db.changesCount
                    }
                }
            }
            return count
        }
    }
    func page(_ number: Int,kind: String,query: String) throws -> (items:[AuditIssue],total:Int) {
        try queue.read { db in
            let condition = "(?='' OR kind=?) AND (?='' OR instr(lower(title||char(10)||field||char(10)||value||char(10)||message),lower(?))>0)"
            let args: StatementArguments = [kind,kind,query,query]
            let total = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM issue WHERE "+condition,arguments:args) ?? 0
            let page = min(max(0,number),max(0,(total-1)/50))
            let rows = try Row.fetchAll(db,sql:"SELECT * FROM issue WHERE "+condition+" ORDER BY id LIMIT 50 OFFSET ?",arguments:args + [page*50])
            return (rows.map { .init(id:$0["id"],kind:$0["kind"],key:$0["recordKey"],recordID:$0["recordID"],parentID:$0["parentID"],title:$0["title"],field:$0["field"],value:$0["value"],message:$0["message"]) },total)
        }
    }
}
