import Foundation
import GRDB
import KongReviewCore

// MARK: - GRDB 记录协议

extension Source: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "source"
    public static let highlights = hasMany(Highlight.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Article: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "article"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Card: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "card"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ReviewEvent: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "review_event"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension NoteTemplate: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "note_template"
}

extension DeckOptions: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "deck_options"
}

extension Highlight: @retroactive FetchableRecord, @retroactive MutablePersistableRecord {
    public static let databaseTableName = "highlight"
    public static let source = belongsTo(Source.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 数据库

/// 单一 SQLite 文件：~/Library/Application Support/KongReview/kongreview.sqlite（未开沙盒；备份时复制整个 KongReview 文件夹即可）
final class AppDatabase {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// 恢复备份后补跑迁移（备份可能来自旧版本）
    func migrateIfNeeded() throws {
        try migrator.migrate(writer)
    }

    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("KongReview", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("kongreview.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true

        // 改名迁移：新库不存在、旧版 KongGlean 的库存在时，把旧库完整复制过来（旧文件原样保留）
        let legacy = support.appendingPathComponent("KongGlean/glean.sqlite")
        try migrateLegacyDatabase(from: legacy, to: url, configuration: config)

        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// 用 SQLite 在线备份把旧库复制成新库（包括尚未合并进主文件的 WAL 内容）
    static func migrateLegacyDatabase(from legacy: URL, to url: URL, configuration: Configuration) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) else { return }
        let source = try DatabaseQueue(path: legacy.path, configuration: configuration)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".migrating-\(UUID().uuidString).sqlite")
        let target = try DatabaseQueue(path: temp.path, configuration: configuration)
        try source.backup(to: target)
        try source.close()
        try target.close()
        try fm.moveItem(at: temp, to: url)
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

        // v0.2：软删除
        m.registerMigration("v2-soft-delete") { db in
            try db.alter(table: "highlight") { t in
                t.add(column: "deletedAt", .datetime)
            }
        }

        // v0.4：网页存档
        m.registerMigration("v3-articles") { db in
            try db.create(table: "article") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("source", onDelete: .setNull)
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("siteName", .text)
                t.column("publishedAt", .text)
                t.column("excerpt", .text)
                t.column("contentHTML", .text).notNull()
                t.column("contentText", .text).notNull()
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("savedAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
                t.column("isRead", .boolean).notNull().defaults(to: false)
            }
        }

        // v0.5：引文需要的出处字段
        m.registerMigration("v4-source-citation-fields") { db in
            try db.alter(table: "source") { t in
                t.add(column: "place", .text)
                t.add(column: "container", .text)
                t.add(column: "issue", .text)
            }
        }

        // v0.7：记忆卡（仿 Anki）、媒体、回顾日志、图片缓存
        m.registerMigration("v5-cards-log-cache") { db in
            try db.create(table: "card") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("deck", .text).notNull().defaults(to: "默认").indexed()
                t.column("front", .text).notNull()
                t.column("back", .text).notNull().defaults(to: "")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.belongsTo("highlight", onDelete: .setNull)
                t.column("state", .text).notNull().defaults(to: "new")
                t.column("step", .integer).notNull().defaults(to: 0)
                t.column("interval", .double).notNull().defaults(to: 0)
                t.column("ease", .double).notNull().defaults(to: 2.5)
                t.column("due", .datetime).notNull().indexed()
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("isSuspended", .boolean).notNull().defaults(to: false)
                t.column("ankiGuid", .text).unique()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "card_media") { t in
                t.column("name", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "review_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("highlightId", .integer)
                t.column("cardId", .integer)
                t.column("answer", .integer)
                t.column("at", .datetime).notNull().indexed()
            }
            try db.create(table: "image_cache") { t in
                t.column("url", .text).primaryKey()
                t.column("data", .blob).notNull()
                t.column("mime", .text)
                t.column("fetchedAt", .datetime).notNull()
            }

            // 旧版“记忆卡”（摘录上的半衰期标记）转成真正的卡片，放进“摘录”牌组
            let now = Date()
            let old = try Highlight.filter(sql: "masteryHalfLifeDays IS NOT NULL AND deletedAt IS NULL").fetchAll(db)
            for h in old {
                let src = try h.sourceId.flatMap { try Source.fetchOne(db, key: $0) }
                // 只写 v5 时就有的列（以后 Card 增加的字段由后续迁移补上默认值）
                let c = Card.from(h, source: src)
                try db.execute(sql: """
                    INSERT INTO card (deck, front, back, tags, highlightId, state, step, interval, ease, due, reps, lapses,
                                      isSuspended, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, 'new', 0, 0, 2.5, ?, 0, 0, 0, ?, ?)
                    """, arguments: [c.deck, c.front, c.back, Self.tagsJSON(c.tags), c.highlightId, now, now, now])
            }
            try db.execute(sql: "UPDATE highlight SET masteryHalfLifeDays = NULL, masteryLastReviewedAt = NULL")
        }

        m.registerMigration("v6-templates-fsrs-deck-options") { db in
            try db.alter(table: "card") { t in
                t.add(column: "noteType", .text)
                t.add(column: "fields", .text).notNull().defaults(to: "[]")
                t.add(column: "stability", .double)
                t.add(column: "difficulty", .double)
                t.add(column: "lastReview", .datetime)
            }
            try db.create(table: "note_template") { t in
                t.column("name", .text).primaryKey()
                t.column("fieldNames", .text).notNull()
                t.column("front", .text).notNull()
                t.column("back", .text).notNull()
                t.column("collapsed", .text).notNull()
                t.column("isCloze", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "deck_options") { t in
                t.column("deck", .text).primaryKey()
                t.column("newPerDay", .integer)
                t.column("reviewsPerDay", .integer)
                t.column("algorithm", .text).notNull().defaults(to: "sm2")
                t.column("desiredRetention", .double).notNull().defaults(to: 0.9)
            }
            try db.alter(table: "review_event") { t in
                t.add(column: "ankiRevlogId", .integer)
            }
            try db.create(index: "review_event_on_ankiRevlogId", on: "review_event", columns: ["ankiRevlogId"],
                          unique: true, condition: Column("ankiRevlogId") != nil)
            try db.create(index: "review_event_on_cardId", on: "review_event", columns: ["cardId"])
        }

        m.registerMigration("v7-covers-frequency-inbox") { db in
            try db.alter(table: "source") { t in t.add(column: "isbn", .text) }
            try db.alter(table: "highlight") { t in t.add(column: "frequency", .integer) }
            try db.create(table: "source_cover") { t in
                t.column("sourceId", .integer).primaryKey().references("source", onDelete: .cascade)
                t.column("data", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // 外部应用投递的摘录：来源应用 + 外部 id → 本地摘录，防止重复导入
            try db.create(table: "inbox_item") { t in
                t.column("key", .text).primaryKey()
                t.column("highlightId", .integer)
                t.column("importedAt", .datetime).notNull()
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

    /// 软删除：移入“最近删除”
    func moveToTrash(_ highlight: Highlight, now: Date = Date()) throws {
        var h = highlight
        h.deletedAt = now
        try save(h)
    }

    func restore(_ highlight: Highlight) throws {
        var h = highlight
        h.deletedAt = nil
        try save(h)
    }

    /// 彻底删除（仅用于“最近删除”）
    func deletePermanently(_ highlight: Highlight) throws {
        _ = try writer.write { db in try highlight.delete(db) }
    }

    /// 清空“最近删除”
    @discardableResult
    func emptyTrash() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM highlight WHERE deletedAt IS NOT NULL")
            return db.changesCount
        }
    }

    /// 清除删除时间早于 cutoff 的条目（默认保留 30 天）
    @discardableResult
    func purgeTrash(olderThan cutoff: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM highlight WHERE deletedAt IS NOT NULL AND deletedAt < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// 把整个数据库写成一个独立的 SQLite 文件（VACUUM INTO，一致性快照，不影响正在使用的库）
    func backup(to url: URL) throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
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
            // 只填书名、没填作者时（快速录入的常见情况），沿用同名的已有出处
            if author.isEmpty,
               let existing = try Source.filter(Column("title") == title).order(Column("id")).fetchOne(db) {
                return existing
            }
            var s = Source(title: title, author: author, kind: kind, url: url)
            try s.insert(db)
            return s
        }
    }

    /// 处理 kongreview://add 链接
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

// MARK: - 批量操作

extension AppDatabase {
    /// 对一批摘录做同一种修改（一个事务内完成）
    @discardableResult
    func modifyHighlights(ids: [Int64], now: Date = Date(), _ change: (inout Highlight) -> Void) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try writer.write { db in
            var n = 0
            for var h in try Highlight.fetchAll(db, keys: ids) {
                let before = h
                change(&h)
                if h != before {
                    h.updatedAt = now
                    try h.update(db)
                    n += 1
                }
            }
            return n
        }
    }

    /// 出处列表（附摘录数，不含已删除），用于出处管理
    func sourcesWithCounts() throws -> [(source: Source, count: Int)] {
        try writer.read { db in
            let counts = try Row.fetchAll(db, sql: """
                SELECT sourceId, COUNT(*) AS n FROM highlight
                WHERE sourceId IS NOT NULL AND deletedAt IS NULL GROUP BY sourceId
                """)
            var dict: [Int64: Int] = [:]
            for r in counts { dict[r["sourceId"]] = r["n"] }
            return try Source.fetchAll(db).map { ($0, $0.id.flatMap { dict[$0] } ?? 0) }
        }
    }

    /// 把若干出处合并到 target：摘录和存档文章都转过去，target 缺的书目信息用被合并者补齐，然后删除被合并的出处
    @discardableResult
    func mergeSources(_ ids: [Int64], into target: Int64) throws -> Int {
        let others = ids.filter { $0 != target }
        guard !others.isEmpty else { return 0 }
        return try writer.write { db in
            guard var t = try Source.fetchOne(db, key: target) else { return 0 }
            let merged = try Source.fetchAll(db, keys: others)
            func fill(_ kp: WritableKeyPath<Source, String?>) {
                if t[keyPath: kp]?.isEmpty ?? true, let v = merged.compactMap({ $0[keyPath: kp] }).first(where: { !$0.isEmpty }) {
                    t[keyPath: kp] = v
                }
            }
            if t.author.isEmpty, let a = merged.map(\.author).first(where: { !$0.isEmpty }) { t.author = a }
            fill(\.publisher); fill(\.year); fill(\.edition); fill(\.url); fill(\.place); fill(\.container); fill(\.issue)
            try t.update(db)

            let placeholders = Array(repeating: "?", count: others.count).joined(separator: ",")
            var args: [(any DatabaseValueConvertible)?] = [target]
            args += others.map { $0 }
            try db.execute(sql: "UPDATE highlight SET sourceId = ? WHERE sourceId IN (\(placeholders))", arguments: StatementArguments(args))
            let moved = db.changesCount
            try db.execute(sql: "UPDATE article SET sourceId = ? WHERE sourceId IN (\(placeholders))", arguments: StatementArguments(args))
            _ = try Source.deleteAll(db, keys: others)
            return moved
        }
    }

    func setKind(_ kind: SourceKind, forSources ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var args: [(any DatabaseValueConvertible)?] = [kind.rawValue]
            args += ids.map { $0 }
            try db.execute(sql: "UPDATE source SET kind = ? WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    func deleteSources(_ ids: [Int64]) throws {
        _ = try writer.write { db in try Source.deleteAll(db, keys: ids) }
    }
}

// MARK: - 网页存档

extension AppDatabase {
    /// 保存抓取到的文章：同一网址已存在则更新正文；同时建立（或沿用）对应的“网页”出处。
    @discardableResult
    func saveArticle(_ fetched: Article, now: Date = Date()) throws -> Article {
        try writer.write { db in
            // 出处：按网址找，没有就新建
            var source: Source
            if let s = try Source.filter(Column("url") == fetched.url).fetchOne(db) {
                source = s
            } else {
                source = Source(
                    title: fetched.title,
                    author: fetched.author ?? "",
                    kind: .web,
                    url: fetched.url,
                    publisher: fetched.siteName,
                    year: fetched.publishedYear,
                    createdAt: now
                )
                try source.insert(db)
            }

            var article = fetched
            article.sourceId = source.id
            if let existing = try Article.filter(Column("url") == fetched.url).fetchOne(db) {
                article.id = existing.id
                article.savedAt = existing.savedAt
                article.lastOpenedAt = existing.lastOpenedAt
                article.isRead = existing.isRead
                try article.update(db)
            } else {
                try article.insert(db)
            }
            return article
        }
    }

    /// 文章列表（只取元数据，不取正文，列表再长也很快；阅读时用 article(id:) 取全文）
    func articles(query: String = "") throws -> [Article] {
        try writer.read { db in
            var sql = """
                SELECT id, sourceId, url, title, author, siteName, publishedAt, excerpt,
                       '' AS contentHTML, '' AS contentText, wordCount, savedAt, lastOpenedAt, isRead
                FROM article
                """
            var args: [(any DatabaseValueConvertible)?] = []
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                let p = SearchQuery.likePattern(q)
                sql += " WHERE title LIKE ? ESCAPE '\\' OR siteName LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\'"
                args += [p, p, p]
            }
            sql += " ORDER BY savedAt DESC"
            return try Article.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func articleCount() throws -> Int {
        try writer.read { db in try Article.fetchCount(db) }
    }

    func article(id: Int64) throws -> Article? {
        try writer.read { db in try Article.fetchOne(db, key: id) }
    }

    func article(url: String) throws -> Article? {
        try writer.read { db in try Article.filter(Column("url") == url).fetchOne(db) }
    }

    func markArticleOpened(id: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE article SET lastOpenedAt = ?, isRead = 1 WHERE id = ?", arguments: [now, id])
        }
    }

    /// 只删存档的正文；出处和已划的摘录都保留
    func deleteArticle(id: Int64) throws {
        _ = try writer.write { db in try Article.deleteOne(db, key: id) }
    }

    /// 文章对应出处下的摘录数（不含已删除）
    func articleHighlightCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT article.id AS aid, COUNT(highlight.id) AS n
                FROM article JOIN highlight ON highlight.sourceId = article.sourceId
                WHERE highlight.deletedAt IS NULL
                GROUP BY article.id
                """)
            var dict: [Int64: Int] = [:]
            for r in rows { dict[r["aid"]] = r["n"] }
            return dict
        }
    }
}

// MARK: - 导入

struct ImportReport: Equatable {
    var sourcesCreated = 0
    var sourcesReused = 0
    var highlightsImported = 0
    var duplicatesSkipped = 0
}

extension AppDatabase {
    /// 导入 Readwise CSV 的解析结果。整个导入在一个事务里完成：要么全部成功，要么什么都不改。
    /// - 同一出处（书名 + 作者完全相同）沿用已有记录；
    /// - 同一出处下正文完全相同的摘录视为重复，跳过（可重复导入同一个文件而不产生重复）；
    /// - extraTag 会加到每条导入的摘录上，方便日后筛选或批量处理。
    @discardableResult
    func importReadwise(_ result: ReadwiseCSVImporter.Result, extraTag: String? = nil, now: Date = Date()) throws -> ImportReport {
        try writer.write { db in
            var report = ImportReport()
            for src in result.sources {
                var source: Source
                if let existing = try Source
                    .filter(Column("title") == src.title && Column("author") == src.author)
                    .fetchOne(db) {
                    source = existing
                    report.sourcesReused += 1
                } else {
                    source = Source(title: src.title, author: src.author, kind: src.kind, url: src.url, createdAt: now)
                    try source.insert(db)
                    report.sourcesCreated += 1
                }

                for item in src.highlights {
                    let exists = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS (SELECT 1 FROM highlight WHERE sourceId = ? AND text = ?)
                        """, arguments: [source.id, item.text]) ?? false
                    if exists {
                        report.duplicatesSkipped += 1
                        continue
                    }
                    var tags = item.tags
                    if let extraTag, !extraTag.isEmpty, !tags.contains(extraTag) { tags.append(extraTag) }
                    let when = item.highlightedAt ?? now
                    var h = Highlight(
                        sourceId: source.id,
                        text: item.text,
                        note: item.note,
                        location: item.location,
                        tags: tags,
                        isFavorite: item.isFavorite,
                        isDiscarded: item.isDiscarded,
                        createdAt: when,
                        updatedAt: now
                    )
                    try h.insert(db)
                    report.highlightsImported += 1
                }
            }
            return report
        }
    }
}

