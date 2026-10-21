import Foundation
import GRDB
import KongReviewCore

enum GlobalSearchKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case highlight, card, article, source
    /// 4.1：札记
    case note
    /// 4.1.1：问题簿
    case question
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: return "札记"
        case .question: return "问题"
        case .highlight: return "摘录"
        case .card: return "记忆卡"
        case .article: return "网页存档"
        case .source: return "出处"
        }
    }
    var symbol: String {
        switch self {
        case .highlight: return "text.quote"
        case .card: return "rectangle.on.rectangle"
        case .article: return "doc.richtext"
        case .source: return "books.vertical"
        case .note: return "lightbulb"
        case .question: return "questionmark.bubble"
        }
    }
}

struct GlobalSearchTarget: Hashable, Sendable {
    var kind: GlobalSearchKind
    var recordID: Int64
}

/// 搜索面板只接收有限长的预览；打开结果时再取完整记录。
struct GlobalSearchHit: Identifiable, Equatable, Sendable {
    var target: GlobalSearchTarget
    var title: String
    var preview: String
    var context: String
    var badge: String?
    var id: String { target.kind.rawValue + ":" + String(target.recordID) }
}

struct GlobalSearchPage: Sendable {
    var kind: GlobalSearchKind
    var items: [GlobalSearchHit]
    var total: Int
    var offset: Int
    var hasMore: Bool { offset + items.count < total }
}

