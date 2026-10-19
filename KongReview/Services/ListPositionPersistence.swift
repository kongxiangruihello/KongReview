import Foundation

/// 只保存列表参数和定位 ID，不保存摘录、卡片或网页正文。
@MainActor
final class ListPositionPersistence {
    static let pageSizes = [50, 100, 200]
    private let defaults: UserDefaults?
    private let prefix = "lists.position.v1."

    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    static func normalizedPageSize(_ value: Int) -> Int {
        pageSizes.contains(value) ? value : 200
    }

    func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = defaults?.data(forKey: prefix + key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ snapshot: T, for key: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: prefix + key)
    }
}

struct HighlightListPosition: Codable, Equatable {
    var query = ""
    var extra = ListFilter()
    var showFilters = false
    var page = 1
    var pageSize = 200
    var limit = 200
    var sourceByPage = true
    var anchorID: Int64?
}

struct CardBrowsePosition: Codable, Equatable {
    var query = ""
    var page = 1
    var pageSize = 200
    var anchorID: Int64?
    var tag: String?
    var stateFilter: String?
}
