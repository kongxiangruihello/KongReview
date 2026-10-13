import Foundation
import GRDB
import KongReviewCore

// MARK: - 专题笔记本（1.3）

extension Notebook: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "notebook"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension NotebookBlock: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "notebook_block"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension AppDatabase {
    /// 全部笔记本（最近改动的在前）及各自摘录条数
    func notebooks() throws -> [Notebook] {
        try writer.read { db in try Notebook.order(Column("updatedAt").desc).fetchAll(db) }
    }

    func notebookQuoteCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT notebookId, COUNT(*) AS n FROM notebook_block WHERE kind = 'highlight' GROUP BY notebookId")
            return Dictionary(uniqueKeysWithValues: rows.compactMap { r in (r["notebookId"] as Int64?).map { ($0, (r["n"] as Int?) ?? 0) } })
        }
    }

    @discardableResult
    func createNotebook(title: String, now: Date = Date()) throws -> Notebook {
        try writer.write { db in
            var n = Notebook(title: title, createdAt: now, updatedAt: now)
            try n.insert(db)
            return n
        }
    }

    func renameNotebook(_ id: Int64, title: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE notebook SET title = ?, updatedAt = ? WHERE id = ?", arguments: [title, now, id])
        }
    }

    func deleteNotebook(_ id: Int64) throws {
        _ = try writer.write { db in try Notebook.deleteOne(db, key: id) }
    }

    func notebookBlocks(_ notebookId: Int64) throws -> [NotebookBlock] {
        try writer.read { db in
            try NotebookBlock.filter(Column("notebookId") == notebookId).order(Column("position"), Column("id")).fetchAll(db)
        }
    }

    /// 插入若干块到 after 这一块之后（nil 表示末尾；atStart 为 true 时插到开头）。返回插入后的块（含 id）
    @discardableResult
    func insertBlocks(_ blocks: [NotebookBlock], into notebookId: Int64, after: Int64?, atStart: Bool = false,
                      now: Date = Date()) throws -> [NotebookBlock] {
        try writer.write { db in
            let existing = try NotebookBlock.filter(Column("notebookId") == notebookId)
                .order(Column("position"), Column("id")).fetchAll(db)
            var before: Double?
            var nextPos: Double?
            if atStart {
                before = nil
                nextPos = existing.first?.position
            } else if let after, let i = existing.firstIndex(where: { $0.id == after }) {
                before = existing[i].position
                nextPos = i + 1 < existing.count ? existing[i + 1].position : nil
            } else {
                before = existing.last?.position
                nextPos = nil
            }
            // 间隔太小时先把整本重新编号
            if let b = before, let a = nextPos, a - b < 1e-6 * Double(blocks.count + 1) {
                for (k, var blk) in existing.enumerated() {
                    blk.position = Double(k + 1)
                    try blk.update(db)
                }
                return try insertBlocksRenumbered(db, blocks, notebookId: notebookId, after: after, atStart: atStart, now: now)
            }
            var out: [NotebookBlock] = []
            let n = Double(blocks.count)
            for (k, var b) in blocks.enumerated() {
                let k = Double(k)
                let pos: Double
                switch (before, nextPos) {
                case let (lo?, hi?): pos = lo + (hi - lo) * (k + 1) / (n + 1)
                case let (lo?, nil): pos = lo + k + 1
                case let (nil, hi?): pos = hi - (n - k)
                case (nil, nil): pos = k + 1
                }
                b.notebookId = notebookId
                b.position = pos
                b.createdAt = now
                b.updatedAt = now
                try b.insert(db)
                out.append(b)
            }
            try db.execute(sql: "UPDATE notebook SET updatedAt = ? WHERE id = ?", arguments: [now, notebookId])
            return out
        }
    }

    private func insertBlocksRenumbered(_ db: Database, _ blocks: [NotebookBlock], notebookId: Int64, after: Int64?,
                                        atStart: Bool, now: Date) throws -> [NotebookBlock] {
        let existing = try NotebookBlock.filter(Column("notebookId") == notebookId).order(Column("position")).fetchAll(db)
        let index: Int = atStart ? 0 : ((after.flatMap { a in existing.firstIndex(where: { $0.id == a }) }).map { $0 + 1 } ?? existing.count)
        var out: [NotebookBlock] = []
        // 前面的不动，后面的整体后移
        let shift = Double(blocks.count)
        for k in index..<existing.count {
            var e = existing[k]
            e.position = Double(k + 1) + shift
            try e.update(db)
        }
        for (j, var b) in blocks.enumerated() {
            b.notebookId = notebookId
            b.position = Double(index + j + 1)
            b.createdAt = now
            b.updatedAt = now
            try b.insert(db)
            out.append(b)
        }
        try db.execute(sql: "UPDATE notebook SET updatedAt = ? WHERE id = ?", arguments: [now, notebookId])
        return out
    }

    func updateBlockText(_ id: Int64, text: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE notebook_block SET text = ?, updatedAt = ? WHERE id = ?", arguments: [text, now, id])
            try db.execute(sql: "UPDATE notebook SET updatedAt = ? WHERE id = (SELECT notebookId FROM notebook_block WHERE id = ?)",
                           arguments: [now, id])
        }
    }

    func setBlockPosition(_ id: Int64, position: Double) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE notebook_block SET position = ? WHERE id = ?", arguments: [position, id])
        }
    }

    func deleteBlocks(_ ids: [Int64]) throws {
        _ = try writer.write { db in try NotebookBlock.deleteAll(db, keys: ids) }
    }

    /// 重新按给定顺序编号（拖动排序后调用）
    func reorderBlocks(_ orderedIDs: [Int64]) throws {
        try writer.write { db in
            for (k, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE notebook_block SET position = ? WHERE id = ?", arguments: [Double(k + 1), id])
            }
        }
    }

    /// 某条摘录已在哪些笔记本里
    func notebookIDs(containing highlightId: Int64) throws -> Set<Int64> {
        try writer.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT notebookId FROM notebook_block WHERE highlightId = ?", arguments: [highlightId]))
        }
    }
}