// MARK: - 查询条件

/// 摘录列表的筛选条件（列表、计数、导出共用）
struct HighlightQuery: Hashable {
    var text: String = ""
    var sourceId: Int64?
    var tag: String?
    var includeDiscarded = false
    var favoritesOnly = false
    var masteryOnly = false
    var unsortedOnly = false
    var deletedOnly = false
    /// 组合筛选：须同时带有这些标签
    var tags: [String] = []
    /// 添加日期范围（含首尾两天）
    var dateFrom: Date?
    var dateTo: Date?

    func sqlParts() -> (from: String, where: String, args: [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        var from = "highlight"

        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for t in tags where !t.isEmpty {
            clauses.append("EXISTS (SELECT 1 FROM json_each(highlight.tags) WHERE json_each.value = ?)")
            args.append(t)
        }
        if let dateFrom {
            clauses.append("highlight.createdAt >= ?")
            args.append(Calendar.current.startOfDay(for: dateFrom))
        }
        if let dateTo {
            clauses.append("highlight.createdAt < ?")
            args.append(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: dateTo)))
        }
        if deletedOnly {
            clauses.append("highlight.deletedAt IS NOT NULL")
        } else {
            clauses.append("highlight.deletedAt IS NULL")
            if !includeDiscarded { clauses.append("highlight.isDiscarded = 0") }
        }
        if favoritesOnly { clauses.append("highlight.isFavorite = 1") }
        if masteryOnly { clauses.append("highlight.masteryHalfLifeDays IS NOT NULL") }
        if unsortedOnly { clauses.append("highlight.sourceId IS NULL") }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return (from, whereSQL, args)
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
                WHERE sourceId IS NOT NULL AND isDiscarded = 0 AND deletedAt IS NULL
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
        unsortedOnly: Bool = false,
        deletedOnly: Bool = false
    ) throws -> [Highlight] {
        try highlights(HighlightQuery(
            text: query, sourceId: sourceId, tag: tag, includeDiscarded: includeDiscarded,
            favoritesOnly: favoritesOnly, masteryOnly: masteryOnly, unsortedOnly: unsortedOnly, deletedOnly: deletedOnly
        ))
    }

    /// 分页查询（limit 为 nil 时返回全部）
    func highlights(_ q: HighlightQuery, limit: Int? = nil, offset: Int = 0) throws -> [Highlight] {
        try writer.read { db in
            let (from, whereSQL, args) = q.sqlParts()
            var sql = "SELECT highlight.* FROM \(from)\(whereSQL)"
            sql += q.deletedOnly ? " ORDER BY highlight.deletedAt DESC" : " ORDER BY highlight.createdAt DESC"
            sql += ", highlight.id DESC"
            var all = args
            if let limit {
                sql += " LIMIT ? OFFSET ?"
                all += [limit, offset]
            }
            return try Highlight.fetchAll(db, sql: sql, arguments: StatementArguments(all))
        }
    }

    func count(_ q: HighlightQuery) throws -> Int {
        try writer.read { db in
            let (from, whereSQL, args) = q.sqlParts()
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(from)\(whereSQL)", arguments: StatementArguments(args)) ?? 0
        }
    }

    func allTags() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT json_each.value FROM highlight, json_each(highlight.tags)
                WHERE highlight.isDiscarded = 0 AND highlight.deletedAt IS NULL
                ORDER BY json_each.value
                """)
        }
    }

    func trashCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM highlight WHERE deletedAt IS NOT NULL") ?? 0
        }
    }

    /// 按给定 id 顺序取出摘录（用于恢复当日回顾；已删除的不返回）
    func highlights(ids: [Int64]) throws -> [Highlight] {
        let found = try writer.read { db in try Highlight.fetchAll(db, keys: ids) }
            .filter { !$0.isDeleted }
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

extension AppDatabase {
    /// 与 GRDB 对 Codable 数组的编码一致：JSON 文本
    static func tagsJSON(_ tags: [String]) -> String {
        (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
    }
}
