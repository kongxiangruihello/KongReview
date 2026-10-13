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

    func cardCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card WHERE deletedAt IS NULL") ?? 0 }
    }

    func deckNames() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deck FROM card WHERE deletedAt IS NULL ORDER BY deck")
        }
    }

    /// 今天已经学过的新卡、复习卡数量（用于每日上限）；deck 为 nil 时统计全部牌组
    func studiedToday(deck: String? = nil, now: Date = Date()) throws -> (new: Int, review: Int) {
        let start = Calendar.current.startOfDay(for: now)
        return try writer.read { db in
            let deckFilter = deck == nil ? "" : " AND e.cardId IN (SELECT id FROM card WHERE deck = ?)"
            var args: [DatabaseValueConvertible] = [start, start]
            if let deck { args.append(deck) }
            // 新卡：今天第一次回答的卡（今天之前没有日志）
            let newCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT cardId) FROM review_event e
                WHERE kind = 'card' AND at >= ?
                  AND NOT EXISTS (SELECT 1 FROM review_event p WHERE p.cardId = e.cardId AND p.kind = 'card' AND p.at < ?)
                """ + deckFilter, arguments: StatementArguments(args)) ?? 0
            var args2: [DatabaseValueConvertible] = [start]
            if let deck { args2.append(deck) }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT cardId) FROM review_event e WHERE kind = 'card' AND at >= ?" + deckFilter,
                                         arguments: StatementArguments(args2)) ?? 0
            return (newCount, max(0, total - newCount))
        }
    }

    /// 牌组的有效选项：没设置过的项用全局默认
    func effectiveOptions(_ deck: String, defaults: (new: Int, review: Int)) throws -> DeckOptions {
        var o = try writer.read { db in try DeckOptions.fetchOne(db, key: deck) } ?? DeckOptions(deck: deck)
        if o.newPerDay == nil { o.newPerDay = defaults.new }
        if o.reviewsPerDay == nil { o.reviewsPerDay = defaults.review }
        return o
    }

    func deckSummaries(now: Date = Date(), newPerDay: Int, reviewsPerDay: Int) throws -> [DeckSummary] {
        let all = try cards()
        let options = try deckOptions()
        let grouped = Dictionary(grouping: all, by: \.deck)
        return try grouped.keys.sorted().map { name in
            let cs = grouped[name] ?? []
            let o = options[name]
            let done = try studiedToday(deck: name, now: now)
            return DeckSummary(name: name, total: cs.count,
                               counts: StudyQueue.counts(cs, now: now,
                                                         newLimitLeft: (o?.newPerDay ?? newPerDay) - done.new,
                                                         reviewLimitLeft: (o?.reviewsPerDay ?? reviewsPerDay) - done.review))
        }
    }

    /// 回答一张卡：更新调度并写入回顾日志（一个事务）
    @discardableResult
    func answer(_ card: Card, _ a: CardAnswer, scheduler: any CardScheduling = CardScheduler(), now: Date = Date()) throws -> Card {
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
        /// 已导入过的卡片补上了字段、记忆状态或复习记录（重复导入同一个包时）
        var upgraded = 0
        var media = 0
        var revlog = 0
        var templates = 0
        var decks: [String] = []
        var fsrsDecks: [String] = []
    }

    /// 导入 Anki 笔记（一个事务）：按 guid 去重；media 为 文件名 → 数据。
    /// 已导入过的笔记不重复建卡，但会补上 0.8 新增的内容：多字段、笔记类型、FSRS 记忆状态、复习记录。
    @discardableResult
    func importAnki(_ notes: [AnkiNote], media: [String: Data] = [:], now: Date = Date()) throws -> CardImportReport {
        try writer.write { db in
            var r = CardImportReport()
            var decks = Set<String>()
            var fsrsDecks = Set<String>()

            // 笔记类型模板：已有的不覆盖（保留用户改过的设置）
            var seenTypes = Set<String>()
            for n in notes {
                guard let type = n.noteType, !n.fieldNames.isEmpty, seenTypes.insert(type).inserted else { continue }
                if try NoteTemplate.fetchOne(db, key: type) == nil {
                    try NoteTemplate.defaultTemplate(name: type, fieldNames: n.fieldNames, isCloze: n.isCloze).insert(db)
                    r.templates += 1
                }
            }
            // 牌组选项：沿用 Anki 的每日上限、算法与期望保留率（已设置过的牌组不覆盖）
            var seenDecks = Set<String>()
            for n in notes {
                guard var o = n.deckOptions, seenDecks.insert(n.deck).inserted else { continue }
                o.deck = n.deck
                if try DeckOptions.fetchOne(db, key: n.deck) == nil { try o.insert(db) }
                if o.algorithm == .fsrs { fsrsDecks.insert(n.deck) }
            }

            for n in notes {
                var card: Card
                if let g = n.guid, !g.isEmpty, let existing = try Card.filter(Column("ankiGuid") == g).fetchOne(db) {
                    r.duplicates += 1
                    card = existing
                    var changed = false
                    if card.fields.isEmpty, !n.fields.isEmpty, n.noteType != nil {
                        card.fields = n.fields; card.noteType = n.noteType; changed = true
                    }
                    if card.stability == nil, let m = n.memory {
                        card.stability = m.stability; card.difficulty = m.difficulty; changed = true
                    }
                    if card.lastReview == nil, let last = n.revlog.last { card.lastReview = last.at; changed = true }
                    if changed { try card.update(db); r.upgraded += 1 }
                } else {
                    card = Card(deck: n.deck, front: n.front, back: n.back, tags: n.tags, due: now,
                                ankiGuid: (n.guid?.isEmpty ?? true) ? nil : n.guid, createdAt: now, updatedAt: now)
                    if let s = n.schedule {
                        card.state = s.state; card.interval = s.interval; card.ease = s.ease; card.due = s.due
                        card.reps = s.reps; card.lapses = s.lapses; card.isSuspended = s.suspended
                    }
                    if n.noteType != nil, !n.fields.isEmpty { card.noteType = n.noteType; card.fields = n.fields }
                    if let m = n.memory { card.stability = m.stability; card.difficulty = m.difficulty }
                    card.lastReview = n.revlog.last?.at
                    try card.insert(db)
                    r.imported += 1
                    decks.insert(n.deck)
                }
                // 复习记录写进回顾日志（统计与 FSRS 参数优化都用它）；按 Anki 的记录 id 去重
                if let cid = card.id {
                    for log in n.revlog {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO review_event (kind, cardId, answer, at, ankiRevlogId)
                            VALUES ('card', ?, ?, ?, ?)
                            """, arguments: [cid, log.ease, log.at, log.id])
                        r.revlog += db.changesCount
                    }
                }
            }
            for (name, data) in media {
                try db.execute(sql: "INSERT OR REPLACE INTO card_media (name, data) VALUES (?, ?)", arguments: [name, data])
                r.media += 1
            }
            r.decks = decks.sorted()
            r.fsrsDecks = fsrsDecks.sorted()
            return r
        }
    }

    // MARK: 笔记类型模板

    func noteTemplates() throws -> [String: NoteTemplate] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try NoteTemplate.fetchAll(db).map { ($0.name, $0) })
        }
    }

    func save(_ template: NoteTemplate) throws {
        try writer.write { db in try template.save(db) }
    }

    /// 模板编辑器的示例卡：这个笔记类型下第一张有字段的卡（不读出全部卡片）
    func sampleCard(noteType: String) throws -> Card? {
        try writer.read { db in
            try Card.fetchOne(db, sql: """
                SELECT * FROM card WHERE noteType = ? AND deletedAt IS NULL AND fields IS NOT NULL AND fields NOT IN ('', '[]')
                ORDER BY id LIMIT 1
                """, arguments: [noteType])
        }
    }

    func cardCount(noteType: String) throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card WHERE noteType = ? AND deletedAt IS NULL", arguments: [noteType]) ?? 0 }
    }

    // MARK: 牌组选项

    func deckOptions() throws -> [String: DeckOptions] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try DeckOptions.fetchAll(db).map { ($0.deck, $0) })
        }
    }

    func save(_ options: DeckOptions) throws {
        try writer.write { db in try options.save(db) }
    }

    // MARK: FSRS

    /// 每张卡的复习记录（按时间），用于优化参数与重算记忆状态
    func fsrsHistories(decks: Set<String>? = nil) throws -> [Int64: [FSRSReview]] {
        try writer.read { db in
            var sql = """
                SELECT e.cardId, e.answer, e.at FROM review_event e JOIN card c ON c.id = e.cardId
                WHERE e.kind = 'card' AND e.answer BETWEEN 1 AND 4 AND c.deletedAt IS NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let decks, !decks.isEmpty {
                sql += " AND c.deck IN (" + decks.map { _ in "?" }.joined(separator: ",") + ")"
                args = decks.sorted()
            }
            sql += " ORDER BY e.cardId, e.at"
            var out: [Int64: [FSRSReview]] = [:]
            for r in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                let at: Date = r["at"]
                out[r["cardId"], default: []].append(FSRSReview(day: FSRS.dayNumber(at), rating: r["answer"]))
            }
            return out
        }
    }

    /// 按复习记录重算记忆状态（换参数或从 SM-2 改用 FSRS 后）；没有记录的卡保持原样。返回更新的卡数
    @discardableResult
    func recomputeMemory(parameters: [Double], decks: Set<String>) throws -> Int {
        let histories = try fsrsHistories(decks: decks)
        let f = FSRS(parameters: parameters)
        return try writer.write { db in
            var n = 0
            for (id, h) in histories {
                guard let m = f.memoryState(history: h) else { continue }
                try db.execute(sql: "UPDATE card SET stability = ?, difficulty = ? WHERE id = ?", arguments: [m.s, m.d, id])
                n += 1
            }
            return n
        }
    }

    // MARK: 摘录 ↔ 记忆卡

    func cards(forHighlight id: Int64) throws -> [Card] {
        try writer.read { db in try Card.filter(Column("highlightId") == id && Column("deletedAt") == nil).fetchAll(db) }
    }

    /// 用摘录的最新内容重新生成卡片正反面（复习进度不变）。返回更新的卡数
    @discardableResult
    func syncCards(fromHighlight id: Int64, style: CitationStyle) throws -> Int {
        try writer.write { db in
            guard let h = try Highlight.fetchOne(db, key: id) else { return 0 }
            let src = try h.sourceId.flatMap { try Source.fetchOne(db, key: $0) }
            let fresh = Card.from(h, source: src, style: style)
            var n = 0
            for var c in try Card.filter(Column("highlightId") == id && Column("deletedAt") == nil).fetchAll(db) {
                guard c.front != fresh.front || c.back != fresh.back || c.tags != fresh.tags else { continue }
                c.front = fresh.front; c.back = fresh.back; c.tags = fresh.tags; c.updatedAt = Date()
                try c.update(db)
                n += 1
            }
            return n
        }
    }

    // MARK: 整理数据库

    struct CompactReport {
        var bytesBefore: Int64
        var bytesAfter: Int64
        var mediaRemoved: Int
    }

    /// 删除没有卡片、摘录引用的媒体文件，再用 VACUUM 收回空间
    func compact() throws -> CompactReport {
        let before = fileSize()
        let removed: Int = try writer.write { db in
            var used = Set<String>()
            for r in try Row.fetchAll(db, sql: "SELECT front, back, fields FROM card WHERE deletedAt IS NULL") {
                for key in ["front", "back", "fields"] {
                    if let s: String = r[key] { used.formUnion(AnkiPackage.mediaReferences(in: s)) }
                }
            }
            // 摘录正文里的图片（如 LiquidText 导入的图片摘录）也算在用
            for text in try String.fetchAll(db, sql: "SELECT text FROM highlight WHERE text LIKE '%kr-media://%'") {
                used.formUnion(AnkiPackage.krMediaReferences(in: text))
            }
            var n = 0
            for name in try String.fetchAll(db, sql: "SELECT name FROM card_media") where !used.contains(name) {
                try db.execute(sql: "DELETE FROM card_media WHERE name = ?", arguments: [name])
                n += 1
            }
            return n
        }
        try writer.vacuum()
        return CompactReport(bytesBefore: before, bytesAfter: fileSize(), mediaRemoved: removed)
    }

    func fileSize() -> Int64 {
        let path = writer.path
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: path + suffix),
               let n = (a[.size] as? NSNumber)?.int64Value { total += n }
        }
        return total
    }

    /// 各项占用：摘录、记忆卡媒体、图片缓存、网页存档（字节，约数）
    func storageBreakdown() throws -> [(String, Int64)] {
        try writer.read { db in
            func sum(_ sql: String) throws -> Int64 { try Int64.fetchOne(db, sql: sql) ?? 0 }
            return [
                ("记忆卡图片", try sum("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM card_media")),
                ("网页图片缓存", try sum("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM image_cache")),
                ("网页存档正文", try sum("SELECT COALESCE(SUM(LENGTH(contentHTML)), 0) FROM article")),
                ("记忆卡", try sum("SELECT COALESCE(SUM(LENGTH(front) + LENGTH(back) + LENGTH(fields)), 0) FROM card")),
            ]
        }
    }

    // MARK: 导出到 Anki

    /// 导出若干牌组为 .apkg 包内文件（写到 folder）
    func exportApkg(decks: Set<String>, includeScheduling: Bool, fsrsParameters: [Double]?,
                    defaults: (new: Int, review: Int), to folder: URL) throws -> ApkgWriter.Report {
        let cards = try self.cards().filter { decks.contains($0.deck) }
        let templates = try noteTemplates()
        let options = try deckOptions()
        let ids = cards.compactMap(\.id)
        let history: [Int64: [ReviewEvent]] = try writer.read { db in
            guard includeScheduling, !ids.isEmpty else { return [:] }
            let events = try ReviewEvent.filter(Column("kind") == "card" && ids.contains(Column("cardId")))
                .order(Column("at")).fetchAll(db)
            return Dictionary(grouping: events) { $0.cardId ?? -1 }
        }
        let anyFSRS = decks.contains { options[$0]?.algorithm == .fsrs }
        let retention = decks.compactMap { options[$0]?.desiredRetention }.first ?? 0.9
        return try ApkgWriter.writeFolder(
            cards: cards, templates: templates, media: { try? self.media(named: $0) },
            history: history, includeScheduling: includeScheduling,
            fsrsParameters: anyFSRS ? fsrsParameters : nil, desiredRetention: retention,
            newPerDay: defaults.new, reviewsPerDay: defaults.review, to: folder)
    }

    // MARK: 提醒用：某天待复习的卡数（估计）

    func cardsDue(on day: Date, newPerDay: Int, reviewsPerDay: Int) throws -> Int {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day)) ?? day
        return try writer.read { db in
            let rev = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM card WHERE deletedAt IS NULL AND isSuspended = 0 AND state != 'new' AND due < ?
                """, arguments: [end]) ?? 0
            let new = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card WHERE deletedAt IS NULL AND isSuspended = 0 AND state = 'new'") ?? 0
            return min(rev, reviewsPerDay) + min(new, newPerDay)
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

    /// 把 SQLite 文件头的读写版本号（第 18、19 字节）从 2（WAL）改为 1（rollback journal）
    static func disableWAL(at url: URL) {
        guard let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 20), head.count == 20,
              head.starts(with: Data("SQLite format 3".utf8)),
              head[18] == 2 || head[19] == 2 else { return }
        try? h.seek(toOffset: 18)
        try? h.write(contentsOf: Data([1, 1]))
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

        // Anki 的集合是 WAL 模式（文件头第 18、19 字节为 2）。包里没有 -wal / -shm 文件，
        // 以只读方式打开 WAL 数据库时 macOS 的 SQLite 会报 error 14（unable to open database file）。
        // 这里读的是解压到临时目录的副本，直接把文件头改回传统日志模式（1），再正常打开。
        disableWAL(at: path)
        let dbq = try DatabaseQueue(path: path.path)
        let notes: [AnkiNote] = try dbq.read { db in
            let colColumns = Set(try db.columns(in: "col").map(\.name))
            let wanted = ["crt", "models", "decks", "dconf", "conf"].filter(colColumns.contains)
            let col = try Row.fetchOne(db, sql: "SELECT \(wanted.joined(separator: ", ")) FROM col")
            let crt = Date(timeIntervalSince1970: TimeInterval((col?["crt"] as Int64?) ?? 0))
            func json(_ key: String) -> [String: Any]? {
                guard let text: String = col?[key], let data = text.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

            // 笔记类型：id → 名称、字段名、是否完形填空
            var clozeModels = Set<Int64>()
            var modelNames: [Int64: String] = [:]
            var modelFields: [Int64: [String]] = [:]
            if let obj = json("models") {
                for (k, v) in obj {
                    guard let m = v as? [String: Any], let id = Int64(k) else { continue }
                    if (m["type"] as? Int) == 1 { clozeModels.insert(id) }
                    modelNames[id] = m["name"] as? String
                    if let flds = m["flds"] as? [[String: Any]] {
                        modelFields[id] = flds.sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                            .compactMap { $0["name"] as? String }
                    }
                }
            }
            // schema 18（新格式）：笔记类型在 notetypes 表（config 为 protobuf，开头 08 01 表示完形填空），字段在 fields 表
            if try db.tableExists("notetypes") {
                for r in try Row.fetchAll(db, sql: "SELECT id, name, hex(substr(config, 1, 2)) AS k FROM notetypes") {
                    let id: Int64 = r["id"]
                    modelNames[id] = r["name"]
                    if (r["k"] as String?) == "0801" { clozeModels.insert(id) }
                }
            }
            if try db.tableExists("fields") {
                for r in try Row.fetchAll(db, sql: "SELECT ntid, name FROM fields ORDER BY ntid, ord") {
                    let id: Int64 = r["ntid"]
                    modelFields[id, default: []].append(r["name"] ?? "")
                }
            }

            // 牌组：id → 名称、选项组 id；选项组 id → 每日上限与期望保留率
            var deckNames: [Int64: String] = [:]
            var deckConfigOf: [Int64: Int64] = [:]
            var configs: [Int64: (new: Int?, rev: Int?, retention: Double?)] = [:]
            var fsrsOn = false
            if let obj = json("decks") {
                for (k, v) in obj {
                    guard let d = v as? [String: Any], let id = Int64(k) else { continue }
                    if let name = d["name"] as? String { deckNames[id] = name.replacingOccurrences(of: "\u{1f}", with: "::") }
                    if let conf = (d["conf"] as? NSNumber)?.int64Value { deckConfigOf[id] = conf }
                }
            }
            if let obj = json("dconf") {
                for (k, v) in obj {
                    guard let c = v as? [String: Any], let id = Int64(k) else { continue }
                    let new = ((c["new"] as? [String: Any])?["perDay"] as? NSNumber)?.intValue
                    let rev = ((c["rev"] as? [String: Any])?["perDay"] as? NSNumber)?.intValue
                    configs[id] = (new, rev, (c["desiredRetention"] as? NSNumber)?.doubleValue)
                }
            }
            if let conf = json("conf"), (conf["fsrs"] as? Bool) == true { fsrsOn = true }
            if try db.tableExists("decks") {
                let hasKind = try db.columns(in: "decks").contains { $0.name == "kind" }
                for r in try Row.fetchAll(db, sql: hasKind ? "SELECT id, name, kind FROM decks" : "SELECT id, name FROM decks") {
                    let id: Int64 = r["id"]
                    deckNames[id] = (r["name"] as String? ?? "").replacingOccurrences(of: "\u{1f}", with: "::")
                    if hasKind, let kind: Data = r["kind"], let cid = AnkiPackage.deckConfigID(fromKind: kind) { deckConfigOf[id] = cid }
                }
            }
            if try db.tableExists("deck_config") {
                for r in try Row.fetchAll(db, sql: "SELECT id, config FROM deck_config") {
                    let id: Int64 = r["id"]
                    if let blob: Data = r["config"] {
                        let c = AnkiPackage.deckConfig(fromProto: blob)
                        configs[id] = (c.newPerDay, c.reviewsPerDay, c.desiredRetention)
                    }
                }
            }
            if try db.tableExists("config"),
               let v = try Data.fetchOne(db, sql: "SELECT val FROM config WHERE key = 'fsrs'") {
                fsrsOn = String(decoding: v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            }

            // 很旧的集合没有 cards.data 列
            let cardData = try db.columns(in: "cards").contains { $0.name == "data" } ? "c.data" : "'' AS data"
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id AS nid, n.guid, n.mid, n.flds, n.tags,
                       c.id AS cid, c.did, c.type, c.queue, c.due, c.ivl, c.factor, c.reps, c.lapses, \(cardData)
                FROM notes n
                JOIN cards c ON c.nid = n.id
                WHERE c.ord = (SELECT MIN(ord) FROM cards c2 WHERE c2.nid = n.id)
                ORDER BY n.id
                """)

            // 复习记录：只取学习 / 复习 / 重学 / 筛选牌组里的正常评分（排除手动改期等 ease = 0 的记录）
            var revlog: [Int64: [AnkiNote.Revlog]] = [:]
            if try db.tableExists("revlog") {
                for r in try Row.fetchAll(db, sql: "SELECT id, cid, ease FROM revlog WHERE ease BETWEEN 1 AND 4 AND type BETWEEN 0 AND 3 ORDER BY id") {
                    revlog[r["cid"], default: []].append(AnkiNote.Revlog(id: r["id"], ease: r["ease"]))
                }
            }

            return rows.map { r in
                let fields = (r["flds"] as String? ?? "").components(separatedBy: "\u{1f}")
                let mid: Int64 = r["mid"]
                let isCloze = clozeModels.contains(mid)
                let faces = AnkiContent.faces(fields: fields, isClozeModel: isCloze)
                let tags = (r["tags"] as String? ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty }
                let did: Int64 = r["did"]
                let cid: Int64 = r["cid"]
                let schedule = AnkiNote.schedule(
                    type: r["type"], queue: r["queue"], due: r["due"], ivl: r["ivl"], factor: r["factor"],
                    reps: r["reps"], lapses: r["lapses"], collectionCreated: crt, now: now)
                let deck = deckNames[did] ?? "Anki"
                var note = AnkiNote(front: faces.front, back: faces.back, tags: tags,
                                    deck: deck, guid: r["guid"], schedule: schedule)
                note.noteType = modelNames[mid]
                note.fieldNames = modelFields[mid] ?? []
                note.fields = fields
                note.isCloze = isCloze
                note.memory = AnkiNote.memory(fromCardData: r["data"])
                note.revlog = revlog[cid] ?? []
                if let conf = deckConfigOf[did].flatMap({ configs[$0] }) {
                    note.deckOptions = DeckOptions(deck: deck, newPerDay: conf.new, reviewsPerDay: conf.rev,
                                                   algorithm: fsrsOn ? .fsrs : .sm2,
                                                   desiredRetention: conf.retention ?? 0.9)
                } else if fsrsOn {
                    note.deckOptions = DeckOptions(deck: deck, algorithm: .fsrs)
                }
                return note
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
            for f in n.fields { wanted.formUnion(AnkiPackage.mediaReferences(in: f)) }
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
