import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.8：新录的摘录及早上卷
//
// 每天的摘录题原本从全库按权重抽，新录的一条在大库里可能几个月才第一次出（ReviewScheduler.weight 对新录没有专门的优先）。
// 测试效应（Roediger & Karpicke 2006）与连续再学习都要求读后尽早考一次、隔几天再考：
//   录进来（KongFolio 导入的按导入那天算）的第二天起第 1 次，第 1 次之后隔 2 天起第 2 次；考过两次就回到平常的加权抽样。
// 每天留几个名额（默认 3，设置可改，0 为不留），排在补考之后、占每天摘录题的名额：
// 先出到了第 2 次的，再出最近录的；一次进来很多时每天只出几道，其余往后顺延（30 天内）。
// 30 天内录的才算新录；整篇存进来的文章（原文 ≥ 1000 字）归“今日标注”，不算。

enum ExamFresh {
    static let perDayKey = "exam.freshPerDay"
    static let defaultPerDay = 3
    /// 多少天内录的算新录
    static let windowDays = 30
    /// 第 1 次之后隔几天考第 2 次
    static let secondGapDays = 2
    /// 考几次后回到平常的抽样
    static let rounds = 2
    static let sessionKey = "exam.freshSession"

    static func perDay(_ defaults: UserDefaults = .standard) -> Int {
        max(0, min(10, defaults.object(forKey: perDayKey) as? Int ?? defaultPerDay))
    }

    /// 今天这一组里的新录摘录：编号 → 第几次考
    struct Session: Codable, Equatable, Sendable {
        var day: String
        var rounds: [Int64: Int] = [:]

        static func load(_ defaults: UserDefaults = .standard) -> Session? {
            defaults.data(forKey: sessionKey).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        }

        func save(_ defaults: UserDefaults = .standard) {
            if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: sessionKey) }
        }
    }
}

/// 一条新录的摘录
struct ExamFreshCandidate: Equatable, Sendable {
    var id: Int64
    var enteredAt: Date
    /// 已在卷面上考过几次
    var attempts: Int
    /// 这次是第几次
    var round: Int { attempts + 1 }
}

extension AppDatabase {
    /// 今天该考的新录摘录：到了第 2 次的在前，其余最近录的在前
    func examFreshCandidates(now: Date = Date(), limit: Int, calendar: Calendar = .current) throws -> [ExamFreshCandidate] {
        guard limit > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -ExamFresh.windowDays, to: today) ?? today
        let secondBefore = calendar.date(byAdding: .day, value: -(ExamFresh.secondGapDays - 1), to: today) ?? today
        return try writer.read { db in
            let tests = try db.tableExists("self_test_log")
            let imports = try db.tableExists("kongfolio_item")
            let entered = imports ? "COALESCE(k.importedAt, h.createdAt)" : "h.createdAt"
            let rows = try Row.fetchAll(db, sql: """
                SELECT h.id, \(entered) AS enteredAt,
                       \(tests ? "(SELECT COUNT(*) FROM self_test_log l WHERE l.kind = 'highlight' AND l.setKey = 'exam' AND l.recordId = h.id)" : "0") AS attempts,
                       \(tests ? "(SELECT MAX(at) FROM self_test_log l WHERE l.kind = 'highlight' AND l.setKey = 'exam' AND l.recordId = h.id)" : "NULL") AS lastAt
                FROM highlight h
                \(imports ? "LEFT JOIN (SELECT targetId, MIN(importedAt) AS importedAt FROM kongfolio_item WHERE targetKind = 'highlight' GROUP BY targetId) k ON k.targetId = h.id" : "")
                WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND length(h.text) < ?
                  AND \(entered) >= ? AND \(entered) < ?
                ORDER BY attempts DESC, enteredAt DESC, h.id DESC
                """, arguments: [AnnotateSettings.minimumRawLength, since, today])
            var out: [ExamFreshCandidate] = []
            for row in rows {
                let attempts: Int = row["attempts"]
                guard attempts < ExamFresh.rounds else { continue }
                if attempts > 0 {
                    // 第 2 次：第 1 次之后隔两天起（今天又考过的不算）
                    guard let last: Date = row["lastAt"], last < secondBefore else { continue }
                }
                out.append(ExamFreshCandidate(id: row["id"], enteredAt: row["enteredAt"], attempts: attempts))
                if out.count >= limit { break }
            }
            return out
        }
    }
}
