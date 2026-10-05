import Foundation
import GRDB
import KongGleanCore

// MARK: - GRDB 记录协议

extension Source: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "source"
    public static let highlights = hasMany(Highlight.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Highlight: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "highlight"
    public static let source = belongsTo(Source.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 数据库

/// 单一 SQLite 文件：~/Library/Application Support/KongGlean/glean.sqlite（未开沙盒；备份时复制整个 KongGlean 文件夹即可）
final class AppDatabase {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("KongGlean", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("glean.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// 内存数据库，供 SwiftUI 预览使用
    static func makeEmpty() -> AppDatabase {
        try! AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        // 注意：不要开启 eraseDatabaseOnSchemaChange，否则调试版改表结构会清空真实数据。
        // 改表一律新增 registerMigration("v2") 之类的迁移。
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull().defaults(to: "book")
                t.column("url", .text)
                t.column("publisher", .text)
                t.column("edition", .text)
                t.column("year", .text)
                t.column("reviewWeight", .double).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "highlight") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("source", onDelete: .setNull)   // 生成 sourceId 列
                t.column("text", .text).notNull()
                t.column("translation", .text)
                t.column("note", .text)
                t.column("location", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")   // JSON 数组
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isDiscarded", .boolean).notNull().defaults(to: false)
                t.column("lastSurfacedAt", .datetime)
                t.column("surfacedCount", .integer).notNull().defaults(to: 0)
                t.column("masteryHalfLifeDays", .double)
                t.column("masteryLastReviewedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // 全文检索：trigram 分词器，可直接匹配中文任意子串（≥3 字）。
            // synchronize 会建立触发器，增删改 highlight 时自动同步索引。
            try db.create(virtualTable: "highlight_ft", using: FTS5()) { t in
                t.synchronize(withTable: "highlight")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("text")
                t.column("translation")
                t.column("note")
            }
        }
        return m
    }
}

// MARK: - 写操作

extension AppDatabase {
    @discardableResult
    func save(_ source: Source) throws -> Source {
        try writer.write { db in
            var s = source
            try s.save(db)
            return s
        }
    }

    @discardableResult
    func save(_ highlight: Highlight) throws -> Highlight {
        try writer.write { db in
            var h = highlight
            h.updatedAt = Date()
            try h.save(db)
            return h
        }
    }

    func save(_ highlights: [Highlight]) throws {
        try writer.write { db in
            for var h in highlights { try h.save(db) }
        }
    }

    func delete(_ highlight: Highlight) throws {
        _ = try writer.write { db in try highlight.delete(db) }
    }

    func delete(_ source: Source) throws {
        _ = try writer.write { db in try source.delete(db) }
    }

    /// 按标题（与作者）找到已有出处，没有就新建。网页按 URL 匹配。
    func findOrCreateSource(title: String, author: String = "", kind: SourceKind, url: String? = nil) throws -> Source {
        try writer.write { db in
            if let url, !url.isEmpty,
               let existing = try Source.filter(Column("url") == url).fetchOne(db) {
                return existing
            }
            if let existing = try Source
                .filter(Column("title") == title && Column("author") == author)
                .fetchOne(db) {
                return existing
            }
            var s = Source(title: title, author: author, kind: kind, url: url)
            try s.insert(db)
            return s
        }
    }

    /// 处理 kongglean://add 链接
    @discardableResult
    func ingest(_ capture: CaptureRequest) throws -> Highlight {
        var sourceId: Int64?
        if let title = capture.title ?? capture.url {
            let kind: SourceKind = capture.url == nil ? .book : .web
            sourceId = try findOrCreateSource(title: title, author: capture.author ?? "", kind: kind, url: capture.url).id
        }
        let h = Highlight(
            sourceId: sourceId,
            text: capture.text,
            note: capture.note,
            location: capture.location,
            tags: capture.tags
        )
        return try save(h)
    }
}

// MARK: - 读操作

extension AppDatabase {
    func allSources() throws -> [Source] {
        try writer.read { db in
            try Source.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func highlightCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sourceId, COUNT(*) AS n FROM highlight
                WHERE sourceId IS NOT NULL AND isDiscarded = 0
                GROUP BY sourceId
                """)
            var dict: [Int64: Int] = [:]
            for r in rows { dict[r["sourceId"]] = r["n"] }
            return dict
        }
    }

    /// 列表与搜索。query 为空时返回全部；≥3 字走 FTS5，否则走 LIKE。
    func highlights(
        query: String = "",
        sourceId: Int64? = nil,
        tag: String? = nil,
        includeDiscarded: Bool = false,
        favoritesOnly: Bool = false,
        masteryOnly: Bool = false,
        unsortedOnly: Bool = false
    ) throws -> [Highlight] {
        try writer.read { db in
            var clauses: [String] = []
            var args: [(any DatabaseValueConvertible)?] = []
            var from = "highlight"

            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                if SearchQuery.usesFullText(q) {
                    from = "highlight JOIN highlight_ft ON highlight_ft.rowid = highlight.id"
                    clauses.append("highlight_ft MATCH ?")
                    args.append(SearchQuery.fts5Phrase(q))
                } else {
                    clauses.append("(highlight.text LIKE ? ESCAPE '\\' OR highlight.note LIKE ? ESCAPE '\\' OR highlight.translation LIKE ? ESCAPE '\\')")
                    let p = SearchQuery.likePattern(q)
                    args += [p, p, p]
                }
            }
            if let sourceId {
                clauses.append("highlight.sourceId = ?")
                args.append(sourceId)
            }
            if let tag, !tag.isEmpty {
                // tags 以 JSON 数组存储，用 json_each 精确匹配
                clauses.append("EXISTS (SELECT 1 FROM json_each(highlight.tags) WHERE json_each.value = ?)")
                args.append(tag)
            }
            if !includeDiscarded { clauses.append("highlight.isDiscarded = 0") }
            if favoritesOnly { clauses.append("highlight.isFavorite = 1") }
            if masteryOnly { clauses.append("highlight.masteryHalfLifeDays IS NOT NULL") }
            if unsortedOnly { clauses.append("highlight.sourceId IS NULL") }

            var sql = "SELECT highlight.* FROM \(from)"
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY highlight.createdAt DESC"
            return try Highlight.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func allTags() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT json_each.value FROM highlight, json_each(highlight.tags)
                WHERE highlight.isDiscarded = 0
                ORDER BY json_each.value
                """)
        }
    }

    /// 按给定 id 顺序取出摘录（用于恢复当日回顾）
    func highlights(ids: [Int64]) throws -> [Highlight] {
        let found = try writer.read { db in try Highlight.fetchAll(db, keys: ids) }
        let byId = Dictionary(uniqueKeysWithValues: found.compactMap { h in h.id.map { ($0, h) } })
        return ids.compactMap { byId[$0] }
    }

    func source(id: Int64?) throws -> Source? {
        guard let id else { return nil }
        return try writer.read { db in try Source.fetchOne(db, key: id) }
    }

    /// 回顾候选：未弃置的全部摘录（可按标签限定为“主题回顾”）
    func reviewCandidates(tag: String? = nil) throws -> (highlights: [Highlight], sourceWeights: [Int64: Double]) {
        let hs = try highlights(tag: tag)
        let weights = try writer.read { db -> [Int64: Double] in
            var dict: [Int64: Double] = [:]
            for s in try Source.fetchAll(db) { if let id = s.id { dict[id] = s.reviewWeight } }
            return dict
        }
        return (hs, weights)
    }
}
