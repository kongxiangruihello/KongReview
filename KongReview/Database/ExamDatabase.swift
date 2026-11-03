import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.3：今日试卷
//
// 今日检查、今日回顾、记忆卡学习、重温、每周自测合成一张卷子、一个入口：
//   记忆卡——作答题（正面 → 背面，重来 / 困难 / 良好 / 简单，FSRS 不变）；
//   摘录——要点题（给出处、位置与按语，想原文）与出处题（给原文，想出处）轮换，记得 / 大致 / 忘了；
//   札记——论证题（给题目，想理由与依据），记得 / 大致 / 忘了，再问一句“还这么看吗”；
//   问题——进展题（先写一句现在的答案或线索），有新线索 / 写解答 / 还没有；
//   笔记——复述题（给笔记本、小标题与开头几个字），已吸收 / 需重读 / 待整理。
// 各类按自己的到期日出题（摘录沿用每天的加权抽样），卷面上交错排列。
// 摘录与札记的“记得 / 大致 / 忘了”记在 self_test_log（setKey = "exam"），计入掌握度；
// 忘了的摘录 2 天后起优先回到卷子上（“补考”，30 天内、每天至多 3 条，占每日条数的名额）。

/// 卷子上的五类题
enum ExamKind: String, CaseIterable, Codable, Sendable {
    case card, highlight, note, block, question

    var title: String {
        switch self {
        case .card: "记忆卡"
        case .highlight: "摘录"
        case .note: "札记"
        case .block: "笔记"
        case .question: "问题"
        }
    }

    var questionTitle: String {
        switch self {
        case .card: "作答题"
        case .highlight: "摘录题"
        case .note: "论证题"
        case .block: "复述题"
        case .question: "进展题"
        }
    }

    var symbol: String {
        switch self {
        case .card: "brain"
        case .highlight: "text.quote"
        case .note: "lightbulb"
        case .block: "book.closed"
        case .question: "questionmark.bubble"
        }
    }
}

/// 交错出题：从上一题的下一类起，轮到第一类还有题的
enum ExamRotation {
    static let order: [ExamKind] = [.card, .highlight, .note, .card, .highlight, .block, .question]

    /// - Parameters:
    ///   - turn: 轮到第几位（每答一题加一）
    ///   - available: 此刻还有题的各类
    /// - Returns: 这一题出哪一类，以及出过之后的下一位
    static func next(turn: Int, available: Set<ExamKind>) -> (kind: ExamKind, turn: Int)? {
        guard !available.isEmpty else { return nil }
        let n = order.count
        for step in 0..<n {
            let i = ((turn % n) + n + step) % n
            if available.contains(order[i]) { return (order[i], i + 1) }
        }
        return nil
    }
}

/// 摘录题的出法
enum ExamHighlightMode: Equatable, Sendable {
    /// 要点题：给出处、位置与按语，想原文
    case gist
    /// 出处题：给原文，想出处
    case source
    /// 没有出处的摘录：给开头几个字（与按语、标签），想全文
    case opening

