import Foundation
import GRDB
import KongReviewCore

// MARK: - 1.6：出处书页

struct SourcePageStats: Equatable {
    var total = 0
    var withPage = 0
    var reviewed = 0
    var withNote = 0
    var cards = 0
    var favorites = 0
    var firstPage: Int?
    var lastPage: Int?
}

extension AppDatabase {
    func sourcePageStats(_ sourceId: Int64) throws -> SourcePageStats {
        try writer.read { db in
            var s = SourcePageStats()
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n,
                       SUM(CASE WHEN kr_page(location) IS NOT NULL THEN 1 ELSE 0 END) AS p,
                       SUM(CASE WHEN surfacedCount > 0 THEN 1 ELSE 0 END) AS r,
                       SUM(CASE WHEN trim(coalesce(note, '')) <> '' THEN 1 ELSE 0 END) AS nt,
                       SUM(CASE WHEN isFavorite = 1 THEN 1 ELSE 0 END) AS f,
                       MIN(kr_page(location)) AS lo, MAX(kr_page(location)) AS hi
                FROM highlight WHERE sourceId = ? AND deletedAt IS NULL AND isDiscarded = 0
                """, arguments: [sourceId])
            s.total = (r?["n"] as Int?) ?? 0
            s.withPage = (r?["p"] as Int?) ?? 0
            s.reviewed = (r?["r"] as Int?) ?? 0
            s.withNote = (r?["nt"] as Int?) ?? 0
            s.favorites = (r?["f"] as Int?) ?? 0
            s.firstPage = r?["lo"]
            s.lastPage = r?["hi"]
            s.cards = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT c.highlightId) FROM card c JOIN highlight h ON h.id = c.highlightId
                WHERE h.sourceId = ? AND c.deletedAt IS NULL AND h.deletedAt IS NULL
                """, arguments: [sourceId]) ?? 0
            return s
        }
    }

    /// 一本书的全部摘录，按页码排序（导出读书笔记用）
    func sourceHighlightsByPage(_ sourceId: Int64) throws -> [Highlight] {
        try highlights(HighlightQuery(sourceId: sourceId, orderByPage: true))
    }
}
