import Foundation
import Observation
import KongReviewCore

// 说明：从 macOS 27 SDK 起，SwiftUI 的 @State 变成了宏，宏插件只随完整版 Xcode 提供，
// 仅装“命令行工具”时无法编译 @State。因此界面的局部状态改放在 @Observable 类里，
// 由 LibraryStore 持有。（@Observable 的宏插件随 Swift 工具链提供，不受影响。）

/// 每日回顾界面的状态
@MainActor
@Observable
final class ReviewState {
    /// 主题回顾：按标签限定范围；nil 为全库
    var theme: String?
    var cards: [ReviewCard] = []
    var position = 0
    /// 正在写按语时的草稿（非 nil 表示编辑框打开；此时单键快捷键停用）
    var noteDraft: String?
    /// 当前这组回顾是哪一天的（跨日时据此刷新）
    var day = ""
    /// 卡片上的出处详情（完整引文、位置、标签、添加时间）是否展开；默认折叠
    var showDetails = false
    /// 卡片下方的“相关摘录”是否展开（记住上次状态）
    var showRelated: Bool = UserDefaults.standard.bool(forKey: "review.showRelated") {
        didSet { UserDefaults.standard.set(showRelated, forKey: "review.showRelated") }
    }
}

/// 记忆卡学习界面的状态
@MainActor
@Observable
final class StudyState {
    /// 正在学习的牌组（nil 显示牌组列表）
    var deck: String?
    /// 浏览模式（列出牌组内全部卡片）
    var browsingDeck: String?
    var current: Card?
    var showingAnswer = false
    var finished = false
    var browseQuery = ""
    var browseSelection: Set<Int64> = []
    /// 最近用过的牌组（新建卡片时默认放这里）
    var lastDeck: String?
    /// 正在重命名的牌组与输入框文字
    var renamingDeck: String?
    var renameText = ""
}

/// 记忆卡编辑面板的草稿
struct CardDraft: Identifiable {
    let id = UUID()
    var card: Card
    var tagsText: String = ""
    var isNew: Bool { card.id == nil }
}

/// 记忆卡设置
enum CardSettings {
    static let newPerDayKey = "cards.newPerDay"
    static let reviewsPerDayKey = "cards.reviewsPerDay"
    static let fsrsParamsKey = "cards.fsrsParams"
    static let fsrsInfoKey = "cards.fsrsInfo"
    static let adjustDarkColorsKey = "cards.adjustDarkColors"
    static let syncFromHighlightKey = "cards.syncFromHighlight"   // "ask" / "always" / "never"
    static let menuBarCountsKey = "menubar.showCounts"

    static var newPerDay: Int { (UserDefaults.standard.object(forKey: newPerDayKey) as? Int) ?? 20 }
    static var reviewsPerDay: Int { (UserDefaults.standard.object(forKey: reviewsPerDayKey) as? Int) ?? 200 }
    static var defaults: (new: Int, review: Int) { (newPerDay, reviewsPerDay) }

    /// FSRS 参数（21 个）；没优化过时用默认值
    static var fsrsParameters: [Double] {
        get {
            let v = UserDefaults.standard.array(forKey: fsrsParamsKey) as? [Double] ?? []
            return v.count == 21 ? v : FSRS.defaultParameters
        }
        set { UserDefaults.standard.set(newValue, forKey: fsrsParamsKey) }
    }
    static var fsrsIsDefault: Bool { (UserDefaults.standard.array(forKey: fsrsParamsKey) as? [Double] ?? []).count != 21 }
    /// 上次优化的说明文字
    static var fsrsInfo: String? {
        get { UserDefaults.standard.string(forKey: fsrsInfoKey) }
        set { UserDefaults.standard.set(newValue, forKey: fsrsInfoKey) }
    }
    /// 深色模式下自动调亮卡片自带的深色文字
    static var adjustDarkColors: Bool { UserDefaults.standard.object(forKey: adjustDarkColorsKey) as? Bool ?? true }
    static var syncFromHighlight: String { UserDefaults.standard.string(forKey: syncFromHighlightKey) ?? "ask" }
    static var menuBarCounts: Bool { UserDefaults.standard.object(forKey: menuBarCountsKey) as? Bool ?? true }
}

/// 导出到 Anki 的选择
struct ApkgExportRequest: Identifiable {
    let id = UUID()
    var allDecks: [String]
    var decks: Set<String>
    var includeScheduling = true
}

/// 改了摘录后，询问是否同步更新对应的记忆卡
struct CardSyncOffer: Identifiable {
    let id = UUID()
    var highlightId: Int64
    var cardCount: Int
}

