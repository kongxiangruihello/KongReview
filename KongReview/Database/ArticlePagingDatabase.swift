import Foundation
import GRDB
import KongReviewCore

/// 网页列表的一页。正文仍在打开阅读器时按 ID 获取。
struct ArticlePage: Sendable {
    var items: [Article]
    var total: Int
    var page: Int
    var highlightCounts: [Int64: Int]
}

extension AppDatabase {
    /// 计数、有效页码、元数据与本页摘录数使用同一数据库快照。
    func articlePage(query: String, page: Int, pageSize: Int = 200) async throws -> ArticlePage {
        try await writer.read { db in
            let size = max(1, pageSize)
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let filter = text.isEmpty ? "" : " WHERE title LIKE ? ESCAPE '\\' OR siteName LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\'"
            let pattern = SearchQuery.likePattern(text)
            let args: [(any DatabaseValueConvertible)?] = text.isEmpty ? [] : [pattern, pattern, pattern]
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article" + filter,
                                         arguments: StatementArguments(args)) ?? 0
            let pageCount = max(1, (total + size - 1) / size)
            let current = min(max(1, page), pageCount)
            let items = try Article.fetchAll(db, sql: """
                SELECT id, sourceId, url, title, author, siteName, publishedAt, excerpt,
                       '' AS contentHTML, '' AS contentText, wordCount, savedAt, lastOpenedAt, isRead
                FROM article
                """ + filter + " ORDER BY savedAt DESC, id DESC LIMIT ? OFFSET ?",
                arguments: StatementArguments(args + [size, (current - 1) * size]))

            let sourceIDs = Array(Set(items.compactMap(\.sourceId)))
            var bySource: [Int64: Int] = [:]
            if !sourceIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT sourceId, COUNT(*) AS n FROM highlight
                    WHERE deletedAt IS NULL AND sourceId IN (\(placeholders)) GROUP BY sourceId
                    """, arguments: StatementArguments(sourceIDs))
                for row in rows { bySource[row["sourceId"]] = row["n"] }
            }
            var counts: [Int64: Int] = [:]
            for item in items {
                if let id = item.id, let sid = item.sourceId, let count = bySource[sid] {
                    counts[id] = count
                }
            }
            return ArticlePage(items: items, total: total, page: current, highlightCounts: counts)
        }
    }
}
