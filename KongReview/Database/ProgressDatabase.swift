import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.0.2：检测与激励
//
// 检测：每周一组自测（出处题、要点题、论证题各若干，共 10 题），自评 1 记得、2 大致、3 忘了，记在 self_test_log；
// 检视：月度、年度复盘里的“学问检视”表（记得多少、想得多深、问题进展、久未触及）。
// 激励：自动记下的小胜（progress_event）——问题有了线索或解决、札记修订、札记第一次被另一条链接、第一次引用某本书、
// 自测从“忘了”到“记得”；首页“本周进展”、功课做完时的“今日收获”、问题页的“经过”都从这里取。
// 升级时把已有的解决、链接、引用记为“底账”（quiet = 1，不显示），免得升级当天冒出一批旧事。

/// 自测题型
enum SelfTestKind: String, Codable, CaseIterable, Sendable {
    /// 显示摘录原文、隐去出处：想起书名、作者、大致位置
    case source
    /// 显示出处、位置与按语、隐去原文：想起原文说了什么
    case gist
    /// 显示札记题目：想起理由与依据的摘录
    case argument
    var title: String {
        switch self {
        case .source: "出处题"
        case .gist: "要点题"
        case .argument: "论证题"
        }
    }
    var recordKind: String { self == .argument ? "note" : "highlight" }
}

/// 一道自测题
struct SelfTestItem: Codable, Equatable, Hashable, Sendable {
    var kind: SelfTestKind
    var recordId: Int64
}

/// 一周的自测：题目在第一次打开时抽定，存在 app_progress“selftest.<周 key>”
struct SelfTestSet: Codable, Equatable, Sendable {
    var items: [SelfTestItem] = []
    var createdAt = Date()
    static func key(_ week: GrowthWindow) -> String { "selftest." + week.key }
}

/// 自评
enum SelfTestResult: Int, Codable, Sendable {
    case remembered = 1, partly = 2, forgot = 3
    var title: String {
        switch self {
        case .remembered: "记得"
        case .partly: "大致"
        case .forgot: "忘了"
        }
    }
}

/// 小胜
enum ProgressKind: String, Codable, Sendable {
    case questionLead, questionSolved, noteRevised, noteLinked, sourceCited, selfTestRecovered
    /// 5.1：读完一本书（同一本只记一次）
    case bookFinished
}

struct ProgressEvent: Identifiable, Equatable, Sendable {
    var id: Int64
    var kind: ProgressKind
    var recordId: Int64
    var detail: String
    var at: Date
    /// 给人看的一句
    var text: String {
        switch kind {
        case .questionLead: "问题《\(detail)》有了线索"
        case .questionSolved: "解决了问题《\(detail)》"
        case .noteRevised: "修订了札记《\(detail)》"
        case .noteLinked: "札记《\(detail)》第一次被另一条札记链接"
        case .sourceCited: "第一次在札记中引用《\(detail)》"
        case .selfTestRecovered: "自测：从“忘了”到“记得”——\(detail)"
        case .bookFinished: "读完了《\(detail)》"
        }
    }
}

/// 学问检视（月度、年度复盘）
struct Inspection: Equatable, Sendable {
    var tested = 0
    var remembered = 0
    var rememberedRate: Double? { tested > 0 ? Double(remembered) / Double(tested) : nil }
    var cardRetention: Double?
    var notes = 0
    var avgCited = 0.0
    var avgBacklinks = 0.0
    var revisedNotes = 0
    var open = 0
    var lead = 0
    var solved = 0
    var solvedInPeriod = 0
    var avgDaysToSolve: Double?
    var untouchedNotes: [IdeaNoteRef] = []
    var untouchedNoteCount = 0
    var untouchedSources = 0
}

/// 问题的经过（问题页）
struct QuestionStep: Identifiable, Equatable, Sendable {
    var at: Date
    var text: String
    var symbol: String
    var id: String { "\(at.timeIntervalSince1970)|\(text)" }
}

extension AppDatabase {
    // MARK: 迁移

