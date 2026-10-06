import Foundation

// MARK: - 出处（书、文章、网页……）

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case book, article, web, pdf, other

    public var label: String {
        switch self {
        case .book: return "书籍"
        case .article: return "论文/文章"
        case .web: return "网页"
        case .pdf: return "PDF"
        case .other: return "其他"
        }
    }
}

public struct Source: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var title: String
    public var author: String
    public var kind: SourceKind
    public var url: String?
    public var publisher: String?
    /// 版本信息，如“中华书局 1983 年版”“点校本”
    public var edition: String?
    public var year: String?
    /// 回顾频率系数：0 = 不再出现，1 = 正常，2 = 加倍
    public var reviewWeight: Double
    public var createdAt: Date
    /// 出版地（GB/T 7714 专著需要），如“北京”
    public var place: String?
    /// 所载期刊 / 文集 / 报纸名（论文、文章用）
    public var container: String?
    /// 卷期，如“55(34)”或“第3期”
    public var issue: String?

    public init(
        id: Int64? = nil,
        title: String,
        author: String = "",
        kind: SourceKind = .book,
        url: String? = nil,
        publisher: String? = nil,
        edition: String? = nil,
        year: String? = nil,
        reviewWeight: Double = 1,
        createdAt: Date = Date(),
        place: String? = nil,
        container: String? = nil,
        issue: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.kind = kind
        self.url = url
        self.publisher = publisher
        self.edition = edition
        self.year = year
        self.reviewWeight = reviewWeight
        self.createdAt = createdAt
        self.place = place
        self.container = container
        self.issue = issue
    }
}

// MARK: - 摘录

public struct Highlight: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var sourceId: Int64?
    /// 原文
    public var text: String
    /// 译文 / 白话（可选，适合古籍与外文材料）
    public var translation: String?
    /// 个人按语
    public var note: String?
    /// 位置：页码、卷次、章节等
    public var location: String?
    public var tags: [String]

    public var isFavorite: Bool
    public var isDiscarded: Bool

    // 每日回顾状态
    public var lastSurfacedAt: Date?
    public var surfacedCount: Int

    // Mastery（记忆卡）状态：半衰期为空表示未加入记忆
    public var masteryHalfLifeDays: Double?
    public var masteryLastReviewedAt: Date?

    public var createdAt: Date
    public var updatedAt: Date
    /// 软删除时间；非空表示在“最近删除”里，30 天后彻底清除
    public var deletedAt: Date?

    public init(
        id: Int64? = nil,
        sourceId: Int64? = nil,
        text: String,
        translation: String? = nil,
        note: String? = nil,
        location: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        isDiscarded: Bool = false,
        lastSurfacedAt: Date? = nil,
        surfacedCount: Int = 0,
        masteryHalfLifeDays: Double? = nil,
        masteryLastReviewedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.text = text
        self.translation = translation
        self.note = note
        self.location = location
        self.tags = tags
        self.isFavorite = isFavorite
        self.isDiscarded = isDiscarded
        self.lastSurfacedAt = lastSurfacedAt
        self.surfacedCount = surfacedCount
        self.masteryHalfLifeDays = masteryHalfLifeDays
        self.masteryLastReviewedAt = masteryLastReviewedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public var isInMastery: Bool { masteryHalfLifeDays != nil }
}

// MARK: - 标签工具

public enum TagParser {
    /// 把“论语, 仁 #礼  孔子”之类的输入规范成去重、去井号的标签数组。
    public static func parse(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；#").union(.whitespacesAndNewlines)
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.components(separatedBy: separators) {
            let tag = piece.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }
        return result
    }

    public static func format(_ tags: [String]) -> String {
        tags.joined(separator: ", ")
    }
}
