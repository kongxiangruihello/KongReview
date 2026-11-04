import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.2：自评准不准
//
// 摘录题、解答题（6.2.2 起也包括记忆卡作答题、札记论证题、笔记复述题）写了“我的回答”的，展开对照时把标准答案切成几处要点，标出写出了几处（IdeaUnits）；
// 判分时把“写出几处 / 共几处”与自己判的分一并记下。判“记得”而要点写出不到一半，记为自评偏高；
// 判“忘了”而写出八成以上，记为自评偏低。只做提示与统计，不改判分、不改排程。

/// 记哪一类题
enum CalibrationKind: String, Sendable {
    case highlight, answer
    /// 6.2.2：记忆卡作答题、札记论证题、笔记复述题
    case card, note, block
}

/// 一期里的自评对照
struct CalibrationTally: Equatable, Sendable {
    /// 写了回答、有要点可对照的题数
    var written = 0
    var over = 0
    var under = 0
    var fair: Int { written - over - under }
    /// 一致的比例（不足 5 道不算）
    var fairRatio: Double? { written >= 5 ? Double(fair) / Double(written) : nil }
}

extension SelfTestResult {
    /// 6.2.2：记忆卡评分折成自评——重来算忘了，困难算大致，良好、简单算记得
    init(card answer: CardAnswer) {
        switch answer {
        case .again: self = .forgot
        case .hard: self = .partly
        case .good, .easy: self = .remembered
        }
    }

    /// 6.2.2：复述题的判定折成自评——已吸收算记得，需重读算忘了，待整理算大致
    init(block outcome: RevisitOutcome) {
        switch outcome {
        case .absorbed: self = .remembered
        case .reread: self = .forgot
        default: self = .partly
        }
    }

    var ideaGrade: IdeaUnits.Grade {
        switch self {
        case .remembered: .remembered
        case .partly: .partly
        case .forgot: .forgot
        }
    }
}

extension AppDatabase {
    /// 迁移 v29
    static func installExamCalibration(in db: Database) throws {
        try db.create(table: "exam_calibration", ifNotExists: true) { t in
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("day", .text).notNull()
            t.column("units", .integer).notNull()
            t.column("hits", .integer).notNull()
            t.column("result", .integer).notNull()
            t.column("at", .datetime).notNull()
            t.primaryKey(["kind", "recordId", "day"])
        }
    }

    /// 记一道题的对照（没有要点的不记；同一天再答以最后一次为准）
    func recordCalibration(kind: CalibrationKind, recordId: Int64, match: IdeaUnitMatch, result: SelfTestResult, now: Date = Date()) throws {
        guard match.total > 0 else { return }
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO exam_calibration(kind, recordId, day, units, hits, result, at) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [kind.rawValue, recordId, Self.revisitDay(now), match.total, match.hits, result.rawValue, now])
        }
    }

    /// 一段时间里的自评对照
    func calibrationTally(start: Date, end: Date) throws -> CalibrationTally {
        try writer.read { db in try Self.calibrationTally(db, start: start, end: end) }
    }

    static func calibrationTally(_ db: Database, start: Date, end: Date) throws -> CalibrationTally {
        guard try db.tableExists("exam_calibration") else { return CalibrationTally() }
        var t = CalibrationTally()
        for row in try Row.fetchAll(db, sql: "SELECT units, hits, result FROM exam_calibration WHERE at >= ? AND at < ?", arguments: [start, end]) {
            let units: Int = row["units"], hits: Int = row["hits"]
            guard units > 0, let result = SelfTestResult(rawValue: row["result"]) else { continue }
            t.written += 1
            switch IdeaUnits.verdict(result.ideaGrade, coverage: Double(hits) / Double(units)) {
            case .over: t.over += 1
            case .under: t.under += 1
            case .fair: break
            }
        }
        return t
    }
}

// MARK: - 6.3：自评偏高的题

/// 最近一次判“记得”而要点写出不到一半的一道题
struct OverconfidentItem: Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue)-\(recordId)" }
    var kind: GradeKind
    var recordId: Int64
    var title: String
    var detail: String
    var hits: Int
    var units: Int
    var at: Date
    var notebookId: Int64?

    /// 打开这道题（与“常错的题”同一条路径）
    var weakItem: WeakItem {
        WeakItem(kind: kind, recordId: recordId, title: title, detail: detail, misses: 0, attempts: 0,
                 lastAt: at, lastMissed: false, notebookId: notebookId)
    }
}

extension AppDatabase {
    static let overconfidentDays = 30

    /// 近 30 天里、最近一次对照是“判记得而要点写出不到一半”的题，新的在前；已删去的不列
    func overconfidentItems(limit: Int = 12, now: Date = Date()) throws -> [OverconfidentItem] {
        let since = now.addingTimeInterval(-Double(Self.overconfidentDays) * 86_400)
        return try writer.read { db in
            guard try db.tableExists("exam_calibration") else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.kind, c.recordId, c.units, c.hits, c.result, c.at FROM exam_calibration c
                WHERE c.at >= ? AND c.at = (SELECT MAX(at) FROM exam_calibration x WHERE x.kind = c.kind AND x.recordId = c.recordId)
                ORDER BY c.at DESC
                """, arguments: [since])
            var out: [OverconfidentItem] = []
            for row in rows {
                let units: Int = row["units"], hits: Int = row["hits"]
                guard units > 0, let result = SelfTestResult(rawValue: row["result"]),
                      IdeaUnits.verdict(result.ideaGrade, coverage: Double(hits) / Double(units)) == .over,
                      let kind = CalibrationKind(rawValue: row["kind"]) else { continue }
                let id: Int64 = row["recordId"]
                var title = "", detail = "", grade = GradeKind.highlight, notebookId: Int64?
                switch kind {
                case .highlight:
                    guard let h = try Row.fetchOne(db, sql: """
                        SELECT h.text, h.location, s.title FROM highlight h LEFT JOIN source s ON s.id = h.sourceId
                        WHERE h.id = ? AND h.deletedAt IS NULL
                        """, arguments: [id]) else { continue }
                    title = Self.gradebookOpening(h["text"])
                    detail = [(h["title"] as String?).map { "《\($0)》" }, h["location"] as String?].compactMap { $0 }.joined(separator: " ")
                case .card:
                    guard let c = try Row.fetchOne(db, sql: "SELECT front, deck FROM card WHERE id = ? AND deletedAt IS NULL", arguments: [id]) else { continue }
                    title = Self.gradebookOpening(c["front"]); detail = c["deck"]; grade = .card
                case .note:
                    guard let n = try Row.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ? AND deletedAt IS NULL", arguments: [id]) else { continue }
                    title = n["title"]; detail = "札记 · 论证题"; grade = .note
                case .block:
                    guard let b = try Row.fetchOne(db, sql: """
                        SELECT b.text, b.notebookId, n.title FROM notebook_block b JOIN notebook n ON n.id = b.notebookId WHERE b.id = ?
                        """, arguments: [id]) else { continue }
                    title = Self.gradebookOpening(Self.blockPlain(b["text"])); detail = "《\(b["title"] as String)》"
                    grade = .block; notebookId = b["notebookId"]
                case .answer:
                    guard let q = try Row.fetchOne(db, sql: "SELECT title FROM question WHERE id = ?", arguments: [id]) else { continue }
                    title = q["title"]; detail = "问题簿 · 解答题"; grade = .question
                }
                out.append(OverconfidentItem(kind: grade, recordId: id, title: title, detail: detail, hits: hits, units: units,
                                             at: row["at"], notebookId: notebookId))
                if out.count >= limit { break }
            }
            return out
        }
    }
}
