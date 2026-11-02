import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.1：精简
//
// 应用改为“考场”：每天围绕摘录、记忆卡、札记、问题、笔记来测。与此无关的功能拿掉入口、停掉后台行为：
// 研究项目与当前项目加权、写作统计、学习计划与本期焦点、网页存档、精简提要、封面与篇目进度、版本页码、
// 去年今日、常念的问题、本周进展、专题汇编与参考文献表、笔记本的 Word 与演示稿导出、Obsidian 同步、
// Readwise 导入、引文速查、每周小结推送。
// 数据一律不删：第一次打开 6.0.1 时，把这些功能里自己写的内容导出成 Markdown，并留一份完整的数据库快照。

extension LibraryStore {
    /// 舍弃的功能一律关闭（保留开关只为让旧代码在 6.0.3 清理前仍能编译、测试）
    static let slimmedFeaturesOff = true

    /// 第一次打开 6.0.1：在后台导出舍弃内容并做快照，完成后提示一次
    func runSlimUpgradeIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: SlimUpgrade.doneKey) else { return }
        let db = self.db
        Task.detached(priority: .utility) {
            let result = Result { try SlimUpgrade.run(db: db, defaults: defaults) }
            await MainActor.run {
                switch result {
                case .success(let r?):
                    self.infoMessage = r.message
                case .success(nil):
                    break
                case .failure(let e):
                    AppLog.write("6.0.1 精简留存失败：\(e.localizedDescription)")
                    self.errorMessage = "6.0.1 精简：导出舍弃内容时出错（数据都还在库里，下次打开会再试）：\(e.localizedDescription)"
                }
            }
        }
    }
}

enum SlimUpgrade {
    static let doneKey = "slim601.exported"

    struct Result: Equatable, Sendable {
        var folder: URL
        /// 文件名 → 条数
        var files: [String: Int]
        var snapshot: URL

        var message: String {
            let parts = files.sorted { $0.key < $1.key }.map { "\($0.key)（\($0.value) 条）" }
            return "6.0.1 起应用改为“考场”，研究项目、网页存档、精简提要、学习计划等功能已拿掉。"
                + (parts.isEmpty ? "这些功能里没有您写的内容。" : "其中您写的内容已导出为 Markdown：" + parts.joined(separator: "、") + "。")
                + "另存了一份完整的数据库快照。都在备份文件夹的“\(folder.lastPathComponent)”里；数据库里的原始记录也都保留着。"
        }
    }

    /// 每一类：文件名、表、标题列、排序；按需从 app_progress 取 JSON 记录
    struct Table: Sendable {
        var file: String
        var table: String
        var title: [String]
        var whereSQL: String = ""
        var order: String = "rowid"
    }

    static let tables: [Table] = [
        Table(file: "研究项目", table: "research_project", title: ["title"]),
        Table(file: "研究项目的材料", table: "research_project_link", title: ["projectId", "kind", "recordId"]),
        Table(file: "研究项目的阶段", table: "research_project_stage", title: ["projectId", "stage"]),
        Table(file: "写作记录", table: "writing_log", title: ["day"]),
        Table(file: "精简提要", table: "book_summary", title: ["sourceId", "oneLine"]),
        Table(file: "网页存档", table: "article", title: ["title"]),
        Table(file: "学习计划与本期焦点", table: "app_progress", title: ["key"],
              whereSQL: "key LIKE 'learning-plan.%' OR key LIKE 'learning-cycle%' OR key LIKE 'learning-focus%' OR key LIKE 'focus%'",
              order: "key"),
    ]

