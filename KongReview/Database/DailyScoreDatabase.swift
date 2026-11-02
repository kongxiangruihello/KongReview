import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.2.1：日评分
//
// 每天四项，分开显示，另给一个合成总分（只作记录，不设目标线）：
// - 完成度：今日检查的已做 / 应做（5.2.0）。
// - 掌握度：只算考记忆的三类——记忆卡（每张取当天第一次评分：简单、良好为好，困难为中，重来为差）、
//   自测（记得好、大致中、忘了差）、笔记重温（已吸收好、需重读差）。好记 1、中记 0.5、差记 0；不足 5 条不显示。
// - 推进：修订的札记、有线索或写了解答的问题、收藏与弃置的摘录、标为待整理的笔记，只计条数。
// - 自评：1–5 分，加一句话。只能当天写或改，次日起锁定。
// 合成总分（百分制，需先写自评）：完成度 40、掌握度 40、自评 20；缺掌握度时完成度 70、自评 30；
// 缺完成度时掌握度 70、自评 30；两者都缺只看自评。自评 1–5 分折算为 0、0.25、0.5、0.75、1。

/// 自评的五档
enum SelfScore: Int, CaseIterable, Identifiable, Sendable {
    case one = 1, two, three, four, five
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .one: "几乎没进状态"
        case .two: "勉强做完"
        case .three: "平常"
        case .four: "专注顺畅"
        case .five: "心手相应"
        }
    }
    /// 折算到 0–1
    var fraction: Double { Double(rawValue - 1) / 4 }
}

/// 掌握度的好、中、差条数
struct MasteryTally: Equatable, Codable, Sendable {
    var good = 0
    var mid = 0
    var bad = 0
    var total: Int { good + mid + bad }
    /// 不足 5 条不显示
    static let minimum = 5
    var ratio: Double? { total >= Self.minimum ? (Double(good) + 0.5 * Double(mid)) / Double(total) : nil }
    static func + (a: MasteryTally, b: MasteryTally) -> MasteryTally {
        MasteryTally(good: a.good + b.good, mid: a.mid + b.mid, bad: a.bad + b.bad)
    }
}

/// 推进：只计条数
struct ProgressTally: Equatable, Sendable {
    var notesRevised = 0
    var questionsMoved = 0
    var favorited = 0
    var discarded = 0
    var blocksToOrganize = 0
    var total: Int { notesRevised + questionsMoved + favorited + discarded + blocksToOrganize }
    /// 有数的几项，如“修订札记 1 · 问题有进展 2”
    var lines: [String] {
        [("修订札记", notesRevised), ("问题有进展", questionsMoved), ("收藏摘录", favorited),
         ("弃置摘录", discarded), ("笔记待整理", blocksToOrganize)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
    }
}

/// 一天的日评
struct DailyScore: Equatable, Sendable {
    var day: String
    /// 已做 / 应做；当天没有应做为 nil
    var completion: Double?
    var mastery = MasteryTally()
    var progress = ProgressTally()
    var selfScore: SelfScore?
    var note = ""
    /// 当天以外的日评只读
    var locked = false

    /// 合成总分（0–100）；没有自评为 nil
    var total: Int? {
        guard let s = selfScore?.fraction else { return nil }
        let value: Double
        switch (completion, mastery.ratio) {
        case let (c?, m?): value = c * 0.4 + m * 0.4 + s * 0.2
        case let (c?, nil): value = c * 0.7 + s * 0.3
        case let (nil, m?): value = m * 0.7 + s * 0.3
        case (nil, nil): value = s
        }
        return Int((value * 100).rounded())
    }
}

extension AppDatabase {
    // MARK: 统计

    /// 某天的掌握度（从各日志重算，撤销记忆卡评分后自动回退）
    static func mastery(_ db: Database, start: Date, end: Date) throws -> MasteryTally {
        var t = MasteryTally()
        // 记忆卡：每张取当天第一次评分
        let firsts = try Int.fetchAll(db, sql: """
            SELECT e.answer FROM review_event e
            JOIN (SELECT cardId, MIN(at) AS at FROM review_event WHERE kind = 'card' AND at >= ? AND at < ? AND answer IS NOT NULL GROUP BY cardId) f
              ON f.cardId = e.cardId AND f.at = e.at
            WHERE e.kind = 'card' AND e.answer IS NOT NULL
            GROUP BY e.cardId
            """, arguments: [start, end])
        for a in firsts {
            switch CardAnswer(rawValue: a) {
            case .good?, .easy?: t.good += 1
            case .hard?: t.mid += 1
            case .again?: t.bad += 1
            case nil: break
            }
        }
        if try db.tableExists("self_test_log") {
            for r in try Int.fetchAll(db, sql: "SELECT result FROM self_test_log WHERE at >= ? AND at < ?", arguments: [start, end]) {
                switch SelfTestResult(rawValue: r) {
                case .remembered?: t.good += 1
                case .partly?: t.mid += 1
                case .forgot?: t.bad += 1
                case nil: break
                }
            }
        }
        for o in try String.fetchAll(db, sql: "SELECT outcome FROM revisit_log WHERE kind = 'block' AND at >= ? AND at < ?", arguments: [start, end]) {
            if o == RevisitOutcome.absorbed.rawValue { t.good += 1 } else if o == RevisitOutcome.reread.rawValue { t.bad += 1 }
        }
        return t
    }

