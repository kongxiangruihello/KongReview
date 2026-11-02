import Foundation
import GRDB
import KongReviewCore

// MARK: - 5.0.3：首页“常念的问题”“去年今日”，侧栏四组

/// 往年同一天录的摘录、写的札记、记的问题
struct OnThisDayItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case highlight, note, question }
    var kind: Kind
    var recordId: Int64
    var text: String
    var createdAt: Date
    var yearsAgo: Int
    var id: String { "\(kind.rawValue).\(recordId)" }
    var label: String {
        switch kind {
        case .highlight: "录下摘录"
        case .note: "写下札记"
        case .question: "记下问题"
        }
    }
}

/// 侧栏分组与首页的显示设置
enum SidebarLayout {
    static let showResearchKey = "sidebar.showResearch"
    static let v5AppliedKey = "sidebar.v5.applied"
    /// 4.0 的组名（today、research、reading、collect、writing、growth）改为 5.0 的四组；6.0.1 起为考场、题库、其他三组
    static let groups = ["exam", "bank", "other"]

    /// 第一次用 5.0 侧栏时：“研究与写作”默认折叠（之后按自己的折叠状态）
    static func applyV5Defaults(collapsed: Set<String>, applied: Bool) -> (collapsed: Set<String>, applied: Bool) {
        guard !applied else { return (collapsed, true) }
        return (collapsed.union(["research"]), true)
    }

    static var showResearch: Bool { UserDefaults.standard.object(forKey: showResearchKey) as? Bool ?? true }
}

extension AppDatabase {
    /// 去年今日：往年与今天同月同日（按本地日期；平年的 2 月 28 日一并列出 2 月 29 日的）创建的摘录、札记、问题，新的在前
    func onThisDay(now: Date = Date(), calendar: Calendar = .current, limit: Int = 50) throws -> [OnThisDayItem] {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = c.year, let month = c.month, let day = c.day else { return [] }
        var days = [String(format: "%02d-%02d", month, day)]
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        if month == 2 && day == 28 && !leap { days.append("02-29") }
        let marks = days.map { _ in "?" }.joined(separator: ",")
        let yearText = String(format: "%04d", year)
        return try writer.read { db in
            func fetch(_ sql: String) throws -> [Row] {
                try Row.fetchAll(db, sql: sql, arguments: StatementArguments(days + [yearText]))
            }
            let cond = "strftime('%m-%d', createdAt, 'localtime') IN (\(marks)) AND strftime('%Y', createdAt, 'localtime') < ?"
            var out: [OnThisDayItem] = []
            for row in try fetch("SELECT id, text, createdAt FROM highlight WHERE deletedAt IS NULL AND \(cond)") {
                let text = Markdown.plainText(fromHTML: Markdown.richHTML(row["text"]))
                out.append(.init(kind: .highlight, recordId: row["id"], text: text, createdAt: row["createdAt"], yearsAgo: 0))
            }
            for row in try fetch("SELECT id, title, createdAt FROM idea_note WHERE deletedAt IS NULL AND \(cond)") {
                out.append(.init(kind: .note, recordId: row["id"], text: row["title"], createdAt: row["createdAt"], yearsAgo: 0))
            }
            for row in try fetch("SELECT id, title, createdAt FROM question WHERE \(cond)") {
                out.append(.init(kind: .question, recordId: row["id"], text: row["title"], createdAt: row["createdAt"], yearsAgo: 0))
            }
            for i in out.indices {
                out[i].yearsAgo = max(1, year - calendar.component(.year, from: out[i].createdAt))
                out[i].text = String(out[i].text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120))
            }
            // 新的在前；同一年里札记、问题在摘录前（自己的想法更值得一看）
            let rank: [OnThisDayItem.Kind: Int] = [.note: 0, .question: 1, .highlight: 2]
            return Array(out.sorted { a, b in
                if a.yearsAgo != b.yearsAgo { return a.yearsAgo < b.yearsAgo }
                if a.kind != b.kind { return rank[a.kind]! < rank[b.kind]! }
                return a.createdAt > b.createdAt
            }.prefix(limit))
        }
    }

    /// 首页“常念的问题”：常念且未解决的，最近改过的在前；另给出总数
    func pinnedQuestions(limit: Int = 3) throws -> (items: [QuestionRef], total: Int) {
        try writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM question WHERE pinned = 1 AND status IN ('open', 'lead')") ?? 0
            let items = try Row.fetchAll(db, sql: """
                SELECT id, title, status, pinned FROM question WHERE pinned = 1 AND status IN ('open', 'lead') ORDER BY updatedAt DESC, id DESC LIMIT ?
                """, arguments: [limit]).map {
                    QuestionRef(id: $0["id"], title: $0["title"], status: Question.Status(rawValue: $0["status"]) ?? .open, pinned: $0["pinned"])
                }
            return (items, total)
        }
    }
}
