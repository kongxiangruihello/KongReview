import Foundation
import GRDB
import KongReviewCore

// MARK: - 1.5：重复摘录、久未回顾

/// 合并重复摘录后可撤销所需的记录
struct DuplicateMergeUndo {
    /// 合并前的各条摘录（保留的那条与被并掉的几条）
    var originals: [Highlight]
    /// 改指向的引用：(表, 行 id, 原 highlightId)
    var repointed: [(table: String, rowid: Int64, old: Int64)]
}

extension AppDatabase {
    /// 未删除的全部摘录（找重复用：只要 id、原文、出处）
    func duplicateCandidates() throws -> [DuplicateFinder.Item] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text, sourceId FROM highlight WHERE deletedAt IS NULL").map {
                DuplicateFinder.Item(id: $0["id"], text: $0["text"], sourceId: $0["sourceId"])
            }
        }
    }

    /// 把 others 并入 keeper：字段合并（见 DuplicateFinder.merged），记忆卡、回顾记录、导入记录、笔记本引用改指向 keeper，
    /// others 移入“最近删除”。返回撤销所需的记录。
    @discardableResult
    func mergeHighlights(keeper keeperID: Int64, others otherIDs: [Int64], now: Date = Date()) throws -> DuplicateMergeUndo {
        try writer.write { db in
            let ids = [keeperID] + otherIDs.filter { $0 != keeperID }
            let all = try Highlight.filter(keys: ids).fetchAll(db)
            guard let keeper = all.first(where: { $0.id == keeperID }) else {
                throw ImportFileError("要保留的摘录已不存在。")
            }
            let others = all.filter { $0.id != keeperID }
            var undo = DuplicateMergeUndo(originals: all, repointed: [])
            let otherList = others.compactMap(\.id)
            guard !otherList.isEmpty else { return undo }
            let marks = otherList.map { _ in "?" }.joined(separator: ",")
            for table in ["card", "review_event", "inbox_item", "notebook_block"] {
                let rowidCol = table == "inbox_item" ? "rowid" : "id"
                let rows = try Row.fetchAll(db, sql: "SELECT \(rowidCol) AS r, highlightId AS h FROM \(table) WHERE highlightId IN (\(marks))",
                                            arguments: StatementArguments(otherList))
                for r in rows {
                    let rid: Int64 = r["r"]
                    let old: Int64 = r["h"]
                    undo.repointed.append((table, rid, old))
                }
                try db.execute(sql: "UPDATE \(table) SET highlightId = ? WHERE highlightId IN (\(marks))",
                               arguments: StatementArguments([keeperID] + otherList))
            }
            var merged = DuplicateFinder.merged(keeper: keeper, others: others)
            merged.updatedAt = now
            try merged.update(db)
            for var o in others {
                o.deletedAt = now
                o.updatedAt = now
                try o.update(db)
            }
            return undo
        }
    }

    /// 撤销一次合并
    func undoMerge(_ u: DuplicateMergeUndo) throws {
        try writer.write { db in
            for (table, rid, old) in u.repointed {
                let rowidCol = table == "inbox_item" ? "rowid" : "id"
                try db.execute(sql: "UPDATE \(table) SET highlightId = ? WHERE \(rowidCol) = ?", arguments: [old, rid])
            }
            for var h in u.originals { try h.update(db) }
        }
    }

    // MARK: 久未回顾

    /// 各出处的回顾权重
    func sourceWeights() throws -> [Int64: Double] {
        try writer.read { db in
            var dict: [Int64: Double] = [:]
            for s in try Source.fetchAll(db) { if let id = s.id { dict[id] = s.reviewWeight } }
            return dict
        }
    }

    /// 久未回顾：从未在每日回顾中出现过，或上次出现在 days 天以前（不含已删除、已弃置）
    func staleHighlights(days: Int = 180, now: Date = Date()) throws -> [Highlight] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return try writer.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight
                WHERE deletedAt IS NULL AND isDiscarded = 0
                  AND (surfacedCount = 0 OR lastSurfacedAt IS NULL OR lastSurfacedAt < ?)
                ORDER BY createdAt
                """, arguments: [cutoff])
        }
    }

    struct StaleSummary: Equatable {
        var never = 0
        var old = 0
        var total = 0
        /// 从未回顾的条数最多的几个出处：(出处 id, 条数)
        var bySource: [(Int64?, Int)] = []
        static func == (a: StaleSummary, b: StaleSummary) -> Bool {
            a.never == b.never && a.old == b.old && a.total == b.total
                && a.bySource.map { "\($0.0 ?? -1):\($0.1)" } == b.bySource.map { "\($0.0 ?? -1):\($0.1)" }
        }
    }

    func staleSummary(days: Int = 180, now: Date = Date()) throws -> StaleSummary {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return try writer.read { db in
            var s = StaleSummary()
            let base = "FROM highlight WHERE deletedAt IS NULL AND isDiscarded = 0"
            s.total = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base)") ?? 0
            s.never = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND (surfacedCount = 0 OR lastSurfacedAt IS NULL)") ?? 0
            s.old = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND surfacedCount > 0 AND lastSurfacedAt < ?",
                                     arguments: [cutoff]) ?? 0
            s.bySource = try Row.fetchAll(db, sql: """
                SELECT sourceId, COUNT(*) AS n \(base) AND (surfacedCount = 0 OR lastSurfacedAt IS NULL)
                GROUP BY sourceId ORDER BY n DESC LIMIT 8
                """).map { ($0["sourceId"], $0["n"]) }
            return s
        }
    }
}