    /// v21：自测记录、进展记录（含升级时的底账）
    static func installProgress(in db: Database, now: Date = Date()) throws {
        try db.create(table: "self_test_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("setKey", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("result", .integer).notNull()
            t.column("at", .datetime).notNull()
        }
        try db.create(index: "self_test_log_record", on: "self_test_log", columns: ["kind", "recordId", "at"])
        try db.create(table: "progress_event") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("recordId", .integer).notNull()
            t.column("detail", .text).notNull().defaults(to: "")
            t.column("at", .datetime).notNull()
            t.column("quiet", .boolean).notNull().defaults(to: false)
        }
        try db.create(index: "progress_event_at", on: "progress_event", columns: ["at"])
        try db.create(index: "progress_event_record", on: "progress_event", columns: ["kind", "recordId"])
        // 底账：已解决的问题、已被链接的札记、已被引用过的出处
        try db.execute(sql: """
            INSERT INTO progress_event(kind, recordId, detail, at, quiet)
            SELECT 'questionSolved', id, title, COALESCE(solvedAt, updatedAt), 1 FROM question WHERE status = 'solved'
            """)
        try db.execute(sql: """
            INSERT INTO progress_event(kind, recordId, detail, at, quiet)
            SELECT 'noteLinked', n.id, n.title, ?, 1 FROM idea_note n WHERE n.id IN (SELECT toId FROM idea_note_link)
            """, arguments: [now])
        try db.execute(sql: """
            INSERT INTO progress_event(kind, recordId, detail, at, quiet)
            SELECT 'sourceCited', s.id, s.title, ?, 1 FROM source s
            WHERE s.id IN (SELECT h.sourceId FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId WHERE h.sourceId IS NOT NULL)
            """, arguments: [now])
    }

    // MARK: 记下小胜（在各自的写事务里调用；v21 之前的结构里没有表就不记）

    static func recordProgress(_ db: Database, _ kind: ProgressKind, recordId: Int64, detail: String, now: Date, once: Bool = false) throws {
        guard try db.tableExists("progress_event") else { return }
        if once {
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM progress_event WHERE kind = ? AND recordId = ?", arguments: [kind.rawValue, recordId]) ?? 0
            guard n == 0 else { return }
        }
        try db.execute(sql: "INSERT INTO progress_event(kind, recordId, detail, at) VALUES (?, ?, ?, ?)",
                       arguments: [kind.rawValue, recordId, detail, now])
    }

    /// 问题状态改变：有线索、解决（同一个问题的“解决”只记一次）
    static func recordQuestionStatus(_ db: Database, questionId: Int64, from old: Question.Status, to new: Question.Status, now: Date) throws {
        guard old != new, new == .lead || new == .solved else { return }
        let title = try String.fetchOne(db, sql: "SELECT title FROM question WHERE id = ?", arguments: [questionId]) ?? ""
        if new == .lead {
            guard old == .open else { return }
            try recordProgress(db, .questionLead, recordId: questionId, detail: title, now: now)
        } else {
            try recordProgress(db, .questionSolved, recordId: questionId, detail: title, now: now, once: true)
        }
    }

    /// 札记第一次被另一条链接
    static func recordNoteLinked(_ db: Database, toId: Int64, now: Date = Date()) throws {
        guard let title = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [toId]) else { return }
        try recordProgress(db, .noteLinked, recordId: toId, detail: title, now: now, once: true)
    }

    /// 引用摘录进札记：其出处第一次被引用
    static func recordSourcesCited(_ db: Database, highlightIDs: [Int64], now: Date) throws {
        guard !highlightIDs.isEmpty, try db.tableExists("progress_event") else { return }
        let marks = Array(repeating: "?", count: highlightIDs.count).joined(separator: ",")
        for row in try Row.fetchAll(db, sql: """
            SELECT DISTINCT s.id, s.title FROM highlight h JOIN source s ON s.id = h.sourceId WHERE h.id IN (\(marks))
            """, arguments: StatementArguments(highlightIDs)) {
            try recordProgress(db, .sourceCited, recordId: row["id"], detail: row["title"], now: now, once: true)
        }
    }

    // MARK: 读取进展

    func progressEvents(start: Date, end: Date, limit: Int = 200) throws -> [ProgressEvent] {
        try writer.read { db in
            guard try db.tableExists("progress_event") else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM progress_event WHERE quiet = 0 AND at >= ? AND at < ? ORDER BY at DESC, id DESC LIMIT ?
                """, arguments: [start, end, limit]).compactMap { row in
                    guard let kind = ProgressKind(rawValue: row["kind"]) else { return nil }
                    return ProgressEvent(id: row["id"], kind: kind, recordId: row["recordId"], detail: row["detail"], at: row["at"])
                }
        }
    }

    /// 今日收获：今天的小胜，没有时用今天做了多少代替
    func todayGains(now: Date = Date()) throws -> [String] {
        let (start, end) = Self.dayBounds(now)
        let events = try progressEvents(start: start, end: end, limit: 20)
        var lines = events.prefix(3).map(\.text)
        if events.count > 3 { lines.append("另有 \(events.count - 3) 件") }
        return lines
    }

    // MARK: 自测

    /// 本周的自测题：已抽过就沿用；否则按题型各抽若干（出处 4、要点 3、论证 3，不足时互补），共 count 题
    func selfTestSet(week: GrowthWindow, count: Int = 10, now: Date = Date()) throws -> SelfTestSet {
        if let saved = try progressValue(SelfTestSet.self, key: SelfTestSet.key(week)), !saved.items.isEmpty { return saved }
        let set = SelfTestSet(items: try drawSelfTest(seed: week.key, count: count, now: now), createdAt: now)
        if !set.items.isEmpty { try saveProgress(set, key: SelfTestSet.key(week)) }
        return set
    }

    /// 抽题：摘录取收藏、写过按语、被札记引用或属当前项目的，且未做成记忆卡、有出处；札记取引用了摘录的。
    /// 近 28 天测过的不抽；从未测过的在前，同类按周 key 定序（同一周抽出的总是同一组）。
    func drawSelfTest(seed: String, count: Int = 10, now: Date = Date()) throws -> [SelfTestItem] {
        let focus = try validatedLearningFocus()
        return try writer.read { db in
            let recent = now.addingTimeInterval(-28 * 86_400)
            let focusIDs = try focus.map { try Self.focusHighlightIDs(db, $0) } ?? []
            func lastTested(_ kind: String) throws -> [Int64: Date] {
                var out: [Int64: Date] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT recordId, MAX(at) AS at FROM self_test_log WHERE kind = ? GROUP BY recordId", arguments: [kind]) {
                    out[row["recordId"]] = row["at"]
                }
                return out
            }
            let hTested = try lastTested("highlight"), nTested = try lastTested("note")
            let highlights = try Row.fetchAll(db, sql: """
                SELECT h.id, h.location, h.note, h.isFavorite,
                       EXISTS(SELECT 1 FROM idea_note_highlight x JOIN idea_note n ON n.id = x.noteId AND n.deletedAt IS NULL WHERE x.highlightId = h.id) AS cited
                FROM highlight h
                WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND h.sourceId IS NOT NULL
                  AND h.id NOT IN (SELECT highlightId FROM card WHERE highlightId IS NOT NULL AND deletedAt IS NULL)
                """)
            var pool: [(id: Int64, gistable: Bool)] = []
            for row in highlights {
                let id: Int64 = row["id"]
                let note = (row["note"] as String?) ?? ""
                let annotated = !Markdown.plainText(fromHTML: note).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let eligible = (row["isFavorite"] as Bool) || annotated || (row["cited"] as Bool) || focusIDs.contains(id)
                guard eligible, (hTested[id] ?? .distantPast) < recent else { continue }
                let location = ((row["location"] as String?) ?? "").trimmingCharacters(in: .whitespaces)
                pool.append((id, !location.isEmpty || annotated))
            }
            let notes = try Int64.fetchAll(db, sql: """
                SELECT n.id FROM idea_note n WHERE n.deletedAt IS NULL
                  AND EXISTS(SELECT 1 FROM idea_note_highlight x JOIN highlight h ON h.id = x.highlightId AND h.deletedAt IS NULL WHERE x.noteId = n.id)
                """).filter { (nTested[$0] ?? .distantPast) < recent }
            func order(_ ids: [Int64], tested: [Int64: Date]) -> [Int64] {
                ids.sorted { a, b in
                    let ta = tested[a] == nil, tb = tested[b] == nil
                    if ta != tb { return ta }
                    return Self.mix(seed, a) < Self.mix(seed, b)
                }
            }
            let gistIDs = order(pool.filter { $0.gistable }.map { $0.id }, tested: hTested)
            let noteIDs = order(notes, tested: nTested)
            var used = Set<Int64>()
            var out: [SelfTestItem] = []
            func take(_ kind: SelfTestKind, from ids: [Int64], _ n: Int) {
                var k = 0
                for id in ids where k < n && out.count < count {
                    if kind != .argument { guard !used.contains(id) else { continue }; used.insert(id) }
                    out.append(SelfTestItem(kind: kind, recordId: id)); k += 1
                }
            }
            let argN = min(3, noteIDs.count)
            let gistN = min(3, gistIDs.count)
            take(.argument, from: noteIDs, argN)
            take(.gist, from: gistIDs, gistN)
            take(.source, from: order(pool.map { $0.id }, tested: hTested), count - argN - gistN)
            // 出处题不够时，用要点题、论证题补足
            take(.gist, from: gistIDs, count - out.count)
            take(.argument, from: Array(noteIDs.dropFirst(argN)), count - out.count)
            // 题型交错：论证、要点、出处轮流
            let groups = [SelfTestKind.source, .gist, .argument].map { k in out.filter { $0.kind == k } }
            var mixed: [SelfTestItem] = []
            for i in 0..<(groups.map(\.count).max() ?? 0) { for g in groups where i < g.count { mixed.append(g[i]) } }
            return mixed
        }
    }

    /// 由周 key 与编号得出的稳定次序（SplitMix64）
    static func mix(_ seed: String, _ id: Int64) -> UInt64 {
        var x = UInt64(bitPattern: id) &+ seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return x ^ (x >> 31)
    }

    /// 本周自测的结果（按题）
    func selfTestResults(week: GrowthWindow) throws -> [SelfTestItem: SelfTestResult] {
        try writer.read { db in
            var out: [SelfTestItem: SelfTestResult] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, recordId, result FROM self_test_log WHERE setKey = ? ORDER BY at", arguments: [SelfTestSet.key(week)]) {
                let kind: String = row["kind"]
                let recordId: Int64 = row["recordId"]
                guard let r = SelfTestResult(rawValue: row["result"]) else { continue }
                // 自测记录按记录种类（摘录、札记）存；回到题目时按本周题单匹配
                for k in SelfTestKind.allCases where k.recordKind == kind { out[SelfTestItem(kind: k, recordId: recordId)] = r }
            }
            return out
        }
    }

    /// 记一道题的自评；上一次是“忘了”、这次“记得”时记一件小胜
    func recordSelfTest(_ item: SelfTestItem, result: SelfTestResult, week: GrowthWindow, now: Date = Date()) throws {
        try writer.write { db in
            let previous = try Int.fetchOne(db, sql: "SELECT result FROM self_test_log WHERE kind = ? AND recordId = ? AND setKey != ? ORDER BY at DESC LIMIT 1",
                                            arguments: [item.kind.recordKind, item.recordId, SelfTestSet.key(week)])
            try db.execute(sql: "DELETE FROM self_test_log WHERE setKey = ? AND kind = ? AND recordId = ?",
                           arguments: [SelfTestSet.key(week), item.kind.recordKind, item.recordId])
            try db.execute(sql: "INSERT INTO self_test_log(setKey, kind, recordId, result, at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [SelfTestSet.key(week), item.kind.recordKind, item.recordId, result.rawValue, now])
            if previous == SelfTestResult.forgot.rawValue, result == .remembered {
                let detail: String
                if item.kind == .argument {
                    detail = "札记《" + (try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [item.recordId]) ?? "") + "》"
                } else {
                    let text = try String.fetchOne(db, sql: "SELECT text FROM highlight WHERE id = ?", arguments: [item.recordId]) ?? ""
                    detail = String(Markdown.plainText(fromHTML: Markdown.richHTML(text)).prefix(24))
                }
                try Self.recordProgress(db, .selfTestRecovered, recordId: item.recordId, detail: detail, now: now)
            }
        }
    }

    // MARK: 检视

    func inspection(start: Date, end: Date, now: Date = Date()) async throws -> Inspection {
        let quality = try await growthQuality(start: start, end: end)
        return try await writer.read { db in
            var x = Inspection()
            x.cardRetention = quality.retention
            if try db.tableExists("self_test_log") {
                x.tested = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_test_log WHERE at >= ? AND at < ?", arguments: [start, end]) ?? 0
                x.remembered = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_test_log WHERE result = 1 AND at >= ? AND at < ?", arguments: [start, end]) ?? 0
            }
            x.notes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idea_note WHERE deletedAt IS NULL") ?? 0
            if x.notes > 0 {
                let cited = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM idea_note_highlight x JOIN idea_note n ON n.id = x.noteId AND n.deletedAt IS NULL
                    JOIN highlight h ON h.id = x.highlightId AND h.deletedAt IS NULL
                    """) ?? 0
                let links = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM idea_note_link l JOIN idea_note a ON a.id = l.fromId AND a.deletedAt IS NULL
                    JOIN idea_note b ON b.id = l.toId AND b.deletedAt IS NULL
                    """) ?? 0
                x.avgCited = Double(cited) / Double(x.notes)
                x.avgBacklinks = Double(links) / Double(x.notes)
            }
            x.revisedNotes = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT noteId) FROM idea_note_revision WHERE savedAt >= ? AND savedAt < ?", arguments: [start, end]) ?? 0
            for row in try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM question GROUP BY status") {
                switch Question.Status(rawValue: row["status"]) {
                case .open: x.open = row["n"]
                case .lead: x.lead = row["n"]
                case .solved: x.solved = row["n"]
                default: break
                }
            }
            let solved = try Row.fetchAll(db, sql: "SELECT createdAt, solvedAt FROM question WHERE status = 'solved' AND solvedAt >= ? AND solvedAt < ?", arguments: [start, end])
            x.solvedInPeriod = solved.count
            if !solved.isEmpty {
                let total = solved.reduce(0.0) { $0 + max(0, (($1["solvedAt"] as Date).timeIntervalSince($1["createdAt"] as Date))) }
                x.avgDaysToSolve = total / Double(solved.count) / 86_400
            }
            // 久未触及：半年没改、没重温的札记；半年没有新录、没回顾过其摘录的出处
            let half = now.addingTimeInterval(-182 * 86_400)
            let stale = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title FROM idea_note n LEFT JOIN idea_note_review r ON r.noteId = n.id
                WHERE n.deletedAt IS NULL AND n.updatedAt < ? AND (r.lastReviewedAt IS NULL OR r.lastReviewedAt < ?) ORDER BY n.updatedAt
                """, arguments: [half, half])
            x.untouchedNoteCount = stale.count
            x.untouchedNotes = stale.prefix(5).map { IdeaNoteRef(id: $0["id"], title: $0["title"]) }
            x.untouchedSources = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM source s
                WHERE EXISTS(SELECT 1 FROM highlight h WHERE h.sourceId = s.id AND h.deletedAt IS NULL)
                  AND NOT EXISTS(SELECT 1 FROM highlight h WHERE h.sourceId = s.id AND h.deletedAt IS NULL AND h.createdAt >= ?)
                  AND NOT EXISTS(SELECT 1 FROM review_event e JOIN highlight h ON h.id = e.highlightId WHERE h.sourceId = s.id AND e.at >= ?)
                """, arguments: [half, half]) ?? 0
            return x
        }
    }

    // MARK: 问题的经过

    func questionTimeline(id: Int64) throws -> [QuestionStep] {
        try writer.read { db in
            guard let q = try Question.fetchOne(db, key: id) else { return [] }
            var steps = [QuestionStep(at: q.createdAt, text: "记下这个问题", symbol: "questionmark.circle")]
            for row in try Row.fetchAll(db, sql: "SELECT kind, recordId, addedAt FROM question_material WHERE questionId = ?", arguments: [id]) {
                let kind = QuestionMaterial.Kind(rawValue: row["kind"]) ?? .highlight
                let rid: Int64 = row["recordId"]
                let text: String?
                switch kind {
                case .highlight: text = try String.fetchOne(db, sql: "SELECT text FROM highlight WHERE id = ?", arguments: [rid]).map { Markdown.plainText(fromHTML: Markdown.richHTML($0)) }
                case .note: text = try String.fetchOne(db, sql: "SELECT title FROM idea_note WHERE id = ?", arguments: [rid])
                case .card: text = try String.fetchOne(db, sql: "SELECT front FROM card WHERE id = ?", arguments: [rid]).map { Markdown.plainText(fromHTML: $0) }
                case .block: text = try String.fetchOne(db, sql: "SELECT text FROM notebook_block WHERE id = ?", arguments: [rid]).map { Markdown.plainText(fromHTML: $0) }
                }
                let preview = String((text ?? "（已删除）").split(whereSeparator: \.isNewline).joined(separator: " ").prefix(40))
                steps.append(QuestionStep(at: row["addedAt"], text: "挂上\(kind.title)：\(preview)", symbol: kind.symbol))
            }
            if try db.tableExists("progress_event") {
                for row in try Row.fetchAll(db, sql: """
                    SELECT kind, at FROM progress_event WHERE recordId = ? AND kind IN ('questionLead', 'questionSolved') AND quiet = 0
                    """, arguments: [id]) {
                    let solved = (row["kind"] as String) == ProgressKind.questionSolved.rawValue
                    steps.append(QuestionStep(at: row["at"], text: solved ? "解决" : "有了线索", symbol: solved ? "checkmark.circle" : "magnifyingglass.circle"))
                }
            }
            if q.status == .solved, let at = q.solvedAt, !steps.contains(where: { $0.text == "解决" }) {
                steps.append(QuestionStep(at: at, text: "解决", symbol: "checkmark.circle"))
            }
            // 同一时刻的（挂材料与随之“有了线索”）保持先后
            return steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        }
    }

    // MARK: 年度：这一年的学问

    func yearMarkdown(_ window: GrowthWindow) async throws -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        let year = Calendar.current.component(.year, from: window.start)
        var lines = ["# \(year) 年的学问", ""]
        lines += ["## 数字", ""]
        for r in try await reflectionNumbers(window) { lines.append("- \(r.title)：\(r.now)（上年 \(r.before)）") }
        let events = try progressEvents(start: window.start, end: window.end, limit: 1_000).reversed()
        lines += ["", "## 进展（\(events.count)）", ""]
        lines += events.map { "- \(f.string(from: $0.at))　\($0.text)" }
        let books = try finishedBooks(start: window.start, end: window.end)
        lines += ["", "## 读完的书（\(books.count)）", ""]
        lines += books.map { "- 《\($0.title)》" + ($0.author.isEmpty ? "" : "　\($0.author)") + ($0.oneLine.isEmpty ? "" : "：\($0.oneLine)") }
        let changes = try viewChanges(start: window.start, end: window.end)
        lines += ["", "## 观点的变化（\(changes.count)）", ""]
        for c in changes {
            lines.append("### \(c.nowTitle)")
            if c.beforeTitle != c.nowTitle { lines.append("年初题目：\(c.beforeTitle)") }
            lines += ["", "年初：" + Markdown.plainText(fromHTML: WikiLinks.plain(c.beforeBody)).trimmingCharacters(in: .whitespacesAndNewlines),
                      "", "现在：" + Markdown.plainText(fromHTML: WikiLinks.plain(c.nowBody)).trimmingCharacters(in: .whitespacesAndNewlines), ""]
        }
        let questions = try questionsYearMarkdown(window).split(separator: "\n", omittingEmptySubsequences: false).dropFirst(3)
        lines += ["", "## 问题"] + questions.map { $0.hasPrefix("## ") ? "#" + $0 : String($0) }
        return lines.joined(separator: "\n") + "\n"
    }
}
