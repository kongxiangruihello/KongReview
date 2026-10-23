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

    init(_ writer: any DatabaseWriter, upTo migration: String? = nil) throws {
        self.writer = writer
        // 1.2：繁简归一函数。索引触发器在写连接上调用它，所以必须在迁移之前注册。
        try writer.writeWithoutTransaction { db in AppDatabase.registerFunctions(db) }
        if let migration { try migrator.migrate(writer, upTo: migration) }
        else {
            try migrator.migrate(writer)
            // 4.1.1：旧版本或旧备份里遗留的专题问题，打开时补转入问题簿
            _ = try convertLegacyTopicQuestions()
        }
    }

    /// kr_fold(文本)：繁体转简体、全角转半角、英文转小写（见 ChineseFold），供繁简通搜的索引使用
    /// 应用自定义的 SQL 函数（每个连接都要注册）
    static func registerFunctions(_ db: Database) {
        db.add(function: foldFunction)
        db.add(function: pageFunction)
        db.add(function: globalSearchPlainFunction)
    }

    /// kr_page(位置)：位置文字里的第一个数字（页码），没有数字时为 NULL（1.6，书页排序与“页:”搜索用）
    static let pageFunction = DatabaseFunction("kr_page", argumentCount: 1, pure: true) { values in
        SearchSyntax.firstNumber(String.fromDatabaseValue(values[0]))
    }

    static let foldFunction = DatabaseFunction("kr_fold", argumentCount: 1, pure: true) { values in
        guard let s = String.fromDatabaseValue(values[0]) else { return nil }
        return ChineseFold.fold(s)
    }

    /// 恢复备份后补跑迁移（备份可能来自旧版本）
    /// 4.1.2：已登记的迁移（按登记先后），完整备份恢复时据此判断备份来自哪一版
    var migrationIdentifiers: [String] { migrator.migrations }

    func migrateIfNeeded() throws {
        try migrator.migrate(writer)
        _ = try convertLegacyTopicQuestions()
    }

    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("KongReview", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("kongreview.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in AppDatabase.registerFunctions(db) }

        // 改名迁移：新库不存在、旧版 KongGlean 的库存在时，把旧库完整复制过来（旧文件原样保留）
        let legacy = support.appendingPathComponent("KongGlean/glean.sqlite")
        try migrateLegacyDatabase(from: legacy, to: url, configuration: config)

        let pool = try DatabasePool(path: url.path, configuration: config)
        try backupBeforeQuestionBook(pool, directory: dir)
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

    /// 4.1.1：专题问题迁入问题簿不可逆——升级前把整个库复制一份到“升级前备份”文件夹（只在尚未迁移、且有专题问题时做一次）
    static func backupBeforeQuestionBook(_ pool: DatabasePool, directory: URL) throws {
        let needed = try pool.read { db -> Bool in
            guard try db.tableExists("grdb_migrations"), try db.tableExists("app_progress") else { return false }
            let done = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v18-question-book'") ?? 0
            let legacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_progress WHERE key LIKE 'topic-question.%' OR key LIKE 'question-draft.%'") ?? 0
            return done == 0 && legacy > 0
        }
        guard needed else { return }
        let folder = directory.appendingPathComponent("升级前备份", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let target = try DatabaseQueue(path: folder.appendingPathComponent("kongreview-4.1.1升级前-\(f.string(from: Date())).sqlite").path)
        try pool.backup(to: target)
        try target.close()
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

        // 1.2：繁简通搜索引、记忆卡背面栏目、LiquidText 文件夹导入记录
        m.registerMigration("v8-fold-search-card-sections") { db in
            // 归一后的全文（原文 + 译文 + 按语），trigram 分词；与 highlight 一一对应（rowid = highlight.id）
            try db.execute(sql: """
                CREATE VIRTUAL TABLE highlight_fold_ft USING fts5(body, tokenize = 'trigram');
                INSERT INTO highlight_fold_ft(rowid, body)
                    SELECT id, kr_fold(coalesce(text, '') || char(10) || coalesce(translation, '') || char(10) || coalesce(note, ''))
                    FROM highlight;
                CREATE TRIGGER highlight_fold_ai AFTER INSERT ON highlight BEGIN
                    INSERT INTO highlight_fold_ft(rowid, body)
                    VALUES (new.id, kr_fold(coalesce(new.text, '') || char(10) || coalesce(new.translation, '') || char(10) || coalesce(new.note, '')));
                END;
                CREATE TRIGGER highlight_fold_ad AFTER DELETE ON highlight BEGIN
                    DELETE FROM highlight_fold_ft WHERE rowid = old.id;
                END;
                CREATE TRIGGER highlight_fold_au AFTER UPDATE OF text, translation, note ON highlight BEGIN
                    DELETE FROM highlight_fold_ft WHERE rowid = old.id;
                    INSERT INTO highlight_fold_ft(rowid, body)
                    VALUES (new.id, kr_fold(coalesce(new.text, '') || char(10) || coalesce(new.translation, '') || char(10) || coalesce(new.note, '')));
                END;
                """)
            // 背面栏目：JSON 数组 [{id, name, text, folded}]
            try db.alter(table: "card") { t in t.add(column: "sections", .text) }
        }

        // 1.3：专题笔记本
        m.registerMigration("v9-notebooks") { db in
            try db.create(table: "notebook") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "notebook_block") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("notebookId", .integer).notNull().references("notebook", onDelete: .cascade)
                t.column("position", .double).notNull()
                t.column("kind", .text).notNull()
                t.column("highlightId", .integer).references("highlight", onDelete: .setNull)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "notebook_block_order", on: "notebook_block", columns: ["notebookId", "position"])
            try db.create(index: "notebook_block_highlight", on: "notebook_block", columns: ["highlightId"])
        }

        // 1.5：笔记本里摘录块的“本文批注”
        m.registerMigration("v10-notebook-block-note") { db in
            try db.alter(table: "notebook_block") { t in t.add(column: "note", .text) }
        }

        // 1.7：古籍原典书名（按“《书名·篇名》”体例引用）
        m.registerMigration("v11-source-classic") { db in
            try db.alter(table: "source") { t in t.add(column: "classicTitle", .text) }
        }

        // 2.1：摘录在同一古籍其他版本（整理本）里的页码
        m.registerMigration("v12-edition-page") { db in
            try db.create(table: "highlight_edition_page") { t in
                t.column("highlightId", .integer).notNull().references("highlight", onDelete: .cascade)
                t.column("sourceId", .integer).notNull().references("source", onDelete: .cascade)
                t.column("page", .text).notNull()
                t.primaryKey(["highlightId", "sourceId"])
            }
            try db.create(index: "edition_page_source", on: "highlight_edition_page", columns: ["sourceId"])
        }

        // 2.2：记忆卡回答记录写上回答前的卡片状态（导入的旧卡第一次复习不再被算成新卡）
        m.registerMigration("v13-event-card-state") { db in
            try db.alter(table: "review_event") { t in t.add(column: "cardState", .text) }
        }
        m.registerMigration("v14-growth-progress") { db in
            try db.create(table: "app_progress") { t in
                t.column("key", .text).primaryKey()
                t.column("payload", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        m.registerMigration("v15-card-entry-workflows") { db in
            try db.create(table:"card_entry_record") { t in
                t.column("cardId",.integer).primaryKey().references("card",onDelete:.cascade)
                t.column("recordedAt",.datetime).notNull()
            }
            try db.create(index:"card_entry_record_date",on:"card_entry_record",columns:["recordedAt","cardId"])
            try AppDatabase.installCardEntryOrganizationUndoTracking(in:db)
        }
        // 4.0：研究项目、关联、阶段记录与写作量；本期焦点转为当前项目
        m.registerMigration("v16-research-projects") { db in
            try AppDatabase.installResearchProjects(in: db)
        }
        // 4.1：札记、札记引用的摘录与札记之间的链接
        m.registerMigration("v17-idea-notes") { db in
            try AppDatabase.installIdeaNotes(in: db)
        }
        // 4.1.1：问题簿；3.4 的专题问题与草稿转入
        m.registerMigration("v18-question-book") { db in
            try AppDatabase.installQuestionBook(in: db)
        }
        // 4.1.2：专题笔记本中的札记块
        m.registerMigration("v19-notebook-note-blocks") { db in
            try AppDatabase.installNotebookNoteBlocks(in: db)
        }
        // 5.0.0：重温——札记排程与修订历史、常念问题轮流、重温记录
        m.registerMigration("v20-revisit") { db in
            try AppDatabase.installRevisit(in: db)
        }
        // 5.0.2：自测记录、进展记录（小胜）
        m.registerMigration("v21-progress") { db in
            try AppDatabase.installProgress(in: db)
        }
        // 5.1：精简提要（读完的书）
        m.registerMigration("v22-book-summary") { db in
            try AppDatabase.installBookSummary(in: db)
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
    /// - 同一出处下正文与位置都相同的摘录视为重复，跳过（可重复导入同一个文件而不产生重复）；
    /// - extraTag 会加到每条导入的摘录上，方便日后筛选或批量处理。
    @discardableResult
    /// keyPrefix（1.2，LiquidText 用）：给每条导入的摘录记一个“来源键”（出处 + 位置 + 导入时的原文），
    /// 以后同一条再出现就跳过——即使已在 KongReview 里改过文字或删掉了，重新导出的笔记也不会把它加回来。
    func importReadwise(_ result: ReadwiseCSVImporter.Result, extraTag: String? = nil, now: Date = Date(),
                        keyPrefix: String? = nil) throws -> ImportReport {
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
                    let key = keyPrefix.map { Self.importKey(prefix: $0, title: src.title, author: src.author,
                                                             location: item.location, text: item.text) }
                    if let key, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_item WHERE key = ?)",
                                                  arguments: [key]) ?? false {
                        report.duplicatesSkipped += 1
                        continue
                    }
                    let existingID = try Int64.fetchOne(db, sql: """
                        SELECT id FROM highlight WHERE sourceId = ? AND text = ? AND COALESCE(location, '') = ? LIMIT 1
                        """, arguments: [source.id, item.text, item.location ?? ""])
                    if let existingID {
                        if let key {
                            try db.execute(sql: "INSERT OR IGNORE INTO inbox_item (key, highlightId, importedAt) VALUES (?, ?, ?)",
                                           arguments: [key, existingID, now])
                        }
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
                    if let key {
                        try db.execute(sql: "INSERT OR IGNORE INTO inbox_item (key, highlightId, importedAt) VALUES (?, ?, ?)",
                                       arguments: [key, h.id, now])
                    }
                    report.highlightsImported += 1
                }
            }
            return report
        }
    }
}

extension AppDatabase {
    /// 导入去重键：前缀 + SHA-1(标题、作者、位置、原文)
    static func importKey(prefix: String, title: String, author: String?, location: String?, text: String) -> String {
        let raw = [title, author ?? "", location ?? "", text].joined(separator: "\u{1}")
        return prefix + "|" + SHA1.hex(Data(raw.utf8))
    }
}

// MARK: - 查询条件

/// 摘录列表的筛选条件（列表、计数、导出共用）
struct HighlightQuery: Hashable, Sendable {
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
    /// 1.6：按页码排序（书页视图）；没有页码的排在最后，同页按录入先后
    var orderByPage = false

    var orderSQL: String {
        if deletedOnly { return " ORDER BY highlight.deletedAt DESC" }
        if orderByPage {
            return " ORDER BY kr_page(highlight.location) IS NULL, kr_page(highlight.location), highlight.createdAt, highlight.id"
        }
        return " ORDER BY highlight.createdAt DESC"
    }

    func sqlParts() -> (from: String, where: String, args: [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        let from = "highlight"

        // 1.6：搜索语法（见 KongReviewCore/SearchSyntax.swift）：多个词同时出现、整句、-排除、出处:、作者:、标签:、页:、有按语…
        let parsed = SearchSyntax.parse(text)
        /// 某个词在繁简归一后的索引里出现（1.2 起“红卫兵”与“紅衛兵”互相能搜到）
        func termClause(_ term: String, negate: Bool) {
            let fq = ChineseFold.fold(term)
            guard !fq.isEmpty else { return }
            let inner = SearchQuery.usesFullText(fq)
                ? "SELECT rowid FROM highlight_fold_ft WHERE highlight_fold_ft MATCH ?"
                : "SELECT rowid FROM highlight_fold_ft WHERE body LIKE ? ESCAPE '\\'"
            // HTML rows search visible text, including phrases crossing inline tags.
            // Existing plain/Markdown rows retain their indexed path.
            let body = "coalesce(highlight.text,'')||char(10)||coalesce(highlight.translation,'')||char(10)||coalesce(highlight.note,'')"
            let match = "CASE WHEN instr(\(body),'<')>0 OR instr(\(body),'&')>0 THEN kr_fold(kr_search_plain(\(body))) LIKE ? ESCAPE '\\' ELSE highlight.id IN (\(inner)) END"
            clauses.append(negate ? "NOT (\(match))" : "(\(match))")
            args.append(SearchQuery.likePattern(fq))
            args.append(SearchQuery.usesFullText(fq) ? SearchQuery.fts5Phrase(fq) : SearchQuery.likePattern(fq))
        }
        for t in parsed.terms { termClause(t, negate: false) }
        for t in parsed.excluded { termClause(t, negate: true) }
        for s in parsed.sources {
            clauses.append("highlight.sourceId IN (SELECT id FROM source WHERE kr_fold(title) LIKE ? ESCAPE '\\')")
            args.append(SearchQuery.likePattern(ChineseFold.fold(s)))
        }
        for a in parsed.authors {
            clauses.append("highlight.sourceId IN (SELECT id FROM source WHERE kr_fold(author) LIKE ? ESCAPE '\\')")
            args.append(SearchQuery.likePattern(ChineseFold.fold(a)))
        }
        if let lo = parsed.pageFrom {
            clauses.append("kr_page(highlight.location) >= ?")
            args.append(lo)
        }
        if let hi = parsed.pageTo {
            clauses.append("kr_page(highlight.location) <= ?")
            args.append(hi)
        }
        if parsed.hasNote { clauses.append("trim(coalesce(highlight.note, '')) <> ''") }
        if parsed.hasTranslation { clauses.append("trim(coalesce(highlight.translation, '')) <> ''") }
        if parsed.favorite { clauses.append("highlight.isFavorite = 1") }
        if parsed.card { clauses.append("highlight.id IN (SELECT highlightId FROM card WHERE highlightId IS NOT NULL AND deletedAt IS NULL)") }
        if let sourceId {
            clauses.append("highlight.sourceId = ?")
            args.append(sourceId)
        }
        // tags 以 JSON 数组存储，用 json_each 匹配；1.1 起父标签包含子标签（“儒家”也找出“儒家/孟子”）
        for t in ([tag].compactMap { $0 } + tags + parsed.tags) where !t.isEmpty {
            clauses.append("EXISTS (SELECT 1 FROM json_each(highlight.tags) WHERE json_each.value = ? OR substr(json_each.value, 1, ?) = ?)")
            args.append(t)
            args.append(t.unicodeScalars.count + 1)
            args.append(t + "/")
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
            sql += q.orderSQL
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

    /// 计数和当前页在同一个读取快照内完成；查询排在数据库队列上，不阻塞界面。
    func highlightPage(_ q: HighlightQuery, limit: Int, offset: Int) async throws -> (items: [Highlight], total: Int) {
        try await writer.read { db in
            let (from, whereSQL, args) = q.sqlParts()
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(from)\(whereSQL)",
                                         arguments: StatementArguments(args)) ?? 0
            let sql = "SELECT highlight.* FROM \(from)\(whereSQL)" + q.orderSQL + ", highlight.id DESC LIMIT ? OFFSET ?"
            let items = try Highlight.fetchAll(db, sql: sql,
                arguments: StatementArguments(args + [max(1, limit), max(0, offset)]))
            return (items, total)
        }
    }

    func highlight(id: Int64) throws -> Highlight? {
        try writer.read { db in try Highlight.fetchOne(db, key: id) }
    }

    func dailyReviewCandidateCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND coalesce(s.reviewWeight, 1) > 0
                """) ?? 0
        }
    }

    func dailyQuoteCandidate(seed: Int) throws -> Highlight? {
        try writer.read { db in
            let from = """
                FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND coalesce(s.reviewWeight, 1) > 0
                """
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + from) ?? 0
            guard count > 0 else { return nil }
            return try Highlight.fetchOne(db, sql: "SELECT h.* " + from + " ORDER BY h.id LIMIT 1 OFFSET ?",
                                          arguments: [max(0, seed) % count])
        }
    }

    func existingHighlightCount(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try writer.read { db in
            try Highlight.filter(keys: ids).filter(Column("deletedAt") == nil).fetchCount(db)
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
