import Foundation
import GRDB
import KongReviewCore

enum LearningMaterialScope: Hashable, Sendable {
    case notebook(Int64), source(Int64)
    var id: Int64 { switch self { case .notebook(let id),.source(let id): id } }
    var predicate: String {
        switch self {
        case .notebook: "EXISTS(SELECT 1 FROM notebook_block b WHERE b.notebookId=? AND b.highlightId=h.id)"
        case .source: "h.sourceId=?"
        }
    }
}
enum TopicSection: String, CaseIterable, Identifiable { case highlights, cards, sources
    var id: String { rawValue }
    var title: String { switch self { case .highlights: "摘录"; case .cards: "记忆卡"; case .sources: "出处" } }
}
struct TopicSnapshot: Sendable {
    var highlights: Int
    var cards: Int
    var sources: Int
    var studied: Int
    var page: LearningExplorerPage
}
struct LearningMaterialOptions: Sendable {
    var text = true, notes = true, cards = true, citations = true
}
struct LearningMaterial: Sendable {
    var title: String
    var highlights: [Highlight]
    var sources: [Source]
    var cards: [Card]
    var notebookNotes: [String]
    func printHTML(options: LearningMaterialOptions) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = markdown(options: options).components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line -> String in
            for level in (1...3).reversed() {
                let prefix = String(repeating: "#", count: level) + " "
                if line.hasPrefix(prefix) { return "<h\(level)>" + escape(String(line.dropFirst(prefix.count))) + "</h\(level)>" }
            }
            return "<p>" + escape(line) + "</p>"
        }.joined()
        return "<html><head><meta charset='utf-8'><style>body{font:12pt 'PingFang SC';line-height:1.7;color:#222}p{white-space:pre-wrap;overflow-wrap:anywhere}h1{font-size:23pt}h2{font-size:17pt;margin-top:26pt}h3{font-size:14pt}h1,h2,h3{page-break-after:avoid}</style></head><body>" + body + "</body></html>"
    }
    func markdown(options: LearningMaterialOptions) -> String {
        func plain(_ text: String) -> String { Markdown.plainText(fromHTML: Card.renderHTML(text)) }
        var lines = ["# " + title, ""]
        if options.text || options.notes || options.citations {
            for (index,h) in highlights.enumerated() {
                lines += ["## 摘录 \(index+1)"]
                if options.text { lines += [plain(h.text),h.translation.map { "译文：" + plain($0) } ?? ""] }
                if options.notes, let note = h.note, !note.isEmpty { lines += ["按语：" + plain(note)] }
                if options.citations { lines += ["出处：" + CitationFormatter.citation(for: h, source: sources.first { $0.id == h.sourceId })] }
                lines += [""]
            }
        }
        if options.notes, !notebookNotes.isEmpty { lines += ["## 专题笔记"] + notebookNotes.map(plain) }
        if options.cards {
            lines += ["## 记忆卡问答"]
            for (index,c) in cards.enumerated() {
                lines += ["### \(index+1). \(c.deck)","问题：" + plain(c.front),"答案：" + plain(c.back)]
                for section in c.sections ?? [] { lines += [section.name + "：" + plain(section.text)] }
                for (i,field) in c.fields.enumerated() { lines += ["字段 \(i+1)：" + plain(field)] }
                if options.citations, let h = highlights.first(where: { $0.id == c.highlightId }) {
                    lines += ["出处：" + CitationFormatter.citation(for: h, source: sources.first { $0.id == h.sourceId })]
                }
                lines += [""]
            }
        }
        return lines.joined(separator: "\n\n")
    }
}
extension AppDatabase {
    func topicSnapshot(scope: LearningMaterialScope, section: TopicSection, offset: Int) async throws -> TopicSnapshot {
        try await writer.read { db in
            let membership = "h.deletedAt IS NULL AND " + scope.predicate
            let hFrom = " FROM highlight h WHERE " + membership
            let cFrom = " FROM card c JOIN highlight h ON h.id=c.highlightId WHERE c.deletedAt IS NULL AND " + membership
            let sFrom = " FROM source s WHERE EXISTS(SELECT 1 FROM highlight h WHERE h.sourceId=s.id AND " + membership + ")"
            func count(_ from: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*)" + from, arguments: [scope.id]) ?? 0 }
            let h = try count(hFrom), c = try count(cFrom), s = try count(sFrom)
            let studied = try count(cFrom + " AND c.reps>0")
            let query: String, kind: GlobalSearchKind, total: Int
            switch section {
            case .highlights: query = "SELECT h.id,h.text AS title" + hFrom; kind = .highlight; total = h
            case .cards: query = "SELECT c.id,c.front AS title" + cFrom; kind = .card; total = c
            case .sources: query = "SELECT s.id,s.title" + sFrom; kind = .source; total = s
            }
            let rows = try Row.fetchAll(db, sql: query + " ORDER BY 1 DESC LIMIT 50 OFFSET ?", arguments: [scope.id,max(0,offset)])
            return .init(highlights: h, cards: c, sources: s, studied: studied, page: .init(rows: rows.map {
                let id: Int64 = $0["id"], raw: String = $0["title"]
                return .init(id: id, target: .init(kind: kind,recordID: id), title: String(Markdown.plainText(fromHTML: Card.renderHTML(raw)).prefix(200)), detail: kind.title)
            }, total: total))
        }
    }
    func learningMaterial(scope: LearningMaterialScope) async throws -> LearningMaterial {
        try await writer.read { db in
            let title: String
            switch scope {
            case .notebook: title = try String.fetchOne(db,sql:"SELECT title FROM notebook WHERE id=?",arguments:[scope.id]) ?? "专题学习资料"
            case .source: title = try String.fetchOne(db,sql:"SELECT title FROM source WHERE id=?",arguments:[scope.id]) ?? "出处学习资料"
            }
            let predicate = "h.deletedAt IS NULL AND " + scope.predicate
            let highlights = try Highlight.fetchAll(db,sql:"SELECT h.* FROM highlight h WHERE " + predicate + " ORDER BY h.id",arguments:[scope.id])
            let cards = try Card.fetchAll(db,sql:"SELECT c.* FROM card c JOIN highlight h ON h.id=c.highlightId WHERE c.deletedAt IS NULL AND " + predicate + " ORDER BY c.id",arguments:[scope.id])
            let sources = try Source.fetchAll(db,sql:"SELECT s.* FROM source s WHERE EXISTS(SELECT 1 FROM highlight h WHERE h.sourceId=s.id AND " + predicate + ") ORDER BY s.id",arguments:[scope.id])
            var notes: [String] = []
            if case .notebook = scope {
                notes = try String.fetchAll(db,sql:"SELECT CASE WHEN kind='highlight' THEN coalesce(note,'') ELSE text END FROM notebook_block WHERE notebookId=? ORDER BY position,id",arguments:[scope.id]).filter { !$0.isEmpty }
            }
            return .init(title:title,highlights:highlights,sources:sources,cards:cards,notebookNotes:notes)
        }
    }
}
