import Foundation
import GRDB
import KongReviewCore

// MARK: - 记忆卡

struct DeckSummary: Identifiable, Hashable {
    var name: String
    var total: Int
    var counts: StudyQueue.Counts
    var id: String { name }
}

extension AppDatabase {
    @discardableResult
    func save(_ card: Card) throws -> Card {
        try writer.write { db in
            var c = card
            c.updatedAt = Date()
            try c.save(db)
            return c
        }
    }

    func deleteCards(_ ids: [Int64]) throws {
        _ = try writer.write { db in try Card.deleteAll(db, keys: ids) }
    }

    func card(id: Int64) throws -> Card? {
        try writer.read { db in try Card.fetchOne(db, key: id) }
    }

    /// 牌组内全部卡片（不含已删除）
    func cards(deck: String? = nil, query: String = "") throws -> [Card] {
        try writer.read { db in
            var sql = "SELECT * FROM card WHERE deletedAt IS NULL"
            var args: [(any DatabaseValueConvertible)?] = []
            if let deck { sql += " AND deck = ?"; args.append(deck) }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                let p = SearchQuery.likePattern(q)
                sql += " AND (front LIKE ? ESCAPE '\\\\' OR back LIKE ? ESCAPE '\\\\')"
                args += [p, p]
            }
            sql += " ORDER BY createdAt DESC, id DESC"
            return try Card.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func deckNames() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deck FROM card WHERE deletedAt IS NULL ORDER BY deck")
        }
    }

    /// 今天已经学过的新卡、复习卡数量（用于每日上限）
    func studiedToday(now: Date = Date()) throws -> (new: Int, review: Int) {
        let start = Calendar.current.startOfDay(for: now)
        return try writer.read { db in
            // 新卡：今天第一次回答（reps 从 0 变 1）的卡；用日志里“今天出现、且今天之前没有日志”的卡近似
            let newCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT cardId) FROM review_event e
                WHERE kind = 'card' AND at >= ?
                  AND NOT EXISTS (SELECT 1 FROM review_event p WHERE p.cardId = e.cardId AND p.kind = 'card' AND p.at < ?)
                """, arguments: [start, start]) ?? 0
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT cardId) FROM review_event WHERE kind = 'card' AND at >= ?",
                                         arguments: [start]) ?? 0
            return (newCount, max(0, total - newCount))
        }
    }

    func deckSummaries(now: Date = Date(), newPerDay: Int, reviewsPerDay: Int) throws -> [DeckSummary] {
        let all = try cards()
        let done = try studiedToday(now: now)
        let grouped = Dictionary(grouping: all, by: \.deck)
        return grouped.keys.sorted().map { name in
            let cs = grouped[name] ?? []
            return DeckSummary(name: name, total: cs.count,
                               counts: StudyQueue.counts(cs, now: now, newLimitLeft: newPerDay - done.new,
                                                         reviewLimitLeft: reviewsPerDay - done.review))
        }
    }

    /// 回答一张卡：更新调度并写入回顾日志（一个事务）
    @discardableResult
    func answer(_ card: Card, _ a: CardAnswer, scheduler: CardScheduler = CardScheduler(), now: Date = Date()) throws -> Card {
        try writer.write { db in
            var c = scheduler.answer(card, a, now: now)
            try c.save(db)
            var e = ReviewEvent(kind: .card, cardId: c.id, answer: a.rawValue, at: now)
            try e.insert(db)
            return c
        }
    }

    /// 把摘录做成记忆卡；已有对应卡片的跳过。返回新建数量
    @discardableResult
    func makeCards(fromHighlights ids: [Int64], deck: String = "摘录", style: CitationStyle = .footnote) throws -> Int {
        try writer.write { db in
            var n = 0
            for h in try Highlight.fetchAll(db, keys: ids) where h.deletedAt == nil {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM card WHERE highlightId = ? AND deletedAt IS NULL)", arguments: [h.id]) ?? false
                if exists { continue }
                let src = try h.sourceId.flatMap { try Source.fetchOne(db, key: $0) }
                var c = Card.from(h, source: src, deck: deck, style: style)
                try c.insert(db)
                n += 1
            }
            return n
        }
    }

    func cardHighlightIDs() throws -> Set<Int64> {
        try writer.read { db in Set(try Int64.fetchAll(db, sql: "SELECT highlightId FROM card WHERE highlightId IS NOT NULL AND deletedAt IS NULL")) }
    }

    func renameDeck(_ old: String, to new: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE card SET deck = ? WHERE deck = ?", arguments: [new, old]) }
    }

    // MARK: 媒体

    func media(named name: String) throws -> Data? {
        try writer.read { db in try Data.fetchOne(db, sql: "SELECT data FROM card_media WHERE name = ?", arguments: [name]) }
    }

    // MARK: 导入

    struct CardImportReport: Equatable {
        var imported = 0
        var duplicates = 0
        var media = 0
        var decks: [String] = []
    }

    /// 导入 Anki 笔记（一个事务）：按 guid 去重；media 为 文件名 → 数据
    @discardableResult
    func importAnki(_ notes: [AnkiNote], media: [String: Data] = [:], now: Date = Date()) throws -> CardImportReport {
        try writer.write { db in
            var r = CardImportReport()
            var decks = Set<String>()
            for n in notes {
                if let g = n.guid, !g.isEmpty,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM card WHERE ankiGuid = ?)", arguments: [g]) ?? false {
                    r.duplicates += 1
                    continue
                }
                var c = Card(deck: n.deck, front: n.front, back: n.back, tags: n.tags, due: now,
                             ankiGuid: (n.guid?.isEmpty ?? true) ? nil : n.guid, createdAt: now, updatedAt: now)
                if let s = n.schedule {
                    c.state = s.state; c.interval = s.interval; c.ease = s.ease; c.due = s.due
                    c.reps = s.reps; c.lapses = s.lapses; c.isSuspended = s.suspended
                }
                try c.insert(db)
                r.imported += 1
                decks.insert(n.deck)
            }
            for (name, data) in media {
                try db.execute(sql: "INSERT OR REPLACE INTO card_media (name, data) VALUES (?, ?)", arguments: [name, data])
                r.media += 1
            }
            r.decks = decks.sorted()
            return r
        }
    }
}

// MARK: - 读取 Anki 集合（.apkg 解压后的 collection.anki2 / collection.anki21）

enum AnkiCollectionReader {
    enum ReadError: LocalizedError {
        case newFormatOnly
        case newFormatUnreadable(String)
        case noCollection
        var errorDescription: String? {
            switch self {
            case .newFormatOnly:
                return "这个 .apkg 是 Anki 新版压缩格式，暂时读不了。请在 Anki 导出时勾选“支持旧版 Anki（Support older Anki versions）”，或改用“纯文本笔记”导出。"
            case .newFormatUnreadable(let detail):
                return "读取 Anki 新格式的集合失败（\(detail)）。可以在 Anki 导出时勾选“支持旧版 Anki（Support older Anki versions）”再试。"
            case .noCollection:
                return "文件里没有找到 Anki 集合数据，可能不是 .apkg 牌组文件。"
            }
        }
    }

    /// folder 为 .apkg 解压后的目录
    static func read(folder: URL, now: Date = Date()) throws -> (notes: [AnkiNote], media: [String: Data]) {
        let fm = FileManager.default
        let c21b = folder.appendingPathComponent("collection.anki21b")
        let c21 = folder.appendingPathComponent("collection.anki21")
        let c2 = folder.appendingPathComponent("collection.anki2")
        let path: URL
        if fm.fileExists(atPath: c21b.path) {
            // 新格式：zstd 压缩的 SQLite，先解压成普通数据库文件再读
            let unpacked = folder.appendingPathComponent("collection.kongreview.sqlite")
            let packed = try Data(contentsOf: c21b)
            do {
                try Zstd.decompress(packed).write(to: unpacked)
            } catch {
                throw ReadError.newFormatUnreadable(error.localizedDescription)
            }
            path = unpacked
        }
        else if fm.fileExists(atPath: c21.path) { path = c21 }
        else if fm.fileExists(atPath: c2.path) { path = c2 }
        else { throw ReadError.noCollection }

        var config = Configuration()
        config.readonly = true
        let dbq = try DatabaseQueue(path: path.path, configuration: config)
        let notes: [AnkiNote] = try dbq.read { db in
            let col = try Row.fetchOne(db, sql: "SELECT crt, models, decks FROM col")
            let crt = Date(timeIntervalSince1970: TimeInterval((col?["crt"] as Int64?) ?? 0))

            // 笔记类型：id → (是否完形填空)；牌组：id → 名称
            var clozeModels = Set<Int64>()
            var deckNames: [Int64: String] = [:]
            if let modelsJSON: String = col?["models"], let data = modelsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj {
                    if let m = v as? [String: Any], (m["type"] as? Int) == 1, let id = Int64(k) { clozeModels.insert(id) }
                }
            }
            if let decksJSON: String = col?["decks"], let data = decksJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj {
                    if let d = v as? [String: Any], let name = d["name"] as? String, let id = Int64(k) {
                        deckNames[id] = name.replacingOccurrences(of: "\u{1f}", with: "::")
                    }
                }
            }
            // schema 18（新格式）：笔记类型在 notetypes 表，config 为 protobuf，开头 08 01 表示 kind = 完形填空
            if try db.tableExists("notetypes") {
                for id in try Int64.fetchAll(db, sql: "SELECT id FROM notetypes WHERE hex(substr(config, 1, 2)) = '0801'") {
                    clozeModels.insert(id)
                }
            }
            if deckNames.isEmpty, try db.tableExists("decks") {
                for r in try Row.fetchAll(db, sql: "SELECT id, name FROM decks") {
                    deckNames[r["id"]] = (r["name"] as String? ?? "").replacingOccurrences(of: "\u{1f}", with: "::")
                }
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id AS nid, n.guid, n.mid, n.flds, n.tags,
                       c.did, c.type, c.queue, c.due, c.ivl, c.factor, c.reps, c.lapses
                FROM notes n
                JOIN cards c ON c.nid = n.id
                WHERE c.ord = (SELECT MIN(ord) FROM cards c2 WHERE c2.nid = n.id)
                ORDER BY n.id
                """)
            return rows.map { r in
                let fields = (r["flds"] as String? ?? "").components(separatedBy: "\u{1f}")
                let mid: Int64 = r["mid"]
                let faces = AnkiContent.faces(fields: fields, isClozeModel: clozeModels.contains(mid))
                let tags = (r["tags"] as String? ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty }
                let did: Int64 = r["did"]
                let schedule = AnkiNote.schedule(
                    type: r["type"], queue: r["queue"], due: r["due"], ivl: r["ivl"], factor: r["factor"],
                    reps: r["reps"], lapses: r["lapses"], collectionCreated: crt, now: now)
                return AnkiNote(front: faces.front, back: faces.back, tags: tags,
                                deck: deckNames[did] ?? "Anki", guid: r["guid"], schedule: schedule)
            }
        }
        // 万一读到的是新版包里那条“请升级 Anki”的占位笔记
        if notes.count <= 1, let f = notes.first?.front,
           f.contains("Anki"), f.contains("update") || f.contains("更新") || f.contains("升级") {
            throw ReadError.newFormatOnly
        }

        // 媒体：只取笔记里真正引用到的文件（包里常有大量已不用的音频）
        var wanted = Set<String>()
        for n in notes {
            wanted.formUnion(AnkiPackage.mediaReferences(in: n.front))
            wanted.formUnion(AnkiPackage.mediaReferences(in: n.back))
        }
        var media: [String: Data] = [:]
        if !wanted.isEmpty, let index = try? Data(contentsOf: folder.appendingPathComponent("media")) {
            for (file, name) in AnkiPackage.mediaMap(index) where wanted.contains(name) {
                guard let d = try? Data(contentsOf: folder.appendingPathComponent(file)) else { continue }
                media[name] = Zstd.isZstd(d) ? ((try? Zstd.decompress(d)) ?? d) : d
            }
        }
        return (notes, media)
    }
}

