import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.0.1：复盘——每周五步，月度、年度
//
// 每周：① 看数字 ② 看新材料 ③ 看自己的想法 ④ 过一遍常念问题 ⑤ 写三句话（收获、困难、下一步）。
// 月度同上，数字与材料按月；年度另加“观点的变化”（今年修订过的札记，年初或初写时与现在并排）与“一年的问题”。
// 三句话与学习小结的“复盘”是同一份（app_progress 中 GrowthReflection，键为周期的 key）；
// 复盘走到哪一步、是否完成另存在 app_progress“reflection.<周期 key>”。不新增表。

/// 复盘的一步
enum ReflectionStep: String, Codable, CaseIterable, Identifiable, Sendable {
    case numbers, materials, thoughts, questions, views, sentences
    var id: String { rawValue }
    var title: String {
        switch self {
        case .numbers: "看数字"
        case .materials: "看新材料"
        case .thoughts: "看自己的想法"
        case .questions: "过一遍常念问题"
        case .views: "观点的变化"
        case .sentences: "写三句话"
        }
    }
    static func steps(for period: GrowthPeriod) -> [ReflectionStep] {
        period == .year ? [.numbers, .materials, .thoughts, .questions, .views, .sentences]
                        : [.numbers, .materials, .thoughts, .questions, .sentences]
    }
}

/// 复盘的进度：走到第几步、看过哪几步、何时完成
struct ReflectionProgress: Codable, Equatable, Sendable {
    var step = 0
    var visited: [Int] = []
    var completedAt: Date?
    static func key(_ window: GrowthWindow) -> String { "reflection." + window.key }
}

/// 第一步：一项数字与上期同期
struct ReflectionNumber: Identifiable, Equatable, Sendable {
    var title: String
    var now: Int
    var before: Int
    var id: String { title }
}

/// 第三步：本期新写、本期修订、重温时说要修订而还没改的札记
struct ReflectionThoughts: Equatable, Sendable {
    struct Revised: Identifiable, Equatable, Sendable {
        var ref: IdeaNoteRef
        var times: Int
        var id: Int64 { ref.id }
    }
    var created: [IdeaNoteRef] = []
    var revised: [Revised] = []
    var pendingRevision: [IdeaNoteRef] = []
}

/// 第四步：常念的问题（本期新挂的材料数）、本期解决的、可标为常念的；年度另有新记、解决、仍在心上的个数
struct ReflectionQuestions: Equatable, Sendable {
    struct Pinned: Identifiable, Equatable, Sendable {
        var ref: QuestionRef
        var newMaterials: Int
        var id: Int64 { ref.id }
    }
    var pinned: [Pinned] = []
    var solved: [QuestionRef] = []
    var candidates: [QuestionRef] = []
    var created = 0
    var solvedCount = 0
    var stillOpen = 0
    /// 常念超过这个数时提醒精简
    static let pinnedLimit = 12
}

/// 年度“观点的变化”：一条札记年初（或初写时）与现在
struct ViewChange: Identifiable, Equatable, Sendable {
    var id: Int64
    var beforeTitle: String
    var beforeBody: String
    var nowTitle: String
    var nowBody: String
    var revisions: Int
}

extension AppDatabase {
    // MARK: 进度

    func reflectionProgress(_ window: GrowthWindow) throws -> ReflectionProgress {
        try progressValue(ReflectionProgress.self, key: ReflectionProgress.key(window)) ?? ReflectionProgress()
    }

    func saveReflectionProgress(_ p: ReflectionProgress, window: GrowthWindow) throws {
        try saveProgress(p, key: ReflectionProgress.key(window))
    }

