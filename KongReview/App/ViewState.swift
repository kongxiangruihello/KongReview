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
    /// 1.2：卡片上就地编辑原文、译文、按语时的草稿（非 nil 表示正在编辑；此时单键快捷键停用）
    var inlineDraft: InlineEditDraft?
    /// 1.4：改变它会让回顾页重新载入当前范围（“回顾这本”时从头开始）
    var sessionToken = 0
    /// 当前这组回顾是哪一天的（跨日时据此刷新）
    var day = ""
    /// 卡片上的出处详情（完整引文、位置、标签、添加时间）是否展开；默认折叠
    var showDetails = false
    /// 卡片下方的“相关摘录”是否展开（记住上次状态）
    var showRelated: Bool = UserDefaults.standard.bool(forKey: "review.showRelated") {
        didSet { UserDefaults.standard.set(showRelated, forKey: "review.showRelated") }
    }
}

/// 生成参考文献表的请求：一组出处（按在列表里首次出现的顺序）
struct BibliographyRequest: Identifiable {
    let id = UUID()
    var title: String
    var sources: [Source]
}

/// 回顾范围：theme 为 nil 是全库，“nb:12”是专题笔记本（1.4），其余是标签
enum ReviewScope {
    static let notebookPrefix = "nb:"
    static func notebook(_ id: Int64) -> String { notebookPrefix + String(id) }
    /// 1.5：久未回顾的摘录（从未出现或半年以上没出现）
    static let stale = "__stale"
    static func notebookID(_ theme: String?) -> Int64? {
        guard let t = theme, t.hasPrefix(notebookPrefix) else { return nil }
        return Int64(t.dropFirst(notebookPrefix.count))
    }

    /// 1.7：按书回顾——“src:12”是整本书，“src:12:10-20”是第 10–20 页
    static let sourcePrefix = "src:"
    /// 不限的一头写成空：“src:12:-50”（第 50 页以前）、“src:12:10-”（第 10 页以后）
    static func source(_ id: Int64, pages: ClosedRange<Int>? = nil) -> String {
        guard let p = pages else { return sourcePrefix + String(id) }
        let a = p.lowerBound == Int.min ? "" : String(p.lowerBound)
        let b = p.upperBound == Int.max ? "" : String(p.upperBound)
        return sourcePrefix + String(id) + ":" + a + "-" + b
    }
    static func sourceScope(_ theme: String?) -> (id: Int64, pages: ClosedRange<Int>?)? {
        guard let t = theme, t.hasPrefix(sourcePrefix) else { return nil }
        let parts = t.dropFirst(sourcePrefix.count).split(separator: ":", maxSplits: 1)
        guard let first = parts.first, let id = Int64(first) else { return nil }
        guard parts.count == 2 else { return (id, nil) }
        let r = parts[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard r.count == 2 else { return (id, nil) }
        let a = r[0].isEmpty ? Int.min : Int(r[0])
        let b = r[1].isEmpty ? Int.max : Int(r[1])
        guard let a, let b, !(r[0].isEmpty && r[1].isEmpty) else { return (id, nil) }
        return (id, min(a, b)...max(a, b))
    }
}

/// 1.9：引文核对的结果（导出前检查）
struct CitationCheckRequest: Identifiable {
    enum Export { case docx, pdf }
    /// 重新核对后沿用原来的 id，面板不会关掉再弹出
    var id = UUID()
    var issues: [CitationCheck.Issue]
    /// 摘录 id → 开头几个字（列表里显示）
    var snippets: [Int64: String]
    /// 从导出菜单进来时，核对完可“仍然导出”
    var export: Export?
    /// 2.0：清单里直接补的页码（摘录 id → 输入的页码）
    var pageDrafts: [Int64: String] = [:]
    /// 摘录现在的位置（补页码时显示）
    var locations: [Int64: String] = [:]
    /// 有几条填了页码
    var filledPages: Int { pageDrafts.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
}

/// 2.2：从对照表导入版本页码
@MainActor
@Observable
final class EditionImportDraft: Identifiable {
    nonisolated let id = UUID()
    let sourceId: Int64
    var editionId: Int64?
    /// 读到的单元格
    var cells: [[String]] = []
    /// 表从哪里来（文件名或“剪贴板”）
    var origin = ""
    var overwrite = false
    var error: String?
    init(sourceId: Int64, editionId: Int64?) {
        self.sourceId = sourceId
        self.editionId = editionId
    }
    var rows: [EditionPageImport.Row] { EditionPageImport.rows(cells) }
}

/// 2.1：篇目进度面板
struct ChapterProgressRequest: Identifiable {
    let id = UUID()
    var sourceId: Int64
}

/// 2.0：按篇回顾——“chap:12:学而”
extension ReviewScope {
    static let chapterPrefix = "chap:"
    static func chapter(_ sourceId: Int64, _ name: String) -> String { chapterPrefix + String(sourceId) + ":" + name }
    static func chapterScope(_ theme: String?) -> (id: Int64, chapter: String)? {
        guard let t = theme, t.hasPrefix(chapterPrefix) else { return nil }
        let parts = t.dropFirst(chapterPrefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = Int64(parts[0]), !parts[1].isEmpty else { return nil }
        return (id, String(parts[1]))
    }
}

/// 1.7：出处书页“按页码范围”面板
@MainActor
@Observable
final class PageRangeDraft: Identifiable {
    nonisolated let id = UUID()
    let sourceId: Int64
    var fromText: String
    var toText: String
    init(sourceId: Int64, from: Int?, to: Int?) {
        self.sourceId = sourceId
        self.fromText = from.map(String.init) ?? ""
        self.toText = to.map(String.init) ?? ""
    }
    /// 输入的范围（只填一头时另一头不限）；都没填为 nil
    var range: ClosedRange<Int>? {
        let a = Int(fromText.trimmingCharacters(in: .whitespaces))
        let b = Int(toText.trimmingCharacters(in: .whitespaces))
        switch (a, b) {
        case let (a?, b?): return min(a, b)...max(a, b)
        case let (a?, nil): return a...Int.max
        case let (nil, b?): return Int.min...b
        default: return nil
        }
    }
}

/// 回顾卡片就地编辑的草稿
struct InlineEditDraft: Equatable {
    var id: Int64?
    var text: String
    var translation: String
    var note: String
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
    var browseItems: [Card] = []
    var browseTotal = 0
    var browsePage = 1
    var browsePageInput = "1"
    var browseIsLoading = false
    var browseLoadID = UUID()
    var browseOwnerDeck: String?
    var browseLoadedQuery = ""
    static let browsePageSize = 200
    var browsePageCount: Int { max(1, (browseTotal + Self.browsePageSize - 1) / Self.browsePageSize) }