/// Anki 导入预览
struct CardImportPreview: Identifiable {
    let id = UUID()
    var fileName: String
    var notes: [AnkiNote]
    var media: [String: Data]
    var withSchedule: Int { notes.filter { $0.schedule != nil }.count }
    var withMemory: Int { notes.filter { $0.memory != nil }.count }
    var revlogCount: Int { notes.reduce(0) { $0 + $1.revlog.count } }
    var noteTypes: [String] { Array(Set(notes.compactMap { $0.fieldNames.isEmpty ? nil : $0.noteType })).sorted() }
    var usesFSRS: Bool { notes.contains { $0.deckOptions?.algorithm == .fsrs } }
    var decks: [String] { Array(Set(notes.map(\.deck))).sorted() }
}

/// 网页存档正文编辑
struct ArticleSourceDraft: Identifiable {
    let id = UUID()
    var articleId: Int64
    var html: String
}

/// 摘录列表界面的状态
@MainActor
@Observable
final class ListState {
    var query = ""
    var items: [Highlight] = []
    /// 符合当前筛选条件的总数
    var total = 0
    /// 已加载的条数上限（分页：每次多加载 pageSize 条）
    var limit = ListState.pageSize
    /// 多选的摘录 id
    var selection: Set<Int64> = []
    /// 上一次加载用的筛选条件（变化时回到第一页）
    var lastQuery: HighlightQuery?
    /// 组合筛选（出处、多个标签、日期、只看收藏）
    var extra = ListFilter()
    /// 筛选条是否展开
    var showFilters = false
    /// 筛选条件属于哪个列表（切换列表时清空）
    var extraOwner = ""

    static let pageSize = 200
    var hasMore: Bool { items.count < total }
}

/// 出处列表的排序方式（侧边栏）
enum SourceSort: String, CaseIterable {
    case recent, count, title
    var label: String {
        switch self {
        case .recent: return "最近添加"
        case .count: return "摘录数"
        case .title: return "书名"
        }
    }
    static let defaultsKey = "sidebar.sourceSort"
    static var current: SourceSort {
        get { SourceSort(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .recent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// 批量操作
enum BatchAction {
    case favorite(Bool)
    case discard(Bool)
    case addTags([String])
    case removeTags([String])
    case move(Int64?)
    case addToMastery   // 做成记忆卡
    case delete
}

/// 需要输入的批量操作（加标签、去标签、移到出处）
struct BatchPrompt: Identifiable {
    enum Kind { case addTags, removeTags, move }
    let id = UUID()
    var kind: Kind
    var ids: [Int64]
    var text = ""
}

/// 导出请求
struct ExportRequest: Identifiable {
    enum Kind { case compilation, anki }
    let id = UUID()
    var kind: Kind
    /// 说明导出范围，如“已选 12 条”“#仁 · 全部 86 条”
    var scopeLabel: String
    var highlights: [Highlight]
    var title: String
    var grouping: CompilationOptions.Grouping = .bySource
    var includeTranslation = true
    var includeNotes = true
    var includeTags = false
    var style: CitationStyle = CitationSettings.style
    var wordFormat = true
}

enum CitationSettings {
    static let defaultsKey = "citation.style"
    static var style: CitationStyle {
        get { CitationStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .footnote }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// 合并出处请求
struct MergeRequest: Identifiable {
    struct Candidate: Identifiable {
        var source: Source
        var count: Int
        var id: Int64 { source.id ?? -1 }
    }
    let id = UUID()
    var sources: [Candidate]
    var target: Int64
}

struct ReviewCard: Identifiable {
    var highlight: Highlight
    var isMastery: Bool
    var id: Int64 { highlight.id ?? -1 }
}

/// 读取“今日回顾”保存在 UserDefaults 里的进度（全库那一组），供菜单栏与提醒显示剩余条数
enum ReviewSessionRecordStore {
    struct Snapshot: Decodable {
        var day: String
        var regularIds: [Int64]
        var masteryIds: [Int64]
        var position: Int
        var total: Int { regularIds.count + masteryIds.count }
    }

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: "review.session._all") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

/// 1.1：标签改名 / 合并 / 删除
struct TagEditRequest: Identifiable {
    enum Mode { case rename, delete }
    let id = UUID()
    var tag: String
    var mode: Mode
    var newName: String
    /// 受影响的摘录数（含子标签）
    var affected: Int
}

/// 填空卡制作
struct ClozeDraft: Identifiable {
    let id = UUID()
    var highlightId: Int64?
    /// 带 {{c1::…}} 标记的原文
    var text: String
    /// 背面附加内容（译文、按语、出处）
    var extra: String
    var deck: String
    var tags: [String]
    var numbers: [Int] { AnkiContent.clozeNumbers(text) }
}