// MARK: - 每周小结（1.3）

extension AppDatabase {
    func weeklyDigest(now: Date = Date()) throws -> WeeklyDigest {
        let (start, end) = WeeklyDigest.previousWeek(of: now)
        var d = WeeklyDigest(start: start, end: end)
        try writer.read { db in
            let r = try Row.fetchOne(db, sql: """
                SELECT SUM(CASE WHEN kind NOT IN ('card', 'note') THEN 1 ELSE 0 END) AS h,
                       SUM(CASE WHEN kind = 'card' THEN 1 ELSE 0 END) AS c,
                       SUM(CASE WHEN kind = 'card' AND answer > 1 THEN 1 ELSE 0 END) AS ok,
                       COUNT(DISTINCT date(at, 'localtime')) AS days
                FROM review_event WHERE at >= ? AND at < ?
                """, arguments: [start, end])
            d.highlightsReviewed = (r?["h"] as Int?) ?? 0
            d.cardsReviewed = (r?["c"] as Int?) ?? 0
            d.cardsCorrect = (r?["ok"] as Int?) ?? 0
            d.activeDays = (r?["days"] as Int?) ?? 0
            d.newHighlights = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight WHERE deletedAt IS NULL AND createdAt >= ? AND createdAt < ?
                """, arguments: [start, end]) ?? 0
            d.newCards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM card WHERE deletedAt IS NULL AND createdAt >= ? AND createdAt < ?
                """, arguments: [start, end]) ?? 0
            // 本周金句：上周收藏的；没有就上周回顾过的；再没有就全部收藏里挑
            let favs = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT e.highlightId FROM review_event e JOIN highlight h ON h.id = e.highlightId
                WHERE e.kind = 'favorite' AND e.at >= ? AND e.at < ? AND h.deletedAt IS NULL AND h.isDiscarded = 0
                """, arguments: [start, end])
            var pool = favs
            if pool.isEmpty {
                pool = try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT e.highlightId FROM review_event e JOIN highlight h ON h.id = e.highlightId
                    WHERE e.kind NOT IN ('card', 'note', 'discard') AND e.at >= ? AND e.at < ?
                      AND h.deletedAt IS NULL AND h.isDiscarded = 0
                    """, arguments: [start, end])
            }
            if pool.isEmpty {
                pool = try Int64.fetchAll(db, sql: "SELECT id FROM highlight WHERE isFavorite = 1 AND deletedAt IS NULL AND isDiscarded = 0")
            }
            d.quoteID = WeeklyDigest.pick(pool, weekKey: d.key)
        }
        return d
    }
}