    /// 有出处且有位置或按语的，按日期与编号在要点题、出处题之间轮换；只有出处的考出处；没有出处的给开头
    static func pick(for h: Highlight, day: Date, calendar: Calendar = .current) -> ExamHighlightMode {
        guard h.sourceId != nil else { return .opening }
        let hasCue = !(h.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !Markdown.plainText(fromHTML: Markdown.richHTML(h.note ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCue else { return .source }
        let dayIndex = Int(calendar.startOfDay(for: day).timeIntervalSince1970 / 86_400)
        return ((h.id ?? 0) + Int64(dayIndex)) % 2 == 0 ? .gist : .source
    }

    var title: String {
        switch self {
        case .gist: "要点题"
        case .source: "出处题"
        case .opening: "要点题"
        }
    }
}

extension AppDatabase {
    static let examSetKey = "exam"
    /// 忘了的摘录几天后开始补考、多少天内还补、每天至多几条
    static let examRetestAfterDays = 2
    static let examRetestWithinDays = 30
    static let examRetestPerDay = 3

    /// 今天该补考的摘录：最近一次卷面作答是“忘了”，在 2–30 天前，摘录仍在且未弃置；最早忘的在前
    func examRetestHighlightIDs(now: Date = Date(), limit: Int = AppDatabase.examRetestPerDay) throws -> [Int64] {
        guard limit > 0 else { return [] }
        let start = Calendar.current.startOfDay(for: now)
        let latest = start.addingTimeInterval(-Double(Self.examRetestAfterDays - 1) * 86_400)
        let earliest = start.addingTimeInterval(-Double(Self.examRetestWithinDays) * 86_400)
        return try writer.read { db in
            guard try db.tableExists("self_test_log") else { return [] }
            return try Int64.fetchAll(db, sql: """
                SELECT l.recordId FROM self_test_log l
                JOIN (SELECT recordId, MAX(at) AS at FROM self_test_log WHERE kind = 'highlight' GROUP BY recordId) m
                  ON m.recordId = l.recordId AND m.at = l.at
                JOIN highlight h ON h.id = l.recordId
                WHERE l.kind = 'highlight' AND l.result = ? AND l.at < ? AND l.at >= ?
                  AND h.deletedAt IS NULL AND h.isDiscarded = 0
                ORDER BY l.at LIMIT ?
                """, arguments: [SelfTestResult.forgot.rawValue, latest, earliest, limit])
        }
    }

    /// 记一道摘录题或论证题的“记得 / 大致 / 忘了”。同一天同一条再答以最后一次为准；
    /// 上一次（以前某天）是“忘了”、这次“记得”时记一件小胜。
    func recordExamResult(kind: SelfTestKind, recordId: Int64, result: SelfTestResult, now: Date = Date()) throws {
        let (start, end) = Self.dayBounds(now)
        try writer.write { db in
            let previous = try Int.fetchOne(db, sql: "SELECT result FROM self_test_log WHERE kind = ? AND recordId = ? AND at < ? ORDER BY at DESC LIMIT 1",
                                            arguments: [kind.recordKind, recordId, start])
            try db.execute(sql: "DELETE FROM self_test_log WHERE setKey = ? AND kind = ? AND recordId = ? AND at >= ? AND at < ?",
                           arguments: [Self.examSetKey, kind.recordKind, recordId, start, end])
            try db.execute(sql: "INSERT INTO self_test_log(setKey, kind, recordId, result, at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [Self.examSetKey, kind.recordKind, recordId, result.rawValue, now])
            if previous == SelfTestResult.forgot.rawValue, result == .remembered {
                let detail: String
                if kind == .argument {
                    detail = "札记《" + (try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [recordId]) ?? "") + "》"
                } else {
                    let text = try String.fetchOne(db, sql: "SELECT text FROM highlight WHERE id = ?", arguments: [recordId]) ?? ""
                    detail = String(Markdown.plainText(fromHTML: Markdown.richHTML(text)).prefix(24))
                }
                try Self.recordProgress(db, .selfTestRecovered, recordId: recordId, detail: detail, now: now)
            }
        }
    }

    /// 今天卷面上各类的作答数（摘录题、论证题按“记得 / 大致 / 忘了”）
    func examTally(now: Date = Date()) throws -> MasteryTally {
        let (start, end) = Self.dayBounds(now)
        return try writer.read { db in
            var t = MasteryTally()
            guard try db.tableExists("self_test_log") else { return t }
            for r in try Int.fetchAll(db, sql: "SELECT result FROM self_test_log WHERE setKey = ? AND at >= ? AND at < ?",
                                      arguments: [Self.examSetKey, start, end]) {
                switch SelfTestResult(rawValue: r) {
                case .remembered?: t.good += 1
                case .partly?: t.mid += 1
                case .forgot?: t.bad += 1
                case nil: break
                }
            }
            return t
        }
    }
}
