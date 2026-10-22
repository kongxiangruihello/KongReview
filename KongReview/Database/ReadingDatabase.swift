import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.2.0：书目状态与读书进度
//
// 一个出处加入书架后才有阅读状态（source_reading 一行）：想读 → 在读 → 读完，另有“搁置”；读完后可重读，每一遍的起止留在 reading_pass。
// 进度按页码（书、PDF）、百分比（文章、网页）或已读篇目（古籍）。读书记录 reading_log 按天记：手记一条一行；
// 改进度、录摘录推动进度时自动记，同一书同一天合并为一行（口径同 3.17 的写作量）。

struct SourceReading: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    enum Status: String, Codable, CaseIterable, Identifiable, Sendable {
        case want, reading, finished, paused
        var id: String { rawValue }
        var title: String {
            switch self {
            case .want: "想读"
            case .reading: "在读"
            case .finished: "读完"
            case .paused: "搁置"
            }
        }
        var symbol: String {
            switch self {
            case .want: "bookmark"
            case .reading: "book"
            case .finished: "checkmark.circle"
            case .paused: "pause.circle"
            }
        }
        /// 书架上的排列顺序
        var order: Int {
            switch self {
            case .reading: 0
            case .want: 1
            case .finished: 2
            case .paused: 3
            }
        }
    }

    /// 读法：精读（分析阅读）、泛读（检视阅读）、查阅（工具书）
    enum Depth: String, Codable, CaseIterable, Identifiable, Sendable {
        case close, skim, reference
        var id: String { rawValue }
        var title: String {
            switch self {
            case .close: "精读"
            case .skim: "泛读"
            case .reference: "查阅"
            }
        }
    }

    var sourceId: Int64
    var status: Status
    var depth: Depth?
    var currentPage: Int?
    var totalPages: Int?
    /// 文章、网页按百分比（0–100）
    var percent: Double?
    /// 古籍按篇：已读的篇名
    var chaptersRead: [String] = []
    /// 计划读完的日期
    var targetDate: Date?
    /// 为什么要读（想读时记一句）
    var reason: String = ""
    var rereads: Int = 0
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date

    static let databaseTableName = "source_reading"

    init(sourceId: Int64, status: Status, now: Date = Date()) {
        self.sourceId = sourceId
        self.status = status
        self.updatedAt = now
    }

    /// 进度比例（0–1）；不知道总量时为 nil。chapterTotal：古籍的总篇数
    func fraction(chapterTotal: Int? = nil) -> Double? {
        if let t = totalPages, t > 0, let c = currentPage { return min(1, max(0, Double(c) / Double(t))) }
        if let p = percent { return min(1, max(0, p / 100)) }
        if let n = chapterTotal, n > 0, !chaptersRead.isEmpty { return min(1, Double(chaptersRead.count) / Double(n)) }
        if status == .finished { return 1 }
        return nil
    }

    /// 进度的文字：“第 412／896 页”“第 120 页”“60%”“已读 14 篇”
    var progressText: String {
        if let c = currentPage {
            if let t = totalPages, t > 0 { return "第 \(c)／\(t) 页" }
            return "读到第 \(c) 页"
        }
        if let p = percent { return "\(Int(p.rounded()))%" }
        if !chaptersRead.isEmpty { return "已读 \(chaptersRead.count) 篇" }
        if let t = totalPages, t > 0 { return "共 \(t) 页" }
        return ""
    }

    /// 计划日期前每天大约要读几页（有总页数、当前页与计划日期时）
    func pagesPerDay(today: Date, calendar: Calendar = .current) -> Int? {
        guard status == .reading || status == .want, let target = targetDate, let t = totalPages, t > 0 else { return nil }
        let left = t - (currentPage ?? 0)
        guard left > 0 else { return nil }
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: target)).day ?? 0) + 1
        return days > 0 ? Int((Double(left) / Double(days)).rounded(.up)) : nil
    }
}