// MARK: - 回顾日志

extension AppDatabase {
    func log(_ event: ReviewEvent) {
        _ = try? writer.write { db in
            var e = event
            try e.insert(db)
        }
    }

    func events() throws -> [ReviewEvent] {
        try writer.read { db in try ReviewEvent.order(Column("at")).fetchAll(db) }
    }

    /// 今天是否回顾过（看过摘录或复习过记忆卡；只写按语不算）
    func reviewedToday(now: Date = Date()) throws -> Bool {
        let start = Calendar.current.startOfDay(for: now)
        return try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM review_event WHERE at >= ? AND kind != 'note')", arguments: [start]) ?? false
        }
    }
}

// MARK: - 网页图片缓存

extension AppDatabase {
    func cachedImage(_ url: String) throws -> (data: Data, mime: String?)? {
        try writer.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT data, mime FROM image_cache WHERE url = ?", arguments: [url]) else { return nil }
            return (r["data"], r["mime"])
        }
    }

    func cacheImage(_ url: String, data: Data, mime: String?) {
        _ = try? writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO image_cache (url, data, mime, fetchedAt) VALUES (?, ?, ?, ?)",
                           arguments: [url, data, mime, Date()])
        }
    }

    /// 修改存档正文（HTML），同时更新纯文本与字数
    func updateArticleContent(id: Int64, html: String) throws {
        let text = Markdown.plainText(fromHTML: html)
        try writer.write { db in
            try db.execute(sql: "UPDATE article SET contentHTML = ?, contentText = ?, wordCount = ? WHERE id = ?",
                           arguments: [html, text, ArticleText.wordCount(text), id])
        }
    }
}
