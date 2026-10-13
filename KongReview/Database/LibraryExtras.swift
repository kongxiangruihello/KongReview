import Foundation
import GRDB
import KongReviewCore

// MARK: - 出处封面、摘录频率、收件箱导入

extension AppDatabase {
    func cover(sourceId: Int64) throws -> Data? {
        try writer.read { db in try Data.fetchOne(db, sql: "SELECT data FROM source_cover WHERE sourceId = ?", arguments: [sourceId]) }
    }

    /// 有封面的出处 id
    func coverSourceIDs() throws -> Set<Int64> {
        try writer.read { db in Set(try Int64.fetchAll(db, sql: "SELECT sourceId FROM source_cover")) }
    }

    /// 设置封面；data 为 nil 时删除
    func setCover(sourceId: Int64, data: Data?) throws {
        try writer.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO source_cover (sourceId, data, updatedAt) VALUES (?, ?, ?)",
                               arguments: [sourceId, data, Date()])
            } else {
                try db.execute(sql: "DELETE FROM source_cover WHERE sourceId = ?", arguments: [sourceId])
            }
        }
    }

    func setFrequency(_ value: Int?, highlightId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE highlight SET frequency = ?, updatedAt = ? WHERE id = ?",
                           arguments: [value, Date(), highlightId])
        }
    }

    struct InboxReport: Equatable {
        var added = 0
        var duplicates = 0
        var sourceTitle = ""
    }

    /// 导入一个收件箱文件：出处按标题 + 作者合并；摘录按 来源应用 + 外部 id 去重
    func importInbox(_ file: InboxPayload.File, now: Date = Date()) throws -> InboxReport {
        try writer.write { db in
            var r = InboxReport(sourceTitle: file.source.title)
            let info = file.source
            let author = info.author ?? ""
            var source: Source
            if let existing = try Source.filter(Column("title") == info.title && Column("author") == author).fetchOne(db) {
                source = existing
                var changed = false
                if source.url == nil, let u = info.url { source.url = u; changed = true }
                if source.isbn == nil, let i = info.isbn { source.isbn = i; changed = true }
                if changed { try source.update(db) }
            } else {
                source = Source(title: info.title, author: author, kind: info.sourceKind, url: info.url,
                                publisher: info.publisher, year: info.year)
                source.isbn = info.isbn
                try source.insert(db)
            }
            for item in file.highlights {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let key = InboxPayload.key(app: file.app, item: item)
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_item WHERE key = ?)", arguments: [key]) ?? false {
                    r.duplicates += 1
                    continue
                }
                var h = Highlight(sourceId: source.id, text: text, translation: item.translation?.nilIfBlank,
                                  note: item.note?.nilIfBlank, location: item.resolvedLocation, tags: item.tags ?? [],
                                  createdAt: item.createdAt ?? now, updatedAt: now)
                try h.insert(db)
                try db.execute(sql: "INSERT INTO inbox_item (key, highlightId, importedAt) VALUES (?, ?, ?)",
                               arguments: [key, h.id, now])
                r.added += 1
            }
            return r
        }
    }
}

// MARK: - 已存搜索（存在 UserDefaults，体积很小）

struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var text: String
    var filter: ListFilter

    static let key = "list.savedSearches"

    static func all() -> [SavedSearch] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: d)) ?? []
    }

    static func save(_ list: [SavedSearch]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// 列表上方的组合筛选
struct ListFilter: Codable, Hashable {
    var sourceId: Int64?
    var tags: [String] = []
    var from: Date?
    var to: Date?
    var favoritesOnly = false

    var isEmpty: Bool { sourceId == nil && tags.isEmpty && from == nil && to == nil && !favoritesOnly }
}

// MARK: - 1.0：统计汇总、相关摘录、备份恢复

extension AppDatabase {
    /// 按日汇总回顾日志（SQL 里完成，不把上万条日志读进内存）
    func reviewSummary(now: Date = Date(), days: Int = 30) throws -> ReviewStats.Summary {
        try writer.read { db in
            var byDay: [String: ReviewStats.Day] = [:]
            var again = 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(at, 'localtime') AS d,
                       SUM(CASE WHEN kind NOT IN ('card', 'note') THEN 1 ELSE 0 END) AS h,
                       SUM(CASE WHEN kind = 'card' THEN 1 ELSE 0 END) AS c,
                       SUM(CASE WHEN kind = 'card' AND answer = 1 THEN 1 ELSE 0 END) AS a
                FROM review_event GROUP BY d
                """)
            for r in rows {
                guard let d: String = r["d"] else { continue }
                byDay[d] = ReviewStats.Day(key: d, highlights: r["h"] ?? 0, cards: r["c"] ?? 0)
                again += (r["a"] as Int?) ?? 0
            }
            return ReviewStats.summarize(byDay: byDay, again: again, now: now, days: days)
        }
    }

    /// 今天回答记忆卡的次数与答对（非“重来”）次数
    func cardAnswersToday(now: Date = Date()) throws -> (total: Int, correct: Int) {
        let start = Calendar.current.startOfDay(for: now)
        return try writer.read { db in
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, SUM(CASE WHEN answer > 1 THEN 1 ELSE 0 END) AS ok
                FROM review_event WHERE kind = 'card' AND at >= ?
                """, arguments: [start])
            return ((r?["n"] as Int?) ?? 0, (r?["ok"] as Int?) ?? 0)
        }
    }

    /// 建“相关摘录”索引用的数据（未删除、未弃置）
    func relatedDocs() throws -> [RelatedIndex.Doc] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, text, IFNULL(translation, '') AS tr, IFNULL(note, '') AS note, tags, sourceId
                FROM highlight WHERE deletedAt IS NULL AND isDiscarded = 0
                """).map { r in
                let tagsJSON: String = r["tags"] ?? "[]"
                let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
                let text: String = r["text"] ?? ""
                let note: String = r["note"] ?? ""
                return RelatedIndex.Doc(id: r["id"], text: text + "\n" + note, tags: tags, sourceId: r["sourceId"])
            }
        }
    }

    /// 用备份文件的内容整体替换当前数据库（SQLite 在线备份，App 不用重启），再补跑迁移
    func restore(from backup: URL) throws {
        var config = Configuration()
        config.readonly = true
        let source = try DatabaseQueue(path: backup.path, configuration: config)
        try source.backup(to: writer)
        try source.close()
        try migrateIfNeeded()
    }
}

/// 备份文件的概况（恢复面板里列出）
struct BackupInfo: Identifiable, Hashable {
    var url: URL
    var date: Date
    var bytes: Int64
    var highlights: Int
    var cards: Int
    var id: URL { url }

    static func read(_ url: URL) -> BackupInfo? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var config = Configuration()
        config.readonly = true
        guard let q = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        defer { try? q.close() }
        let counts: (Int, Int)? = try? q.read { db in
            let h = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM highlight WHERE deletedAt IS NULL") ?? 0
            let c = try db.tableExists("card") ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card WHERE deletedAt IS NULL") ?? 0) : 0
            return (h, c)
        }
        guard let counts else { return nil }
        return BackupInfo(url: url, date: date, bytes: bytes, highlights: counts.0, cards: counts.1)
    }

    /// 备份文件夹里的全部备份（本机与 iCloud 两处），新的在前
    static func all() -> [BackupInfo] {
        var urls: [URL] = []
        for loc in BackupService.Location.allCases {
            guard let dir = try? BackupService.directory(for: loc) else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where n.hasSuffix(".sqlite") && !n.hasPrefix(".") {
                let u = dir.appendingPathComponent(n)
                if !urls.contains(u) { urls.append(u) }
            }
        }
        return urls.compactMap(read).sorted { $0.date > $1.date }
    }
}

// MARK: - 撤销：改动前的快照

/// 一次可撤销操作涉及的数据在改动前的样子（摘录含已删除的、出处、记忆卡、网页存档所属出处）
struct UndoSnapshot: Sendable {
    var highlightIds: [Int64]
    var sourceIds: [Int64]
    var cardIds: [Int64]
    var highlights: [Highlight] = []
    var sources: [Source] = []
    var cards: [Card] = []
    /// 网页存档 id → 所属出处
    var articleSources: [Int64: Int64?] = [:]
}

extension AppDatabase {
    /// 记下这些摘录、出处（连同其下全部摘录与网页存档）、记忆卡现在的样子
    func snapshot(highlightIds: [Int64] = [], sourceIds: [Int64] = [], cardIds: [Int64] = []) throws -> UndoSnapshot {
        try writer.read { db in
            var s = UndoSnapshot(highlightIds: highlightIds, sourceIds: sourceIds, cardIds: cardIds)
            var hs = try Highlight.fetchAll(db, keys: highlightIds)
            if !sourceIds.isEmpty {
                let more = try Highlight.filter(sourceIds.contains(Column("sourceId"))).fetchAll(db)
                let have = Set(hs.compactMap(\.id))
                hs += more.filter { !have.contains($0.id ?? -1) }
                s.sources = try Source.fetchAll(db, keys: sourceIds)
                for r in try Row.fetchAll(db, sql: "SELECT id, sourceId FROM article WHERE sourceId IN (" +
                                          sourceIds.map { _ in "?" }.joined(separator: ",") + ")",
                                          arguments: StatementArguments(sourceIds)) {
                    s.articleSources[r["id"]] = r["sourceId"]
                }
            }
            s.highlights = hs
            s.cards = try Card.fetchAll(db, keys: cardIds)
            return s
        }
    }

    /// 把快照写回（出处先写，摘录、卡片、存档随后）
    func restore(_ s: UndoSnapshot) throws {
        try writer.write { db in
            for var src in s.sources { try src.save(db) }
            for var h in s.highlights { try h.save(db) }
            for var c in s.cards { try c.save(db) }
            for (aid, sid) in s.articleSources {
                try db.execute(sql: "UPDATE article SET sourceId = ? WHERE id = ?", arguments: [sid, aid])
            }
        }
    }
}

// MARK: - 摘录图片

extension AppDatabase {
    /// 把导入的图片存进媒体表（与记忆卡图片同表，经 kr-media:// 显示；同名覆盖）
    func saveMedia(_ media: [String: Data]) throws {
        guard !media.isEmpty else { return }
        try writer.write { db in
            for (name, data) in media {
                try db.execute(sql: "INSERT OR REPLACE INTO card_media (name, data) VALUES (?, ?)", arguments: [name, data])
            }
        }
    }
}

// MARK: - 1.1：记忆卡统计（SQL 汇总）

extension AppDatabase {
    /// 各状态卡片张数（不读出全部卡片）
    func cardStateCounts() throws -> CardStateCounts {
        try writer.read { db in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN state = 'new' THEN 1 ELSE 0 END) AS n,
                       SUM(CASE WHEN state IN ('learning', 'relearning') THEN 1 ELSE 0 END) AS l,
                       SUM(CASE WHEN state = 'review' THEN 1 ELSE 0 END) AS r,
                       SUM(CASE WHEN isSuspended THEN 1 ELSE 0 END) AS s
                FROM card WHERE deletedAt IS NULL
                """) else { return CardStateCounts() }
            return CardStateCounts(total: r["total"] ?? 0, new: r["n"] ?? 0, learning: r["l"] ?? 0,
                                   review: r["r"] ?? 0, suspended: r["s"] ?? 0)
        }
    }

    /// 已学过、未暂停的卡片的到期时间（负荷预测用）
    func studiedCardDues() throws -> [Date] {
        try writer.read { db in
            try Date.fetchAll(db, sql: """
                SELECT due FROM card WHERE deletedAt IS NULL AND NOT isSuspended AND state <> 'new'
                """)
        }
    }

    /// 某时刻以来的记忆卡作答（保留率用；多取 days 天之前的作答作“上一次”参照）
    func cardAnswers(since: Date) throws -> [CardForecast.Answer] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT cardId, answer, at FROM review_event
                WHERE kind = 'card' AND cardId IS NOT NULL AND answer IS NOT NULL AND at >= ?
                ORDER BY cardId, at
                """, arguments: [since]).map {
                CardForecast.Answer(cardId: $0["cardId"], answer: $0["answer"], at: $0["at"])
            }
        }
    }

    /// 平均期望保留率：用 FSRS 的牌组取平均，没有则 0.9
    func targetRetention() throws -> Double {
        let fsrs = try deckOptions().values.filter { $0.algorithm == .fsrs }
        guard !fsrs.isEmpty else { return 0.9 }
        return fsrs.map(\.desiredRetention).reduce(0, +) / Double(fsrs.count)
    }
}

// MARK: - 1.1：标签整理

extension AppDatabase {
    /// 标签 → 摘录数（不含弃置、已删除）
    func tagCounts() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT json_each.value AS tag, COUNT(*) AS n FROM highlight, json_each(highlight.tags)
                WHERE highlight.isDiscarded = 0 AND highlight.deletedAt IS NULL
                GROUP BY json_each.value
                """) {
                if let t: String = r["tag"] { out[t] = r["n"] ?? 0 }
            }
            return out
        }
    }

    /// 带有这个标签（或其子标签）的全部摘录 id，包括弃置和最近删除里的
    func highlightIDs(withTag tag: String) throws -> [Int64] {
        try writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT highlight.id FROM highlight, json_each(highlight.tags)
                WHERE json_each.value = ? OR substr(json_each.value, 1, ?) = ?
                """, arguments: [tag, tag.unicodeScalars.count + 1, tag + "/"])
        }
    }

    /// 标签改名或合并（新名已存在即合并）；子标签一并改。返回改动的摘录数。
    @discardableResult
    func renameTag(_ old: String, to new: String, now: Date = Date()) throws -> Int {
        let ids = try highlightIDs(withTag: old)
        return try writer.write { db in
            var n = 0
            for var h in try Highlight.fetchAll(db, keys: ids) {
                let tags = TagOps.rename(h.tags, from: old, to: new)
                guard tags != h.tags else { continue }
                h.tags = tags
                h.updatedAt = now
                try h.update(db)
                n += 1
            }
            return n
        }
    }

    /// 从所有摘录上去掉这个标签（连同子标签），摘录本身保留。返回改动的摘录数。
    @discardableResult
    func deleteTag(_ tag: String, now: Date = Date()) throws -> Int {
        let ids = try highlightIDs(withTag: tag)
        return try writer.write { db in
            var n = 0
            for var h in try Highlight.fetchAll(db, keys: ids) {
                let tags = TagOps.remove(h.tags, tag: tag)
                guard tags != h.tags else { continue }
                h.tags = tags
                h.updatedAt = now
                try h.update(db)
                n += 1
            }
            return n
        }
    }
}