    /// 某类周期最近一次完成复盘的时间
    func lastReflection(period: GrowthPeriod) throws -> Date? {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM app_progress WHERE key LIKE ?", arguments: ["reflection.growth.\(period.rawValue).%"])
                .compactMap { try? JSONDecoder().decode(ReflectionProgress.self, from: $0).completedAt }
                .max()
        }
    }

    func reflectionCompleted(_ window: GrowthWindow) -> Bool {
        ((try? reflectionProgress(window))?.completedAt) != nil
    }

    // MARK: 第一步：数字

    func reflectionNumbers(_ window: GrowthWindow) async throws -> [ReflectionNumber] {
        async let a = growthSummary(start: window.start, end: window.end)
        async let b = growthSummary(start: window.previousStart, end: window.previousEnd)
        let (now, before) = try await (a, b)
        let notesNow = try await ideaNotesCreated(start: window.start, end: window.end)
        let notesBefore = try await ideaNotesCreated(start: window.previousStart, end: window.previousEnd)
        let revisitedNow = try await notesRevisited(start: window.start, end: window.end)
        let revisitedBefore = try await notesRevisited(start: window.previousStart, end: window.previousEnd)
        let solvedNow = try await questionsSolved(start: window.start, end: window.end)
        let solvedBefore = try await questionsSolved(start: window.previousStart, end: window.previousEnd)
        let writingNow = try await writingSummary(start: window.start, end: window.end)
        let writingBefore = try await writingSummary(start: window.previousStart, end: window.previousEnd)
        return [
            ReflectionNumber(title: "回顾摘录（条）", now: now[.highlights], before: before[.highlights]),
            ReflectionNumber(title: "学习记忆卡（张）", now: now[.cards], before: before[.cards]),
            ReflectionNumber(title: "新录摘录（条）", now: now[.newHighlights], before: before[.newHighlights]),
            ReflectionNumber(title: "新写札记（条）", now: notesNow, before: notesBefore),
            ReflectionNumber(title: "重温札记（条）", now: revisitedNow, before: revisitedBefore),
            ReflectionNumber(title: "解决问题（个）", now: solvedNow, before: solvedBefore),
            ReflectionNumber(title: "写作（字）", now: writingNow.added, before: writingBefore.added),
        ]
    }

    // MARK: 第三步：自己的想法

    func reflectionThoughts(start: Date, end: Date) throws -> ReflectionThoughts {
        try writer.read { db in
            var t = ReflectionThoughts()
            t.created = try Row.fetchAll(db, sql: """
                SELECT id, title FROM idea_note WHERE deletedAt IS NULL AND createdAt >= ? AND createdAt < ? ORDER BY createdAt DESC, id DESC
                """, arguments: [start, end]).map { IdeaNoteRef(id: $0["id"], title: $0["title"]) }
            t.revised = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, COUNT(*) AS times FROM idea_note_revision r JOIN idea_note n ON n.id = r.noteId AND n.deletedAt IS NULL
                WHERE r.savedAt >= ? AND r.savedAt < ? GROUP BY n.id ORDER BY MAX(r.savedAt) DESC
                """, arguments: [start, end]).map { ReflectionThoughts.Revised(ref: IdeaNoteRef(id: $0["id"], title: $0["title"]), times: $0["times"]) }
            // 最近一次重温选了“要修订”、之后还没改过的
            t.pendingRevision = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title FROM idea_note n
                JOIN (SELECT recordId, MAX(at) AS at FROM revisit_log WHERE kind = 'note' GROUP BY recordId) last ON last.recordId = n.id
                JOIN revisit_log l ON l.kind = 'note' AND l.recordId = n.id AND l.at = last.at AND l.outcome = 'revise'
                WHERE n.deletedAt IS NULL AND n.updatedAt <= last.at ORDER BY last.at
                """).map { IdeaNoteRef(id: $0["id"], title: $0["title"]) }
            return t
        }
    }

    // MARK: 第四步：问题

    func reflectionQuestions(start: Date, end: Date) throws -> ReflectionQuestions {
        try writer.read { db in
            var q = ReflectionQuestions()
            func ref(_ row: Row) -> QuestionRef {
                QuestionRef(id: row["id"], title: row["title"], status: Question.Status(rawValue: row["status"]) ?? .open, pinned: row["pinned"])
            }
            q.pinned = try Row.fetchAll(db, sql: """
                SELECT q.id, q.title, q.status, q.pinned,
                       (SELECT COUNT(*) FROM question_material m WHERE m.questionId = q.id AND m.addedAt >= ? AND m.addedAt < ?) AS fresh
                FROM question q WHERE q.pinned = 1 AND q.status IN ('open', 'lead') ORDER BY fresh DESC, q.updatedAt DESC, q.id
                """, arguments: [start, end]).map { ReflectionQuestions.Pinned(ref: ref($0), newMaterials: $0["fresh"]) }
            q.solved = try Row.fetchAll(db, sql: """
                SELECT id, title, status, pinned FROM question WHERE status = 'solved' AND solvedAt >= ? AND solvedAt < ? ORDER BY solvedAt DESC
                """, arguments: [start, end]).map(ref)
            q.candidates = try Row.fetchAll(db, sql: """
                SELECT id, title, status, pinned FROM question WHERE pinned = 0 AND status IN ('open', 'lead') ORDER BY updatedAt DESC, id DESC LIMIT 8
                """).map(ref)
            q.created = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question WHERE createdAt >= ? AND createdAt < ?", arguments: [start, end]) ?? 0
            q.solvedCount = try Self.questionsSolved(db, start: start, end: end)
            q.stillOpen = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM question WHERE createdAt >= ? AND createdAt < ? AND status IN ('open', 'lead')
                """, arguments: [start, end]) ?? 0
            return q
        }
    }

    /// 年度“一年的问题”：新记、解决、仍在心上的问题，导出为 Markdown
    func questionsYearMarkdown(_ window: GrowthWindow) throws -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        return try writer.read { db in
            let year = Calendar.current.component(.year, from: window.start)
            var lines = ["# \(year) 年的问题", "",
                         "\(f.string(from: window.start)) — \(f.string(from: window.end.addingTimeInterval(-1)))", ""]
            let solved = try Row.fetchAll(db, sql: """
                SELECT title, answer, answerNoteId, solvedAt FROM question WHERE status = 'solved' AND solvedAt >= ? AND solvedAt < ? ORDER BY solvedAt
                """, arguments: [window.start, window.end])
            lines += ["## 解决的问题（\(solved.count)）", ""]
            for row in solved {
                lines.append("- **\(row["title"] as String)**（\(f.string(from: row["solvedAt"] as Date))）")
                var answer = Markdown.plainText(fromHTML: row["answer"] as String).trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty, let nid = row["answerNoteId"] as Int64?,
                   let t = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [nid]) { answer = "见札记《\(t)》" }
                if !answer.isEmpty { lines.append("  " + answer.replacingOccurrences(of: "\n", with: "\n  ")) }
            }
            let open = try Row.fetchAll(db, sql: """
                SELECT title, status, pinned FROM question WHERE status IN ('open', 'lead') ORDER BY pinned DESC, updatedAt DESC
                """)
            lines += ["", "## 仍在心上的问题（\(open.count)）", ""]
            for row in open {
                let status = Question.Status(rawValue: row["status"])?.title ?? ""
                lines.append("- \(row["title"] as String)（\(status)\((row["pinned"] as Bool) ? "，常念" : "")）")
            }
            let created = try String.fetchAll(db, sql: "SELECT title FROM question WHERE createdAt >= ? AND createdAt < ? ORDER BY createdAt",
                                              arguments: [window.start, window.end])
            lines += ["", "## 今年新记的问题（\(created.count)）", ""]
            lines += created.map { "- " + $0 }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    // MARK: 年度：观点的变化

    /// 本期修订过的札记：期初（期间才写的取初写时）与现在
    func viewChanges(start: Date, end: Date, limit: Int = 50) throws -> [ViewChange] {
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.body, COUNT(*) AS times FROM idea_note_revision r JOIN idea_note n ON n.id = r.noteId AND n.deletedAt IS NULL
                WHERE r.savedAt >= ? AND r.savedAt < ? GROUP BY n.id ORDER BY COUNT(*) DESC, MAX(r.savedAt) DESC LIMIT ?
                """, arguments: [start, end, limit])
        }
        return try rows.compactMap { row in
            let id: Int64 = row["id"]
            guard let before = try ideaNoteVersion(noteId: id, at: start) else { return nil }
            return ViewChange(id: id, beforeTitle: before.title, beforeBody: before.body, nowTitle: row["title"], nowBody: row["body"], revisions: row["times"])
        }
    }

    // MARK: 完成

    func completeReflection(_ window: GrowthWindow, now: Date = Date()) throws {
        var p = try reflectionProgress(window)
        p.completedAt = now
        p.visited = Array(Set(p.visited + Array(0..<ReflectionStep.steps(for: window.period).count))).sorted()
        try saveReflectionProgress(p, window: window)
    }

    /// 首页“本周复盘”要指向哪一周：本周；若本周刚开始（前三天）而上周还没复盘，指向上周
    func reflectionTargetWeek(now: Date = Date(), calendar: Calendar = .current) -> GrowthWindow {
        let current = GrowthPeriod.week.window(containing: now, now: now, calendar: calendar)
        guard !reflectionCompleted(current) else { return current }
        let days = calendar.dateComponents([.day], from: current.start, to: calendar.startOfDay(for: now)).day ?? 0
        if days < 3 {
            let previous = GrowthPeriod.week.window(containing: current.previousStart, now: now, calendar: calendar)
            if !reflectionCompleted(previous) { return previous }
        }
        return current
    }
}

