import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.2.2：打卡天数
//
// 打卡：今日检查中至少做完一组（应做为 0 的组做了任意 1 条也算），并保存了日评（自评分）。打卡后不撤销。
// 6.3.4：改为“日课做完”并保存了日评——摘录、记忆卡、札记·笔记·问题各组都做完，或至少答了一道后点了“收工”；
// 只标注文章不算。这几组今天都没有应做、也没答题时，仍按任意一组做完算（见 DailyCheckinRule）。
// 天数：连续（从今天、今天未打卡则从昨天往前数；休息日不打卡不断，打了照样算）、最长连续、累计、本月、本年。
// 连续中断后不显示“0 天”，改显示本月打卡几天；首页可记一句中断原因（出差、生病、课多、其他），只记录不评判。
// 休息日：每周至多 1 天（默认不设）。每次改动按“自哪天起生效”记下，改设置不改写过去的连续天数。
// 补签：每月 2 次，只能补最近 3 天内、当天确有检查记录但忘了写日评的日子；补写的日评标为“补记”。
// 旧记录：升级时把 5.2.2 之前有回顾或记忆卡记录的日子记为“旧记录”打卡（无自评），连续天数不因升级归零。
// 依据：Silverman 与 Barasch（2023）发现，显示断掉的连续会让人更可能放弃；可以“修复”或归因于外部时，这种影响减弱。

/// 打卡的来源
enum CheckinStatus: String, Codable, Sendable {
    /// 当天做完一组并写了日评
    case checked
    /// 事后补签
    case makeup
    /// 5.2.2 之前有学习记录的日子
    case legacy
}

/// 热力图与悬停说明用的一天
struct CheckinDay: Equatable, Sendable {
    var status: CheckinStatus
    var selfScore: Int?
    var note: String
    var done: Int
    var due: Int
    var mastery: MasteryTally
}

/// 休息日的一次设定：自 from（含）起，每周的 weekday（1 为星期日 … 7 为星期六；nil 为不设）
struct RestDayChange: Codable, Equatable, Sendable {
    var from: String
    var weekday: Int?
}

/// 中断原因
enum StreakBreakReason: String, CaseIterable, Identifiable, Sendable {
    case travel, sick, classes, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .travel: "出差"
        case .sick: "生病"
        case .classes: "课多"
        case .other: "其他"
        }
    }
}

/// 打卡的汇总
struct CheckinSummary: Equatable, Sendable {
    var today = ""
    var todayChecked = false
    /// 今天是休息日
    var todayRest = false
    var current = 0
    var longest = 0
    var total = 0
    var month = 0
    var year = 0
    /// 连续中断时，断在哪一天（最后一次打卡之后第一个既没打卡、也不是休息日的日子）；近 7 天内且还没记原因才给
    var brokenOn: String?
    /// 可以补签的日子（新的在前）与本月还剩几次
    var makeupDays: [String] = []
    var makeupLeft = 0
    var restWeekday: Int?
    var days: [String: CheckinDay] = [:]
    static let empty = CheckinSummary()
}

/// 补签不成的原因
struct CheckinMakeupError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

extension AppDatabase {
    static let restDaysKey = "checkin.restDays"
    static let makeupPerMonth = 2
    static let makeupWindowDays = 3

    // MARK: 迁移

    /// v24：5.2.2 之前有回顾或记忆卡记录的日子记为“旧记录”打卡（不含升级当天）
    static func installCheckinLegacy(in db: Database, now: Date = Date()) throws {
        let today = revisitDay(now)
        var days = Set<String>()
        for at in try Date.fetchAll(db, sql: "SELECT at FROM review_event WHERE kind != 'note'") {
            days.insert(ReminderPlan.dayKey(at))
        }
        for day in days where day < today {
            try db.execute(sql: """
                INSERT INTO daily_checkin(day, status, createdAt, updatedAt) VALUES (?, 'legacy', ?, ?)
                ON CONFLICT(day) DO UPDATE SET status = 'legacy' WHERE status IS NULL
                """, arguments: [day, now, now])
        }
    }

    // MARK: 打卡