extension AppDatabase {
    /// 四种结果的计数与首屏来自同一快照；后续每类独立加载更多，永远不取全库正文。
    /// 百分号、下划线、反斜杠均按字面匹配，繁简、全半角和英文大小写归一。
    func globalSearch(query: String, kind: GlobalSearchKind? = nil,
                      offset: Int = 0, limit: Int = 20) async throws -> [GlobalSearchPage] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kinds = kind.map { [$0] } ?? GlobalSearchKind.allCases
        guard !text.isEmpty else {
            return kinds.map { GlobalSearchPage(kind: $0, items: [], total: 0, offset: 0) }
        }
        let size = min(100, max(1, limit)), start = max(0, offset)
        return try await writer.read { db in
            db.add(function: Self.globalSearchPlainFunction)
            let term = ChineseFold.fold(text)
            let pattern = SearchQuery.likePattern(term)
            return try kinds.map { kind in
                let query = Self.globalSearchSQL(kind)
                var args: [String: (any DatabaseValueConvertible)?] = [
                    "pattern": pattern, "limit": size, "offset": start
                ]
                if query.select.contains(":term") { args["term"] = term }
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + query.from + query.filter,
                                            arguments: StatementArguments(["pattern": pattern])) ?? 0
                let rows = try Row.fetchAll(db, sql: query.select + query.from + query.filter
                    + query.order + " LIMIT :limit OFFSET :offset", arguments: StatementArguments(args))
                let hits = rows.map { row in
                    GlobalSearchHit(target: GlobalSearchTarget(kind: kind, recordID: row["id"]),
                        title: Self.searchPreview(row["title"] ?? "", maximum: 100),
                        preview: Self.searchPreview(row["preview"] ?? "", maximum: 240),
                        context: Self.searchPreview(row["context"] ?? "", maximum: 140),
                        badge: row["badge"])
                }
                return GlobalSearchPage(kind: kind, items: hits, total: total, offset: start)
            }
        }
    }

    static let globalSearchPlainFunction = DatabaseFunction("kr_search_plain", argumentCount: 1, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return "" }
        guard Markdown.containsHTMLTag(text) || text.contains("&") else { return text }
        return Markdown.plainText(fromHTML: text)
    }

    private static func searchPreview(_ raw: String, maximum: Int) -> String {
        let plain = Markdown.plainText(fromHTML: raw)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(plain.prefix(maximum)) + (plain.count > maximum ? "…" : "")
    }

    private static func globalSearchSQL(_ kind: GlobalSearchKind)
        -> (select: String, from: String, filter: String, order: String) {
        // instr/substr 使用 SQLite 字符位置，在数据库线程里截出命中附近的正文。
        // 即使匹配在长文末尾，也不用把整篇文章传给界面。
        func snippet(_ expression: String) -> String {
            "substr(kr_search_plain(\(expression)), max(1, instr(kr_fold(kr_search_plain(\(expression))), :term) - 60), 300)"
        }
        switch kind {
        case .highlight:
            let body = """
                CASE WHEN kr_fold(kr_search_plain(h.text)) LIKE :pattern ESCAPE '\\' THEN h.text
                WHEN kr_fold(kr_search_plain(coalesce(h.translation, ''))) LIKE :pattern ESCAPE '\\' THEN h.translation
                WHEN kr_fold(kr_search_plain(coalesce(h.note, ''))) LIKE :pattern ESCAPE '\\' THEN h.note ELSE h.text END
                """
            return ("""
                SELECT h.id, coalesce(nullif(s.title, ''), '未归类摘录') AS title,
                       \(snippet(body)) AS preview,
                       coalesce(h.location, '') AS context,
                       CASE WHEN h.isDiscarded THEN '已弃置' ELSE NULL END AS badge
                """, " FROM highlight h LEFT JOIN source s ON s.id = h.sourceId", """
                 WHERE h.deletedAt IS NULL AND (
                    kr_fold(kr_search_plain(h.text)) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(coalesce(h.translation, ''))) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(coalesce(h.note, ''))) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(h.location, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.title, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.author, '')) LIKE :pattern ESCAPE '\\'
                    OR EXISTS (SELECT 1 FROM json_each(h.tags) WHERE kr_fold(value) LIKE :pattern ESCAPE '\\'))
                """, " ORDER BY h.createdAt DESC, h.id DESC")
        case .card:
            let body = """
                CASE WHEN kr_fold(kr_search_plain(c.front)) LIKE :pattern ESCAPE '\\' THEN c.front
                WHEN kr_fold(kr_search_plain(c.back)) LIKE :pattern ESCAPE '\\' THEN c.back
                WHEN EXISTS (SELECT 1 FROM json_each(c.fields) WHERE kr_fold(kr_search_plain(value)) LIKE :pattern ESCAPE '\\')
                  THEN coalesce((SELECT value FROM json_each(c.fields) WHERE kr_fold(kr_search_plain(value)) LIKE :pattern ESCAPE '\\' LIMIT 1), '')
                WHEN EXISTS (SELECT 1 FROM json_each(coalesce(c.sections, '[]')) WHERE kr_fold(kr_search_plain(json_extract(value, '$.text'))) LIKE :pattern ESCAPE '\\')
                  THEN coalesce((SELECT json_extract(value, '$.text') FROM json_each(coalesce(c.sections, '[]')) WHERE kr_fold(kr_search_plain(json_extract(value, '$.text'))) LIKE :pattern ESCAPE '\\' LIMIT 1), '')
                ELSE c.back END
                """
            return ("""
                SELECT c.id, substr(kr_search_plain(c.front), 1, 160) AS title, \(snippet(body)) AS preview,
                       c.deck AS context, CASE WHEN c.isSuspended THEN '已暂停' ELSE NULL END AS badge
                """, " FROM card c", """
                 WHERE c.deletedAt IS NULL AND (
                    kr_fold(kr_search_plain(c.front)) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(c.back)) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(c.deck) LIKE :pattern ESCAPE '\\'
                    OR EXISTS (SELECT 1 FROM json_each(c.tags) WHERE kr_fold(value) LIKE :pattern ESCAPE '\\')
                    OR EXISTS (SELECT 1 FROM json_each(c.fields) WHERE kr_fold(kr_search_plain(value)) LIKE :pattern ESCAPE '\\')
                    OR EXISTS (SELECT 1 FROM json_each(coalesce(c.sections, '[]'))
                        WHERE kr_fold(json_extract(value, '$.name')) LIKE :pattern ESCAPE '\\'
                           OR kr_fold(kr_search_plain(json_extract(value, '$.text'))) LIKE :pattern ESCAPE '\\'))
                """, " ORDER BY c.createdAt DESC, c.id DESC")
        case .article:
            let body = "coalesce(nullif(a.contentText, ''), a.contentHTML)"
            return ("""
                SELECT a.id, a.title, \(snippet(body)) AS preview,
                       coalesce(nullif(a.siteName, ''), a.url) AS context,
                       CASE WHEN a.isRead THEN '已读' ELSE '未读' END AS badge
                """, " FROM article a", """
                 WHERE kr_fold(a.title) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(a.author, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(a.siteName, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(a.excerpt, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(a.url) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(\(body))) LIKE :pattern ESCAPE '\\'
                """, " ORDER BY a.savedAt DESC, a.id DESC")
        case .note:
            return ("""
                SELECT n.id, n.title, \(snippet("n.body")) AS preview, '' AS context, NULL AS badge
                """, " FROM idea_note n", """
                 WHERE n.deletedAt IS NULL AND (kr_fold(n.title) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(n.body)) LIKE :pattern ESCAPE '\\')
                """, " ORDER BY n.updatedAt DESC, n.id DESC")
        case .question:
            let body = "CASE WHEN kr_fold(kr_search_plain(q.answer)) LIKE :pattern ESCAPE '\\' THEN q.answer ELSE q.detail END"
            return ("""
                SELECT q.id, q.title, \(snippet(body)) AS preview, '' AS context,
                       CASE q.status WHEN 'solved' THEN '已解决' WHEN 'shelved' THEN '搁置' WHEN 'lead' THEN '有线索' ELSE '待研究' END AS badge
                """, " FROM question q", """
                 WHERE kr_fold(q.title) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(q.detail)) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(kr_search_plain(q.answer)) LIKE :pattern ESCAPE '\\'
                """, " ORDER BY q.pinned DESC, q.updatedAt DESC, q.id DESC")
        case .source:
            return ("""
                SELECT s.id, s.title,
                       coalesce(s.author, '') || ' ' || coalesce(s.publisher, '') || ' ' || coalesce(s.year, '') AS preview,
                       coalesce(s.edition, '') || ' ' || coalesce(s.container, '') AS context,
                       NULL AS badge
                """, " FROM source s", """
                 WHERE kr_fold(s.title) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(s.author) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.publisher, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.edition, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.container, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.classicTitle, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.year, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.isbn, '')) LIKE :pattern ESCAPE '\\'
                    OR kr_fold(coalesce(s.url, '')) LIKE :pattern ESCAPE '\\'
                """, " ORDER BY s.createdAt DESC, s.id DESC")
        }
    }
}
