import Foundation
import GRDB
import KongReviewCore

// MARK: - 出处封面、摘录频率、收件箱导入

extension AppDatabase {
    func cover(sourceId: Int64) throws -> Data? {
        try writer.read { db in try Data.fetchOne(db, sql: "SELECT data FROM source_cover WHERE sourceId = ?", arguments: [sourceId]) }
    }

    /// 有封面的出处 id
    func coverSourceIDs() throws -> Set<Int64> {
        try writer.read { db in Set(try Int64.fetchAll(db, sql: "SELECT sourceId FROM source_cover")) }
    }

    /// 设置封面；data 为 nil 时删除
    func setCover(sourceId: Int64, data: Data?) throws {
        try writer.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO source_cover (sourceId, data, updatedAt) VALUES (?, ?, ?)",
                               arguments: [sourceId, data, Date()])
            } else {
                try db.execute(sql: "DELETE FROM source_cover WHERE sourceId = ?", arguments: [sourceId])
            }
        }
    }

    func setFrequency(_ value: Int?, highlightId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE highlight SET frequency = ?, updatedAt = ? WHERE id = ?",
                           arguments: [value, Date(), highlightId])
        }
    }

    struct InboxReport: Equatable {
        var added = 0
        var duplicates = 0
        var sourceTitle = ""
    }

    /// 导入一个收件箱文件：出处按标题 + 作者合并；摘录按 来源应用 + 外部 id 去重
    func importInbox(_ file: InboxPayload.File, now: Date = Date()) throws -> InboxReport {
        try writer.write { db in
            var r = InboxReport(sourceTitle: file.source.title)
            let info = file.source
            let author = info.author ?? ""
            var source: Source
            if let existing = try Source.filter(Column("title") == info.title && Column("author") == author).fetchOne(db) {
                source = existing
                var changed = false
                if source.url == nil, let u = info.url { source.url = u; changed = true }
                if source.isbn == nil, let i = info.isbn { source.isbn = i; changed = true }
                if changed { try source.update(db) }
            } else {
                source = Source(title: info.title, author: author, kind: info.sourceKind, url: info.url,
                                publisher: info.publisher, year: info.year)
                source.isbn = info.isbn
                try source.insert(db)
            }
            for item in file.highlights {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let key = InboxPayload.key(app: file.app, item: item)
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_item WHERE key = ?)", arguments: [key]) ?? false {
                    r.duplicates += 1
                    continue
                }
                var h = Highlight(sourceId: source.id, text: text, translation: item.translation?.nilIfBlank,
                                  note: item.note?.nilIfBlank, location: item.resolvedLocation, tags: item.tags ?? [],
                                  createdAt: item.createdAt ?? now, updatedAt: now)
                try h.insert(db)
                try db.execute(sql: "INSERT INTO inbox_item (key, highlightId, importedAt) VALUES (?, ?, ?)",
                               arguments: [key, h.id, now])
                r.added += 1
            }
            return r
        }
    }
}

// MARK: - 已存搜索（存在 UserDefaults，体积很小）

struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var text: String
    var filter: ListFilter

    static let key = "list.savedSearches"

    static func all() -> [SavedSearch] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: d)) ?? []
    }

    static func save(_ list: [SavedSearch]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// 列表上方的组合筛选
struct ListFilter: Codable, Hashable {
    var sourceId: Int64?
    var tags: [String] = []
    var from: Date?
    var to: Date?
    var favoritesOnly = false

    var isEmpty: Bool { sourceId == nil && tags.isEmpty && from == nil && to == nil && !favoritesOnly }
}