    /// 做完一组且写了日评：记为打卡（已打卡、补签、旧记录不动）
    static func evaluateCheckin(_ db: Database, day: String, now: Date) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT status, selfScore, plan FROM daily_checkin WHERE day = ?", arguments: [day]) else { return }
        let status: String? = row["status"]
        let score: Int? = row["selfScore"]
        guard status == nil, score != nil else { return }
        let json: String = row["plan"]
        let plan = (try? JSONDecoder().decode(DailyCheckPlan.self, from: Data(json.utf8))) ?? DailyCheckPlan()
        // 6.3.4：有 lessonDone 的按日课做完看；旧版存下的计划（nil）仍按做完一组看
        guard (plan.lessonDone ?? plan.groupDone) == true else { return }
        try db.execute(sql: "UPDATE daily_checkin SET status = 'checked', updatedAt = ? WHERE day = ?", arguments: [now, day])
    }

    // MARK: 休息日

    func restDayChanges() throws -> [RestDayChange] {
        try progressValue([RestDayChange].self, key: Self.restDaysKey) ?? []
    }

    /// 自今天起把休息日设为每周的 weekday（nil 为不设）；同一天改多次只留最后一次
    func setRestWeekday(_ weekday: Int?, now: Date = Date()) throws {
        let today = Self.revisitDay(now)
        var changes = try restDayChanges().filter { $0.from != today }
        changes.append(RestDayChange(from: today, weekday: weekday))
        try saveProgress(changes.sorted { $0.from < $1.from }, key: Self.restDaysKey)
    }

    /// 某天是否为休息日（按那天生效的设定）
    static func isRestDay(_ day: String, changes: [RestDayChange], calendar: Calendar = .current) -> Bool {
        guard let wd = changes.last(where: { $0.from <= day })?.weekday else { return false }
        return calendar.component(.weekday, from: bounds(day: day, calendar: calendar).0) == wd
    }

    // MARK: 汇总

    func checkinSummary(now: Date = Date()) throws -> CheckinSummary {
        let changes = try restDayChanges()
        return try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return .empty }
            var s = CheckinSummary()
            s.today = Self.revisitDay(now)
            s.restWeekday = changes.last(where: { $0.from <= s.today })?.weekday
            for row in try Row.fetchAll(db, sql: """
                SELECT day, status, selfScore, note, doneCount, dueCount, masteryGood, masteryMid, masteryBad
                FROM daily_checkin WHERE status IS NOT NULL
                """) {
                guard let st = CheckinStatus(rawValue: row["status"]) else { continue }
                s.days[row["day"]] = CheckinDay(status: st, selfScore: row["selfScore"], note: row["note"] ?? "",
                                                done: row["doneCount"] ?? 0, due: row["dueCount"] ?? 0,
                                                mastery: MasteryTally(good: row["masteryGood"] ?? 0, mid: row["masteryMid"] ?? 0, bad: row["masteryBad"] ?? 0))
            }
            func rest(_ d: String) -> Bool { Self.isRestDay(d, changes: changes) }
            func key(_ offset: Int) -> String { Self.revisitDay(now, plus: offset) }
            s.todayChecked = s.days[s.today] != nil
            s.todayRest = rest(s.today)
            s.total = s.days.count
            s.month = s.days.keys.filter { $0.prefix(7) == s.today.prefix(7) }.count
            s.year = s.days.keys.filter { $0.prefix(4) == s.today.prefix(4) }.count
            guard let first = s.days.keys.min() else {
                s.makeupDays = try Self.makeupCandidates(db, s: s, now: now)
                s.makeupLeft = try Self.makeupLeft(db, now: now)
                return s
            }
            // 连续：今天打了从今天数，没打从昨天数；休息日没打跳过
            var offset = s.todayChecked ? 0 : -1
            while true {
                let d = key(offset)
                if d < first { break }
                if s.days[d] != nil { s.current += 1 } else if !rest(d) { break }
                offset -= 1
            }
            // 最长连续：从第一次打卡到今天（今天没打不算断）
            var run = 0, d = first
            var i = 0
            while d <= s.today {
                if s.days[d] != nil { run += 1; s.longest = max(s.longest, run) }
                else if !rest(d) && d != s.today { run = 0 }
                i += 1
                d = Self.revisitDay(Self.bounds(day: first).0, plus: i)
            }
            // 中断：连续为 0 时，最后一次打卡之后第一个没打卡、也不是休息日的日子
            if s.current == 0, let last = s.days.keys.filter({ $0 < s.today }).max() {
                var j = 1
                var missed = Self.revisitDay(Self.bounds(day: last).0, plus: j)
                while missed < s.today && rest(missed) { j += 1; missed = Self.revisitDay(Self.bounds(day: last).0, plus: j) }
                let recorded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streak_break WHERE day = ?", arguments: [missed]) ?? 0
                if missed < s.today, missed >= key(-7), recorded == 0 { s.brokenOn = missed }
            }
            s.makeupDays = try Self.makeupCandidates(db, s: s, now: now)
            s.makeupLeft = try Self.makeupLeft(db, now: now)
            return s
        }
    }

    // MARK: 补签

    /// 本月还能补签几次
    static func makeupLeft(_ db: Database, now: Date) throws -> Int {
        let month = String(revisitDay(now).prefix(7))
        let used = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_checkin WHERE status = 'makeup' AND substr(day, 1, 7) = ?", arguments: [month]) ?? 0
        return max(0, makeupPerMonth - used)
    }

    /// 某天有没有检查记录：今日检查已做、回顾或记忆卡、重温、自测
    static func hadActivity(_ db: Database, day: String) throws -> Bool {
        if (try Int.fetchOne(db, sql: "SELECT doneCount FROM daily_checkin WHERE day = ?", arguments: [day]) ?? 0) > 0 { return true }
        let (start, end) = bounds(day: day)
        func any(_ sql: String) throws -> Bool { (try Int.fetchOne(db, sql: sql, arguments: [start, end]) ?? 0) > 0 }
        if try any("SELECT COUNT(*) FROM review_event WHERE kind != 'note' AND at >= ? AND at < ?") { return true }
        if try any("SELECT COUNT(*) FROM revisit_log WHERE at >= ? AND at < ?") { return true }
        if try db.tableExists("self_test_log"), try any("SELECT COUNT(*) FROM self_test_log WHERE at >= ? AND at < ?") { return true }
        return false
    }

    /// 可以补签的日子：最近 3 天（不含今天）里没打卡、有检查记录的
    static func makeupCandidates(_ db: Database, s: CheckinSummary, now: Date) throws -> [String] {
        guard try makeupLeft(db, now: now) > 0 else { return [] }
        return try (1...makeupWindowDays).map { revisitDay(now, plus: -$0) }
            .filter { s.days[$0] == nil }
            .filter { try hadActivity(db, day: $0) }
    }

    /// 补签：补写那天的日评，记为“补记”
    func makeUpCheckin(day: String, score: SelfScore, note: String, now: Date = Date()) throws {
        try writer.write { db in
            let today = Self.revisitDay(now)
            guard day < today, day >= Self.revisitDay(now, plus: -Self.makeupWindowDays) else {
                throw CheckinMakeupError(message: "只能补最近 \(Self.makeupWindowDays) 天内的日子。")
            }
            let status = try String.fetchOne(db, sql: "SELECT status FROM daily_checkin WHERE day = ?", arguments: [day])
            guard status == nil else { throw CheckinMakeupError(message: "这一天已经打过卡了。") }
            guard try Self.makeupLeft(db, now: now) > 0 else { throw CheckinMakeupError(message: "本月的 \(Self.makeupPerMonth) 次补签已经用完。") }
            guard try Self.hadActivity(db, day: day) else { throw CheckinMakeupError(message: "这一天没有检查记录，不能补签。") }
            let (start, end) = Self.bounds(day: day)
            let m = try Self.mastery(db, start: start, end: end)
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(sql: """
                INSERT INTO daily_checkin(day, status, selfScore, note, masteryGood, masteryMid, masteryBad, createdAt, updatedAt)
                VALUES (?, 'makeup', ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET status = 'makeup', selfScore = excluded.selfScore, note = excluded.note,
                    masteryGood = excluded.masteryGood, masteryMid = excluded.masteryMid, masteryBad = excluded.masteryBad,
                    updatedAt = excluded.updatedAt
                """, arguments: [day, score.rawValue, text, m.good, m.mid, m.bad, now, now])
        }
    }

    // MARK: 中断原因

    func recordStreakBreak(day: String, reason: StreakBreakReason, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO streak_break(day, reason, createdAt) VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET reason = excluded.reason
                """, arguments: [day, reason.rawValue, now])
        }
    }

    /// 某一期的中断原因（复盘用）：原因 → 次数
    func streakBreaks(start: Date, end: Date) throws -> [StreakBreakReason: Int] {
        try writer.read { db in
            var out: [StreakBreakReason: Int] = [:]
            let (from, to) = (Self.revisitDay(start), Self.revisitDay(end))
            for row in try Row.fetchAll(db, sql: "SELECT reason, COUNT(*) AS n FROM streak_break WHERE day >= ? AND day < ? GROUP BY reason", arguments: [from, to]) {
                if let r = StreakBreakReason(rawValue: row["reason"]) { out[r] = row["n"] }
            }
            return out
        }
    }

    /// 某一期打卡的天数（复盘用）
    func checkinDays(start: Date, end: Date) throws -> Int {
        try writer.read { db in
            guard try db.tableExists("daily_checkin") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_checkin WHERE status IS NOT NULL AND day >= ? AND day < ?",
                                    arguments: [Self.revisitDay(start), Self.revisitDay(end)]) ?? 0
        }
    }
}