    /// 某天的推进
    static func progressTally(_ db: Database, start: Date, end: Date) throws -> ProgressTally {
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql, arguments: [start, end]) ?? 0 }
        var p = ProgressTally()
        // 修订的札记：重温时选“要修订”的，加上当天保存时记下修订的（同一条只算一次）
        p.notesRevised = try count("""
            SELECT COUNT(DISTINCT id) FROM (
              SELECT recordId AS id FROM revisit_log WHERE kind = 'note' AND outcome = 'revise' AND at >= ?1 AND at < ?2
              UNION SELECT noteId AS id FROM idea_note_revision WHERE savedAt >= ?1 AND savedAt < ?2)
            """)
        p.questionsMoved = try count("SELECT COUNT(DISTINCT recordId) FROM revisit_log WHERE kind = 'question' AND outcome IN ('lead', 'answer') AND at >= ? AND at < ?")
        p.favorited = try count("SELECT COUNT(DISTINCT highlightId) FROM review_event WHERE kind = 'favorite' AND at >= ? AND at < ?")
        p.discarded = try count("SELECT COUNT(DISTINCT highlightId) FROM review_event WHERE kind = 'discard' AND at >= ? AND at < ?")
        p.blocksToOrganize = try count("SELECT COUNT(DISTINCT recordId) FROM revisit_log WHERE kind = 'block' AND outcome = 'organize' AND at >= ? AND at < ?")
        return p
    }

    // MARK: 读与写

    /// 某天的日评（day 为“yyyy-MM-dd”）。今天以外的为只读。
    func dailyScore(day: String, now: Date = Date()) throws -> DailyScore {
        try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return DailyScore(day: day) }
            let (start, end) = Self.bounds(day: day)
            let row = try Row.fetchOne(db, sql: "SELECT selfScore, note, doneCount, dueCount FROM daily_checkin WHERE day = ?", arguments: [day])
            let due: Int = row?["dueCount"] ?? 0
            let done: Int = row?["doneCount"] ?? 0
            let raw: Int? = row?["selfScore"]
            let note: String = row?["note"] ?? ""
            return DailyScore(day: day,
                              completion: due > 0 ? min(1, Double(done) / Double(due)) : nil,
                              mastery: try Self.mastery(db, start: start, end: end),
                              progress: try Self.progressTally(db, start: start, end: end),
                              selfScore: raw.flatMap(SelfScore.init(rawValue:)),
                              note: note,
                              locked: day != Self.revisitDay(now))
        }
    }

    /// 写今天的自评与一句话。只能写今天；掌握度一并记下快照。
    func saveSelfScore(_ score: SelfScore?, note: String, now: Date = Date()) throws {
        try writer.write { db in
            let day = Self.revisitDay(now)
            let (start, end) = Self.dayBounds(now)
            let m = try Self.mastery(db, start: start, end: end)
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(sql: """
                INSERT INTO daily_checkin(day, selfScore, note, masteryGood, masteryMid, masteryBad, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET selfScore = excluded.selfScore, note = excluded.note,
                    masteryGood = excluded.masteryGood, masteryMid = excluded.masteryMid, masteryBad = excluded.masteryBad,
                    updatedAt = excluded.updatedAt
                """, arguments: [day, score?.rawValue, text, m.good, m.mid, m.bad, now, now])
        }
    }

    /// 写某一天的自评：不是今天就拒绝（次日锁定）
    func saveSelfScore(_ score: SelfScore?, note: String, day: String, now: Date = Date()) throws {
        guard day == Self.revisitDay(now) else { throw DailyScoreLocked() }
        try saveSelfScore(score, note: note, now: now)
    }

    /// 最近几天的日评（旧的在前，含今天）
    func recentDailyScores(days: Int = 7, now: Date = Date()) throws -> [DailyScore] {
        try (0..<days).reversed().map { try dailyScore(day: Self.revisitDay(now, plus: -$0), now: now) }
    }

    /// “yyyy-MM-dd”所指那一天的起止
    static func bounds(day: String, calendar: Calendar = .current) -> (Date, Date) {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return dayBounds(f.date(from: day) ?? Date(), calendar: calendar)
    }
}

/// 写过去某天的自评
struct DailyScoreLocked: LocalizedError {
    var errorDescription: String? { "只能写今天的自评；过去的日评已锁定。" }
}