    /// 导出到 directory（默认为备份文件夹）下的新文件夹；已做过返回 nil
    @discardableResult
    static func run(db: AppDatabase, defaults: UserDefaults = .standard, directory: URL? = nil, now: Date = Date()) throws -> Result? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        let fm = FileManager.default
        let base = try directory ?? BackupService.directory()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var folder = base.appendingPathComponent("6.0.1 精简前留存 \(f.string(from: now))", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("6.0.1 精简前留存 \(f.string(from: now)) (\(n))", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var files: [String: Int] = [:]
        for (name, text, count) in try markdown(db: db) where count > 0 {
            try text.write(to: folder.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            files[name] = count
        }
        let snapshot = folder.appendingPathComponent("KongReview 数据库快照（6.0.1 之前）.sqlite")
        try db.backup(to: snapshot)
        let readme = """
        # 6.0.1 精简前留存

        KongReview 6.0.1 起改为“考场”：每天围绕摘录、记忆卡、札记、问题、笔记来测。
        研究项目、写作统计、学习计划与本期焦点、网页存档、精简提要、封面与篇目进度、版本页码、
        去年今日、常念的问题、本周进展、专题汇编与参考文献表、笔记本的 Word 与演示稿导出、
        Obsidian 同步、Readwise 导入、引文速查、每周小结推送等功能的入口已拿掉。

        - 各 .md 文件：这些功能里您写下的内容（一条一节）。
        - “KongReview 数据库快照（6.0.1 之前）.sqlite”：此刻的完整数据库（SQLite），任何 SQLite 工具都能打开；也可以放回数据文件夹恢复。
        - 应用数据库里的原始记录没有删除。

        导出时间：\(now.formatted(date: .complete, time: .standard))
        """
        try readme.write(to: folder.appendingPathComponent("说明.md"), atomically: true, encoding: .utf8)
        defaults.set(true, forKey: doneKey)
        return Result(folder: folder, files: files, snapshot: snapshot)
    }

    /// 每一类一份 Markdown：（文件名，正文，条数）。表不存在或为空时条数为 0。
    static func markdown(db: AppDatabase) throws -> [(String, String, Int)] {
        try db.writer.read { db in
            var out: [(String, String, Int)] = []
            for t in tables {
                guard try db.tableExists(t.table) else { out.append((t.file, "", 0)); continue }
                let sql = "SELECT * FROM \(t.table)" + (t.whereSQL.isEmpty ? "" : " WHERE \(t.whereSQL)") + " ORDER BY \(t.order)"
                let rows = try Row.fetchAll(db, sql: sql)
                var text = "# \(t.file)\n\n导出自 KongReview 表 `\(t.table)`，共 \(rows.count) 条。\n"
                for (i, row) in rows.enumerated() {
                    let heading = t.title.compactMap { c -> String? in
                        guard row.hasColumn(c) else { return nil }
                        let v = cell(row[c] as DatabaseValue)
                        return v.isEmpty ? nil : v
                    }.joined(separator: " · ")
                    text += "\n## \(i + 1). \(heading.isEmpty ? "（无题）" : oneLine(heading))\n\n"
                    for column in row.columnNames {
                        let value = cell(row[column] as DatabaseValue, column: column)
                        guard !value.isEmpty else { continue }
                        if value.contains("\n") || value.count > 80 {
                            text += "- **\(column)**：\n\n" + value.split(separator: "\n", omittingEmptySubsequences: false)
                                .map { "  > " + $0 }.joined(separator: "\n") + "\n\n"
                        } else {
                            text += "- **\(column)**：\(value)\n"
                        }
                    }
                }
                out.append((t.file, text, rows.count))
            }
            return out
        }
    }

    private static func oneLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }

    /// 一格转成文字：HTML 转纯文字，JSON 原样，二进制注明大小
    static func cell(_ v: DatabaseValue, column: String = "") -> String {
        switch v.storage {
        case .null: return ""
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") && trimmed.contains(">") { return Markdown.plainText(fromHTML: trimmed) }
            return trimmed
        case .blob(let data):
            if let s = String(data: data, encoding: .utf8), s.hasPrefix("{") || s.hasPrefix("[") { return s }
            return "（二进制 \(data.count) 字节，保留在数据库里）"
        }
    }
}
