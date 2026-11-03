import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.5：成绩册
//
// 日评、打卡、回顾统计、个人成长、学习小结与复盘合成一本“成绩册”（设计见“KongReview 6.0 设计方案：考场”第四、七节）：
// - 每日成绩：每天一行——已做 / 应做、完成度、掌握度、总分、自评、一句话、打卡；按月翻。
// - 掌握度走势：近 12 周，按材料分开（记忆卡、摘录、札记、笔记），好记 1、中记 0.5、差记 0，每周不足 5 条不算。
// - 弱项：近 90 天常错的题——摘录题、论证题忘了两次以上或最近一次忘了；记忆卡重来两次以上；笔记两次以上“需重读”或最近一次需重读。
// - 周报、月报：自动汇总这一期的打卡、完成、掌握、总分、新加的题、标注、小胜，与上一期相比；只留写一句话（取代五步复盘）。
// 只读已有的记录，不新增表；一句话存在 app_progress 的 gradebook.remark.<期>。

/// 成绩册里的材料
enum GradeKind: String, CaseIterable, Identifiable, Sendable {
    /// 6.0.9：question——问题簿的解答题
    case card, highlight, note, block, question
    var id: String { rawValue }
    var title: String {
        switch self {
        case .card: "记忆卡"
        case .highlight: "摘录"
        case .note: "札记"
        case .block: "笔记"
        case .question: "问题"
        }
    }
}

/// 每日成绩的一行
struct GradebookDay: Identifiable, Equatable, Sendable {
    var id: String { day }
    var day: String
    var done = 0
    var due = 0
    var score: DailyScore
    var checkin: CheckinStatus?
    var rest = false
    var isToday = false
    var isFuture = false
    /// 这一天有没有任何记录（作答、日评、打卡）
    var isEmpty: Bool { done == 0 && score.mastery.total == 0 && score.selfScore == nil && checkin == nil }
}

/// 一周的掌握度（按材料）
struct MasteryWeek: Identifiable, Equatable, Sendable {
    var id: String { key }
    /// 这一周第一天（yyyy-MM-dd）
    var key: String
    var start: Date
    var tallies: [GradeKind: MasteryTally] = [:]
    var all: MasteryTally { tallies.values.reduce(MasteryTally(), +) }
}

/// 常错的一道题
struct WeakItem: Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue)-\(recordId)" }
    var kind: GradeKind
    var recordId: Int64
    /// 题面（摘录开头、卡片正面、札记题目、笔记开头）
    var title: String
    /// 出处、牌组、笔记本
    var detail: String
    /// 近 90 天错了几次
    var misses: Int
    /// 近 90 天作答几次
    var attempts: Int
    var lastAt: Date
    /// 最近一次是错的
    var lastMissed: Bool
    /// 笔记所在的笔记本（打开用）
    var notebookId: Int64?
}

/// 周报、月报
struct GradebookReport: Equatable, Sendable {
    var key: String
    var period: GrowthPeriod
    var start: Date
    var end: Date
    /// 这一期一共几天（到今天为止）
    var days = 0
    var checkinDays = 0
    var activeDays = 0
    var done = 0
    var due = 0
    var mastery = MasteryTally()
    var byKind: [GradeKind: MasteryTally] = [:]
    /// 有总分的日子的平均分
    var averageTotal: Int?
    var scoredDays = 0
    var bestDay: String?
    var bestTotal: Int?
    var newHighlights = 0
    var newCards = 0
    var newNotes = 0
    var newQuestions = 0
    var annotatedArticles = 0
    var annotationMarks = 0
    var wins: [String] = []
    var winCount = 0
    var breaks: [StreakBreakReason: Int] = [:]
    var completion: Double? { due > 0 ? min(1, Double(done) / Double(due)) : nil }
}

extension AppDatabase {
    static let gradebookWeakDays = 90
    static func gradebookRemarkKey(_ periodKey: String) -> String { "gradebook.remark." + periodKey }

