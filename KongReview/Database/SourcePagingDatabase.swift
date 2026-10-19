import Foundation
import GRDB
import KongReviewCore

/// 不把 KeyPathComparator 带入请求标识；只记录表格公开的排序字段和方向。
struct SourcePageSort: Hashable, Sendable {
    enum Field: Hashable, Sendable { case title, author, kind, count, createdAt }
    var field: Field
    var descending = false

    init(_ field: Field, descending: Bool = false) {
        self.field = field
        self.descending = descending
    }

    init?(_ comparator: KeyPathComparator<SourceRow>) {
        switch comparator.keyPath {
        case \SourceRow.title: field = .title
        case \SourceRow.author: field = .author
        case \SourceRow.kindLabel: field = .kind
        case \SourceRow.count: field = .count
        case \SourceRow.createdAt: field = .createdAt
        default: return nil
        }
        descending = comparator.order == .reverse
    }

    var comparator: KeyPathComparator<SourceRow> {
        let order: SortOrder = descending ? .reverse : .forward
        switch field {
        case .title: return KeyPathComparator(\.title, order: order)
        case .author: return KeyPathComparator(\.author, order: order)
        case .kind: return KeyPathComparator(\.kindLabel, order: order)
        case .count: return KeyPathComparator(\.count, order: order)
        case .createdAt: return KeyPathComparator(\.createdAt, order: order)
        }
    }
}

struct SourcePage: Sendable {
    var items: [SourceRow]
    var total: Int
    var page: Int
    /// 标记仍基于全库；搜索只显示重复组的一项时，也不会丢掉提示。
    var duplicateIDs: Set<Int64>
    var duplicateCount: Int
}

extension AppDatabase {
    /// 只在后台读取轻量书目信息；查重、筛选、排序和计数来自同一个快照，页面仅接收当前页。
    func sourcePage(query: String, onlyDuplicates: Bool, sorts: [SourcePageSort],
                    page: Int, pageSize: Int = 200) async throws -> SourcePage {
        try await writer.read { db in
            let sources = try Source.fetchAll(db)
            let duplicateIDs = Set(SourceDedup.duplicateGroups(sources).flatMap { $0 })
            let countRows = try Row.fetchAll(db, sql: """
                SELECT sourceId, COUNT(*) AS n FROM highlight
                WHERE sourceId IS NOT NULL AND deletedAt IS NULL GROUP BY sourceId
                """)
            var counts: [Int64: Int] = [:]
            for row in countRows { counts[row["sourceId"]] = row["n"] }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var rows = sources.compactMap { source -> SourceRow? in
                guard let id = source.id,
                      !onlyDuplicates || duplicateIDs.contains(id),
                      text.isEmpty || source.title.localizedCaseInsensitiveContains(text)
                        || source.author.localizedCaseInsensitiveContains(text) else { return nil }
                return SourceRow(id: id, source: source, count: counts[id] ?? 0)
            }
            if onlyDuplicates {
                let keys = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, SourceDedup.key($0.title)) })
                rows.sort {
                    let left = keys[$0.id]!, right = keys[$1.id]!
                    if left != right { return left < right }
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.id < $1.id
                }
            } else {
                let comparators = sorts.map(\.comparator)
                rows.sort { left, right in
                    for comparator in comparators {
                        let result = comparator.compare(left, right)
                        if result != .orderedSame { return result == .orderedAscending }
                    }
                    // 同值排序固定 ID，避免翻页时漏项或重复。
                    return left.id < right.id
                }
            }
            let size = max(1, pageSize)
            let total = rows.count
            let current = min(max(1, page), max(1, (total + size - 1) / size))
            let start = (current - 1) * size
            let items = Array(rows.dropFirst(start).prefix(size))
            return SourcePage(items: items, total: total, page: current,
                              duplicateIDs: duplicateIDs.intersection(items.map(\.id)),
                              duplicateCount: duplicateIDs.count)
        }
    }
}