/// 一条读书记录
struct ReadingLog: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    enum Origin: String, Codable, Sendable {
        /// 手记
        case manual
        /// 改进度时自动记
        case progress
        /// 录摘录推动进度时自动记
        case highlight
    }
    var id: Int64?
    var sourceId: Int64
    /// 日期键 yyyy-MM-dd（与写作量、学习小结同一口径）
    var day: String
    var fromPage: Int?
    var toPage: Int?
    var percent: Double?
    var minutes: Int?
    var note: String = ""
    var origin: Origin
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "reading_log"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// 这一条读了几页
    var pages: Int { max(0, (toPage ?? 0) - (fromPage ?? toPage ?? 0)) }
}

/// 书架的一行
struct ShelfItem: Identifiable, Equatable, Sendable {
    var source: Source
    var reading: SourceReading
    var lastReadDay: String?
    var highlightCount: Int
    var id: Int64 { reading.sourceId }
}

/// 学习小结：一段时间内的读书
struct ReadingSummary: Equatable, Sendable {
    var days = 0
    var pages = 0
    var finished = 0
}

extension AppDatabase {
    // MARK: 迁移

    /// v20：阅读状态与进度、每一遍的起止、读书记录
    static func installReading(in db: Database) throws {
        try db.create(table: "source_reading") { t in
            t.column("sourceId", .integer).primaryKey().references("source", onDelete: .cascade)
            t.column("status", .text).notNull()
            t.column("depth", .text)
            t.column("currentPage", .integer)
            t.column("totalPages", .integer)
            t.column("percent", .double)
            t.column("chaptersRead", .text).notNull().defaults(to: "[]")
            t.column("targetDate", .datetime)
            t.column("reason", .text).notNull().defaults(to: "")
            t.column("rereads", .integer).notNull().defaults(to: 0)
            t.column("startedAt", .datetime)
            t.column("finishedAt", .datetime)
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "reading_pass") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("sourceId", .integer).notNull().references("source", onDelete: .cascade)
            t.column("startedAt", .datetime)
            t.column("finishedAt", .datetime).notNull()
        }
        try db.create(index: "reading_pass_finished", on: "reading_pass", columns: ["finishedAt"])
        try db.create(table: "reading_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("sourceId", .integer).notNull().references("source", onDelete: .cascade)
            t.column("day", .text).notNull()
            t.column("fromPage", .integer)
            t.column("toPage", .integer)
            t.column("percent", .double)
            t.column("minutes", .integer)
            t.column("note", .text).notNull().defaults(to: "")
            t.column("origin", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(index: "reading_log_source_day", on: "reading_log", columns: ["sourceId", "day"])
        try db.create(index: "reading_log_day", on: "reading_log", columns: ["day"])
    }

    // MARK: 自动记录与进度

    /// 自动记录：同一书同一天的自动记录合并为一行（起页取小、止页取大）
    static func mergeAutoReadingLog(_ db: Database, sourceId: Int64, from: Int?, to: Int?, percent: Double?,
                                    origin: ReadingLog.Origin, now: Date) throws {
        let day = ReminderPlan.dayKey(now)
        if var log = try ReadingLog.fetchOne(db, sql: "SELECT * FROM reading_log WHERE sourceId = ? AND day = ? AND origin != 'manual' ORDER BY id LIMIT 1",
                                             arguments: [sourceId, day]) {
            if let f = from { log.fromPage = min(log.fromPage ?? f, f) }
            if let t = to { log.toPage = max(log.toPage ?? t, t) }
            if let p = percent { log.percent = max(log.percent ?? p, p) }
            log.updatedAt = now
            try log.update(db)
        } else {
            var log = ReadingLog(sourceId: sourceId, day: day, fromPage: from, toPage: to, percent: percent,
                                 origin: origin, createdAt: now, updatedAt: now)
            try log.insert(db)
        }
    }

    /// 录入或修改摘录时：位置里的页码超过当前进度，就把进度推到该页；想读、搁置的书随之变为在读
    static func advanceReading(_ db: Database, for h: Highlight, now: Date) throws {
        guard h.deletedAt == nil, let sid = h.sourceId, let page = SearchSyntax.firstNumber(h.location), page > 0,
              var r = try SourceReading.fetchOne(db, key: sid), r.status != .finished, page > (r.currentPage ?? 0) else { return }
        let from = r.currentPage
        r.currentPage = page
        if r.status != .reading { r.status = .reading; r.startedAt = r.startedAt ?? now }
        r.updatedAt = now
        try r.update(db)
        try mergeAutoReadingLog(db, sourceId: sid, from: from ?? page, to: page, percent: nil, origin: .highlight, now: now)
    }

    // MARK: 写入

    /// 改阅读状态；nil = 移出书架（读书记录保留）。读完记下日期与这一遍；从读完回到在读算重读
    func setReadingStatus(sourceId: Int64, _ status: SourceReading.Status?, now: Date = Date()) throws {
        try writer.write { db in
            guard let status else {
                try db.execute(sql: "DELETE FROM source_reading WHERE sourceId = ?", arguments: [sourceId])
                return
            }
            var r = try SourceReading.fetchOne(db, key: sourceId) ?? SourceReading(sourceId: sourceId, status: .want, now: now)
            let old = try SourceReading.exists(db, key: sourceId) ? r.status : nil
            guard old != status else { return }
            switch status {
            case .want:
                break
            case .reading:
                if old == .finished {
                    // 重读：前一遍已在 reading_pass，进度从头算
                    r.rereads += 1
                    r.startedAt = now; r.finishedAt = nil
                    r.currentPage = nil; r.percent = nil; r.chaptersRead = []
                } else {
                    r.startedAt = r.startedAt ?? now
                }
            case .finished:
                r.startedAt = r.startedAt ?? now
                r.finishedAt = now
                if let t = r.totalPages, t > 0 { r.currentPage = t }
                if r.percent != nil { r.percent = 100 }
                try db.execute(sql: "INSERT INTO reading_pass(sourceId, startedAt, finishedAt) VALUES (?, ?, ?)", arguments: [sourceId, r.startedAt, now])
            case .paused:
                break
            }
            r.status = status
            r.updatedAt = now
            try r.save(db)
        }
    }

    /// 保存读法、进度、总页数、计划日期等；进度往前时自动记一笔，想读的书变为在读
    func saveReading(_ edited: SourceReading, now: Date = Date()) throws {
        try writer.write { db in
            var r = edited
            let old = try SourceReading.fetchOne(db, key: r.sourceId)
            let pageMoved = (r.currentPage ?? 0) > (old?.currentPage ?? 0)
            let percentMoved = (r.percent ?? 0) > (old?.percent ?? 0)
            let chaptersMoved = r.chaptersRead.count > (old?.chaptersRead.count ?? 0)
            if pageMoved || percentMoved || chaptersMoved {
                if r.status == .want || r.status == .paused { r.status = .reading; r.startedAt = r.startedAt ?? now }
                try Self.mergeAutoReadingLog(db, sourceId: r.sourceId, from: pageMoved ? (old?.currentPage ?? r.currentPage) : nil,
                                             to: pageMoved ? r.currentPage : nil, percent: percentMoved ? r.percent : nil,
                                             origin: .progress, now: now)
            }
            r.updatedAt = now
            try r.save(db)
        }
    }

    /// 手记一笔：没上书架的书随之加入书架（在读）；止页超过进度时推进进度
    @discardableResult
    func logReading(sourceId: Int64, day: Date, fromPage: Int?, toPage: Int?, minutes: Int?, note: String, now: Date = Date()) throws -> ReadingLog {
        try writer.write { db in
            var log = ReadingLog(sourceId: sourceId, day: ReminderPlan.dayKey(day), fromPage: fromPage, toPage: toPage, percent: nil,
                                 minutes: minutes, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                 origin: .manual, createdAt: now, updatedAt: now)
            try log.insert(db)
            var r = try SourceReading.fetchOne(db, key: sourceId) ?? SourceReading(sourceId: sourceId, status: .reading, now: now)
            if r.status == .want || r.status == .paused { r.status = .reading }
            if r.status == .reading { r.startedAt = r.startedAt ?? now }
            if let t = toPage, t > (r.currentPage ?? 0), r.status != .finished { r.currentPage = t }
            r.updatedAt = now
            try r.save(db)
            return log
        }
    }

    func deleteReadingLog(id: Int64) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM reading_log WHERE id = ?", arguments: [id]) }
    }