    // MARK: 每日成绩

    /// 某月每天一行（新的在前；未来的日子不列）
    func gradebookMonth(containing date: Date, now: Date = Date(), calendar: Calendar = .current) throws -> [GradebookDay] {
        let interval = calendar.dateInterval(of: .month, for: date)!
        let today = Self.revisitDay(now)
        let changes = try restDayChanges()
        var days: [String] = []
        var d = interval.start
        while d < interval.end {
            let key = Self.revisitDay(d)
            if key <= today { days.append(key) }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        let statuses: [String: CheckinStatus] = try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return [:] }
            var out: [String: CheckinStatus] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, status FROM daily_checkin WHERE status IS NOT NULL AND day >= ? AND day <= ?",
                                        arguments: [days.first ?? today, days.last ?? today]) {
                if let s = CheckinStatus(rawValue: row["status"]) { out[row["day"]] = s }
            }
            return out
        }
        let counts: [String: (Int, Int)] = try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return [:] }
            var out: [String: (Int, Int)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, doneCount, dueCount FROM daily_checkin WHERE day >= ? AND day <= ?",
                                        arguments: [days.first ?? today, days.last ?? today]) {
                out[row["day"]] = (row["doneCount"] ?? 0, row["dueCount"] ?? 0)
            }
            return out
        }
        return try days.reversed().map { key in
            let c = counts[key] ?? (0, 0)
            return GradebookDay(day: key, done: c.0, due: c.1, score: try dailyScore(day: key, now: now),
                                checkin: statuses[key], rest: Self.isRestDay(key, changes: changes), isToday: key == today)
        }
    }

    /// 考场门口的“上次成绩”：今天以前最近一个有记录的日子（30 天内）
    func lastGradedDay(now: Date = Date()) throws -> GradebookDay? {
        let today = Self.revisitDay(now)
        let earliest = Self.revisitDay(now, plus: -30)
        let row: Row? = try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return nil }
            return try Row.fetchOne(db, sql: """
                SELECT day, status, doneCount, dueCount FROM daily_checkin
                WHERE day < ? AND day >= ? AND (status IS NOT NULL OR doneCount > 0 OR selfScore IS NOT NULL)
                ORDER BY day DESC LIMIT 1
                """, arguments: [today, earliest])
        }
        guard let row else { return nil }
        let day: String = row["day"]
        return GradebookDay(day: day, done: row["doneCount"] ?? 0, due: row["dueCount"] ?? 0,
                            score: try dailyScore(day: day, now: now),
                            checkin: (row["status"] as String?).flatMap(CheckinStatus.init(rawValue:)),
                            rest: Self.isRestDay(day, changes: try restDayChanges()))
    }

    // MARK: 掌握度（按材料）

    /// 一段时间里各类材料的掌握度。记忆卡每张每天取第一次评分；摘录题、论证题、笔记按每次作答。
    static func masteryByKind(_ db: Database, start: Date, end: Date, calendar: Calendar = .current) throws -> [GradeKind: MasteryTally] {
        var out: [GradeKind: MasteryTally] = [:]
        // 记忆卡：逐日取每张的第一次评分
        var cards = MasteryTally()
        var d = calendar.startOfDay(for: start)
        while d < end {
            let next = calendar.date(byAdding: .day, value: 1, to: d)!
            let s = max(d, start), e = min(next, end)
            for a in try Int.fetchAll(db, sql: """
                SELECT e.answer FROM review_event e
                JOIN (SELECT cardId, MIN(at) AS at FROM review_event WHERE kind = 'card' AND at >= ? AND at < ? AND answer IS NOT NULL GROUP BY cardId) f
                  ON f.cardId = e.cardId AND f.at = e.at
                WHERE e.kind = 'card' AND e.answer IS NOT NULL
                GROUP BY e.cardId
                """, arguments: [s, e]) {
                switch CardAnswer(rawValue: a) {
                case .good?, .easy?: cards.good += 1
                case .hard?: cards.mid += 1
                case .again?: cards.bad += 1
                case nil: break
                }
            }
            d = next
        }
        out[.card] = cards
        if try db.tableExists("self_test_log") {
            for (kind, recordKind) in [(GradeKind.highlight, "highlight"), (.note, "note"), (.question, "question")] {
                var t = MasteryTally()
                for r in try Int.fetchAll(db, sql: "SELECT result FROM self_test_log WHERE kind = ? AND at >= ? AND at < ?",
                                          arguments: [recordKind, start, end]) {
                    switch SelfTestResult(rawValue: r) {
                    case .remembered?: t.good += 1
                    case .partly?: t.mid += 1
                    case .forgot?: t.bad += 1
                    case nil: break
                    }
                }
                out[kind] = t
            }
        }
        if try db.tableExists("revisit_log") {
            var t = MasteryTally()
            for o in try String.fetchAll(db, sql: "SELECT outcome FROM revisit_log WHERE kind = 'block' AND at >= ? AND at < ?", arguments: [start, end]) {
                if o == RevisitOutcome.absorbed.rawValue { t.good += 1 } else if o == RevisitOutcome.reread.rawValue { t.bad += 1 }
            }
            out[.block] = t
        }
        return out
    }

    /// 近几周的掌握度走势（旧的在前，含本周）
    func masteryTrend(weeks: Int = 12, now: Date = Date(), calendar: Calendar = .current) throws -> [MasteryWeek] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        return try writer.read { db in
            try (0..<weeks).reversed().map { i in
                let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeek)!
                let end = min(calendar.date(byAdding: .weekOfYear, value: 1, to: start)!, now)
                return MasteryWeek(key: Self.revisitDay(start), start: start,
                                   tallies: end > start ? try Self.masteryByKind(db, start: start, end: end, calendar: calendar) : [:])
            }
        }
    }

    // MARK: 弱项

    /// 近 90 天常错的题：错两次以上，或最近一次是错的（按错的次数、再按最近一次排）
    func weakItems(limit: Int = 8, now: Date = Date()) throws -> [GradeKind: [WeakItem]] {
        let since = now.addingTimeInterval(-Double(Self.gradebookWeakDays) * 86_400)
        return try writer.read { db in
            var out: [GradeKind: [WeakItem]] = [:]
            func keep(_ misses: Int, _ lastMissed: Bool) -> Bool { misses >= 2 || (misses >= 1 && lastMissed) }
            func sorted(_ items: [WeakItem]) -> [WeakItem] {
                Array(items.sorted { ($0.misses, $0.lastAt) > ($1.misses, $1.lastAt) }.prefix(limit))
            }
            if try db.tableExists("self_test_log") {
                for (kind, recordKind) in [(GradeKind.highlight, "highlight"), (.note, "note"), (.question, "question")] {
                    var items: [WeakItem] = []
                    for row in try Row.fetchAll(db, sql: """
                        SELECT recordId, SUM(result = 3) AS misses, COUNT(*) AS attempts, MAX(at) AS lastAt,
                               (SELECT result FROM self_test_log l2 WHERE l2.kind = l.kind AND l2.recordId = l.recordId ORDER BY at DESC, id DESC LIMIT 1) AS last
                        FROM self_test_log l WHERE kind = ? AND at >= ? GROUP BY recordId HAVING misses > 0
                        """, arguments: [recordKind, since]) {
                        let misses: Int = row["misses"], last: Int = row["last"]
                        guard keep(misses, last == SelfTestResult.forgot.rawValue) else { continue }
                        let id: Int64 = row["recordId"]
                        var title = "", detail = ""
                        if kind == .highlight {
                            guard let h = try Row.fetchOne(db, sql: """
                                SELECT h.text, h.location, s.title FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                                WHERE h.id = ? AND h.deletedAt IS NULL
                                """, arguments: [id]) else { continue }
                            title = Self.gradebookOpening(h["text"])
                            detail = [(h["title"] as String?).map { "《\($0)》" }, h["location"] as String?].compactMap { $0 }.joined(separator: " ")
                        } else if kind == .question {
                            guard let n = try Row.fetchOne(db, sql: "SELECT title FROM question WHERE id = ? AND status = 'solved'", arguments: [id]) else { continue }
                            title = n["title"]
                            detail = "问题簿 · 解答题"
                        } else {
                            guard let n = try Row.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ? AND deletedAt IS NULL", arguments: [id]) else { continue }
                            title = n["title"]
                            detail = "札记"
                        }
                        items.append(WeakItem(kind: kind, recordId: id, title: title, detail: detail, misses: misses,
                                              attempts: row["attempts"], lastAt: row["lastAt"], lastMissed: last == SelfTestResult.forgot.rawValue))
                    }
                    out[kind] = sorted(items)
                }
            }
            var cards: [WeakItem] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT e.cardId, SUM(e.answer = 1) AS misses, COUNT(*) AS attempts, MAX(e.at) AS lastAt, c.front, c.deck,
                       (SELECT answer FROM review_event e2 WHERE e2.kind = 'card' AND e2.cardId = e.cardId AND e2.answer IS NOT NULL ORDER BY at DESC, id DESC LIMIT 1) AS last
                FROM review_event e JOIN card c ON c.id = e.cardId
                WHERE e.kind = 'card' AND e.answer IS NOT NULL AND e.at >= ? AND c.deletedAt IS NULL
                GROUP BY e.cardId HAVING misses >= 2
                """, arguments: [since]) {
                cards.append(WeakItem(kind: .card, recordId: row["cardId"], title: Self.gradebookOpening(row["front"]), detail: row["deck"],
                                      misses: row["misses"], attempts: row["attempts"], lastAt: row["lastAt"],
                                      lastMissed: (row["last"] as Int?) == CardAnswer.again.rawValue))
            }
            out[.card] = sorted(cards)
            if try db.tableExists("revisit_log") {
                var blocks: [WeakItem] = []
                for row in try Row.fetchAll(db, sql: """
                    SELECT l.recordId, SUM(l.outcome = 'reread') AS misses, COUNT(*) AS attempts, MAX(l.at) AS lastAt,
                           (SELECT outcome FROM revisit_log l2 WHERE l2.kind = 'block' AND l2.recordId = l.recordId ORDER BY at DESC, id DESC LIMIT 1) AS last,
                           b.text, b.notebookId, n.title AS notebookTitle
                    FROM revisit_log l JOIN notebook_block b ON b.id = l.recordId JOIN notebook n ON n.id = b.notebookId
                    WHERE l.kind = 'block' AND l.at >= ? GROUP BY l.recordId HAVING misses > 0
                    """, arguments: [since]) {
                    let misses: Int = row["misses"], last: String = row["last"]
                    guard keep(misses, last == RevisitOutcome.reread.rawValue) else { continue }
                    blocks.append(WeakItem(kind: .block, recordId: row["recordId"], title: Self.gradebookOpening(Self.blockPlain(row["text"])),
                                           detail: "《\(row["notebookTitle"] as String)》", misses: misses, attempts: row["attempts"],
                                           lastAt: row["lastAt"], lastMissed: last == RevisitOutcome.reread.rawValue, notebookId: row["notebookId"]))
                }
                out[.block] = sorted(blocks)
            }
            return out
        }
    }

    /// 题面：去掉标记，取开头 40 字
    nonisolated static func gradebookOpening(_ text: String) -> String {
        let plain = Markdown.plainText(fromHTML: Markdown.richHTML(text))
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > 40 ? String(plain.prefix(40)) + "……" : plain
    }

    // MARK: 周报、月报

    func gradebookReport(_ window: GrowthWindow, now: Date = Date(), calendar: Calendar = .current) throws -> GradebookReport {
        var r = GradebookReport(key: window.key, period: window.period, start: window.start, end: window.end)
        let today = Self.revisitDay(now)
        var d = window.start
        while d < window.fullEnd, Self.revisitDay(d) <= today {
            r.days += 1
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        // 总分要先写自评：只算写了自评的日子（年报不必逐日重算）
        let scored: [String] = try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return [] }
            return try String.fetchAll(db, sql: "SELECT day FROM daily_checkin WHERE selfScore IS NOT NULL AND day >= ? AND day <= ? ORDER BY day",
                                       arguments: [Self.revisitDay(window.start), today])
        }
        var totals: [(String, Int)] = []
        for key in scored where key < Self.revisitDay(window.fullEnd) {
            if let t = try dailyScore(day: key, now: now).total { totals.append((key, t)) }
        }
        if !totals.isEmpty {
            r.scoredDays = totals.count
            r.averageTotal = Int((Double(totals.map(\.1).reduce(0, +)) / Double(totals.count)).rounded())
            if let best = totals.max(by: { a, b in a.1 < b.1 || (a.1 == b.1 && a.0 > b.0) }) { r.bestDay = best.0; r.bestTotal = best.1 }
        }
        let firstDay = Self.revisitDay(window.start)
        let lastDay = Self.revisitDay(window.fullEnd.addingTimeInterval(-1))
        try writer.read { db in
            if try db.tableExists("daily_checkin") {
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(status) AS checked, COALESCE(SUM(doneCount), 0) AS done, COALESCE(SUM(dueCount), 0) AS due,
                           SUM(doneCount > 0) AS active
                    FROM daily_checkin WHERE day >= ? AND day <= ?
                    """, arguments: [firstDay, min(lastDay, today)])
                r.checkinDays = row?["checked"] ?? 0
                r.done = row?["done"] ?? 0
                r.due = row?["due"] ?? 0
                r.activeDays = row?["active"] ?? 0
            }
            r.byKind = try Self.masteryByKind(db, start: window.start, end: window.end, calendar: calendar)
            r.mastery = r.byKind.values.reduce(MasteryTally(), +)
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql, arguments: [window.start, window.end]) ?? 0 }
            r.newHighlights = try count("SELECT COUNT(*) FROM highlight WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL")
            r.newCards = try count("SELECT COUNT(*) FROM card WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL")
            if try db.tableExists("idea_note") {
                r.newNotes = try count("SELECT COUNT(*) FROM idea_note WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL")
            }
            if try db.tableExists("question") {
                r.newQuestions = try count("SELECT COUNT(*) FROM question WHERE createdAt >= ? AND createdAt < ?")
            }
            if try db.tableExists("article_mark") {
                r.annotationMarks = try count("SELECT COUNT(*) FROM article_mark m JOIN highlight h ON h.id = m.markId WHERE h.createdAt >= ? AND h.createdAt < ? AND h.deletedAt IS NULL")
                r.annotatedArticles = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM article_annotation
                    WHERE (lastMarkAt >= ?1 AND lastMarkAt < ?2) OR (finishedAt >= ?1 AND finishedAt < ?2) OR (firstAt >= ?1 AND firstAt < ?2)
                    """, arguments: [window.start, window.end]) ?? 0
            }
        }
        let wins = try progressEvents(start: window.start, end: window.end)
        r.winCount = wins.count
        r.wins = wins.prefix(6).map(\.text)
        r.breaks = try streakBreaks(start: window.start, end: window.end)
        return r
    }

    /// 这一期写下的一句话
    func gradebookRemark(_ periodKey: String) throws -> String {
        try progressValue(String.self, key: Self.gradebookRemarkKey(periodKey)) ?? ""
    }

    func saveGradebookRemark(_ text: String, periodKey: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try deleteProgress(key: Self.gradebookRemarkKey(periodKey)) } else { try saveProgress(t, key: Self.gradebookRemarkKey(periodKey)) }
    }
}
