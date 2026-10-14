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

// MARK: - 1.7：按页码范围

extension AppDatabase {
    /// 书中某个页码范围内的摘录（按页码排序；没有页码的不算）。pages 为 nil 时返回全书（含没有页码的，排在最后）
    func sourceHighlights(_ sourceId: Int64, pages: ClosedRange<Int>?) throws -> [Highlight] {
        let all = try sourceHighlightsByPage(sourceId)
        guard let pages else { return all }
        return all.filter { h in SearchSyntax.firstNumber(h.location).map { pages.contains($0) } ?? false }
    }
}

// MARK: - 1.9：原文语境、每日活动

extension AppDatabase {
    /// 同一出处里按页码排在这条前后的几条摘录（记忆卡背面“原文语境”）；index 为这条在结果里的位置
    func contextHighlights(around highlightId: Int64, radius: Int = 2) throws -> (items: [Highlight], index: Int)? {
        guard let h = try highlights(ids: [highlightId]).first, let sid = h.sourceId else { return nil }
        let all = try sourceHighlightsByPage(sid)
        guard let i = all.firstIndex(where: { $0.id == highlightId }) else { return nil }
        let lo = max(0, i - radius), hi = min(all.count - 1, i + radius)
        return (Array(all[lo...hi]), i - lo)
    }

    /// 某一天看过的摘录条数与复习记忆卡的次数（本地日期）
    func activity(on day: Date) throws -> (highlights: Int, cards: Int) {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return try writer.read { db in
            let r = try Row.fetchOne(db, sql: """
                SELECT SUM(CASE WHEN kind NOT IN ('card', 'note') THEN 1 ELSE 0 END) AS h,
                       SUM(CASE WHEN kind = 'card' THEN 1 ELSE 0 END) AS c
                FROM review_event WHERE at >= ? AND at < ?
                """, arguments: [start, end])
            return ((r?["h"] as Int?) ?? 0, (r?["c"] as Int?) ?? 0)
        }
    }
}