// MARK: - 每周复盘提醒

enum ReflectionReminderPlan {
    static let enabledKey = "reflection.reminderEnabled"
    static let weekdayKey = "reflection.reminderWeekday"
    static let hourKey = "reflection.reminderHour"
    static let minuteKey = "reflection.reminderMinute"
    static let prefix = "kongreview.reflection."

    /// 之后几次提醒的时间（weekday：1 为星期日）；提醒的那一周已复盘就跳过。
    /// 提醒所对应的“那一周”取提醒时刻前一天所在的周，星期日为一周之首或之末都对得上。
    static func fires(now: Date, weekday: Int, hour: Int, minute: Int, count: Int = 4,
                      calendar: Calendar = .current, completed: (GrowthWindow) -> Bool) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        var guardCount = 0
        while out.count < count && guardCount < 7 * (count + 2) {
            guardCount += 1
            if calendar.component(.weekday, from: day) == weekday,
               let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire > now,
               !completed(targetWeek(for: fire, calendar: calendar)) {
                out.append(fire)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return out
    }

    static func targetWeek(for fire: Date, calendar: Calendar = .current) -> GrowthWindow {
        let d = calendar.date(byAdding: .day, value: -1, to: fire) ?? fire
        return GrowthPeriod.week.window(containing: d, now: fire, calendar: calendar)
    }
}