    // MARK: 读取

    func readingStatuses() throws -> [Int64: SourceReading] {
        try writer.read { db in
            Dictionary(try SourceReading.fetchAll(db).map { ($0.sourceId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func reading(sourceId: Int64) throws -> SourceReading? {
        try writer.read { db in try SourceReading.fetchOne(db, key: sourceId) }
    }

    /// 书架：书架上的全部出处，带最后读的日期与摘录数
    func shelf() async throws -> [ShelfItem] {
        try await writer.read { db in
            let readings = try SourceReading.fetchAll(db)
            guard !readings.isEmpty else { return [] }
            let sources = Dictionary(try Source.fetchAll(db).compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
            let last = Dictionary(try Row.fetchAll(db, sql: "SELECT sourceId, MAX(day) AS d FROM reading_log GROUP BY sourceId")
                .map { ($0["sourceId"] as Int64, $0["d"] as String) }, uniquingKeysWith: { a, _ in a })
            let counts = Dictionary(try Row.fetchAll(db, sql: "SELECT sourceId, COUNT(*) AS n FROM highlight WHERE deletedAt IS NULL AND sourceId IS NOT NULL GROUP BY sourceId")
                .map { ($0["sourceId"] as Int64, $0["n"] as Int) }, uniquingKeysWith: { a, _ in a })
            return readings.compactMap { r in
                sources[r.sourceId].map { ShelfItem(source: $0, reading: r, lastReadDay: last[r.sourceId], highlightCount: counts[r.sourceId] ?? 0) }
            }
        }
    }

    func readingLogs(sourceId: Int64, limit: Int = 30) throws -> [ReadingLog] {
        try writer.read { db in
            try ReadingLog.fetchAll(db, sql: "SELECT * FROM reading_log WHERE sourceId = ? ORDER BY day DESC, id DESC LIMIT ?", arguments: [sourceId, limit])
        }
    }

    /// 一段时间内的读书：有记录的天数、页数、读完的本数（一书读完两遍算两本）
    func readingSummary(start: Date, end: Date) async throws -> ReadingSummary {
        let lo = ReminderPlan.dayKey(start), hi = ReminderPlan.dayKey(end)
        return try await writer.read { db in
            let days = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT day) FROM reading_log WHERE day >= ? AND day < ?", arguments: [lo, hi]) ?? 0
            let pages = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(MAX(0, COALESCE(toPage, 0) - COALESCE(fromPage, toPage, 0))), 0) FROM reading_log WHERE day >= ? AND day < ?
                """, arguments: [lo, hi]) ?? 0
            let finished = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_pass WHERE finishedAt >= ? AND finishedAt < ?", arguments: [start, end]) ?? 0
            return ReadingSummary(days: days, pages: pages, finished: finished)
        }
    }

    /// 读完不到 7 天的书（回顾加权）
    static func recentlyFinishedSourceIDs(_ db: Database, now: Date) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT sourceId FROM source_reading WHERE status = 'finished' AND finishedAt >= ?",
                           arguments: [now.addingTimeInterval(-7 * 86_400)])
    }
}