    func openCardBrowser(_ deck: String) {
        self.deck = nil
        notebookId = nil
        browseLoadID = UUID()
        browseQuery = ""
        browseSelection = []
        browseItems = []
        browseTotal = 0
        browsePage = 1
        browsePageInput = "1"
        browseIsLoading = false
        browseOwnerDeck = nil
        browseLoadedQuery = ""
        browsingDeck = deck
    }
    /// 最近用过的牌组（新建卡片时默认放这里）
    var lastDeck: String?
    /// 正在重命名的牌组与输入框文字
    var renamingDeck: String?
    var renameText = ""
    /// 1.7：按笔记本学习（deck 里放显示名“《笔记本》”）
    var notebookId: Int64?
    var notebookCounts = StudyQueue.Counts()
    /// 1.9：显示答案后是否展开“原文语境”（记住上次状态）
    var showContext: Bool = UserDefaults.standard.bool(forKey: "study.showContext") {
        didSet { UserDefaults.standard.set(showContext, forKey: "study.showContext") }
    }
}

/// 记忆卡编辑面板的草稿
struct CardDraft: Identifiable {
    let id = UUID()
    var card: Card
    var tagsText: String = ""
    var error: String?
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
    static let sectionNamesKey = "cards.sectionNames"

    /// 背面栏目：最近用过的名称在前，其后是常用名称
    static var sectionNames: [String] {
        let recent = UserDefaults.standard.stringArray(forKey: sectionNamesKey) ?? []
        var out: [String] = []
        for n in recent + CardSection.suggestedNames where !n.isEmpty && !out.contains(n) { out.append(n) }
        return Array(out.prefix(12))
    }

    static func rememberSectionNames(_ names: [String]) {
        let recent = UserDefaults.standard.stringArray(forKey: sectionNamesKey) ?? []
        var out: [String] = []
        for n in names + recent where !n.isEmpty && !out.contains(n) { out.append(n) }
        UserDefaults.standard.set(Array(out.prefix(12)), forKey: sectionNamesKey)
    }

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
    /// 全部摘录与未归类的明确分页（从 1 开始）。
    var page = 1
    var pageInput = "1"
    var isLoading = false
    var loadID = UUID()
    var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }
    /// 多选的摘录 id
    var selection: Set<Int64> = []
    /// 1.7：列表按新条件载入后再选中的摘录（出处书页“按页码…→在列表中选中”）
    var pendingSelection: Set<Int64>?
    /// 上一次加载用的筛选条件（变化时回到第一页）
    var lastQuery: HighlightQuery?
    /// 组合筛选（出处、多个标签、日期、只看收藏）
    var extra = ListFilter()
    /// 筛选条是否展开
    var showFilters = false
    /// 筛选条件属于哪个列表（切换列表时清空）
    var extraOwner = ""
    /// 1.6：出处书页按页码排序（否则按录入时间，新的在前）
    var sourceByPage: Bool = UserDefaults.standard.object(forKey: "list.sourceByPage") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceByPage, forKey: "list.sourceByPage") }
    }

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
    /// 1.7：逐条做填空卡时的进度，如“第 2 / 12 条”
    var progress: String?
    var numbers: [Int] { AnkiContent.clozeNumbers(text) }
}
