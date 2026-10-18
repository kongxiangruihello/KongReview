import SwiftUI
import WebKit
import Observation
import KongReviewCore

// MARK: - 网页存档页（列表 / 阅读器）

@MainActor
@Observable
final class ArticleListState {
    /// 保留旧接口供既有调用使用；实际每页数量来自当前列表设置。
    static let pageSize = 200
    private struct Snapshot: Codable { var query: String; var page: Int; var pageSize: Int; var sort: ArticleSort; var anchorID: Int64? }
    private let persistence: ListPositionPersistence
    private var restoringSnapshot = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            resetCriteria()
        }
    }
    var selectedPageSize = 200 {
        didSet {
            guard selectedPageSize != oldValue else { return }
            let normalized = ListPositionPersistence.normalizedPageSize(selectedPageSize)
            if normalized != selectedPageSize { selectedPageSize = normalized }
            resetCriteria()
        }
    }
    var sort: ArticleSort = .savedNewest { didSet { if sort != oldValue { resetCriteria() } } }
    var items: [Article] = []
    var highlightCounts: [Int64: Int] = [:]
    var total = 0
    var page = 1
    var pageInput = "1"
    var anchorID: Int64?
    var isLoading = true
    var loadID = UUID()
    var pageCount: Int { max(1, (total + selectedPageSize - 1) / selectedPageSize) }

    init(persistence: ListPositionPersistence? = nil) {
        self.persistence = persistence ?? ListPositionPersistence()
        restoringSnapshot = true
        if let saved = self.persistence.load(Snapshot.self, for: "articles") {
            query = saved.query
            selectedPageSize = ListPositionPersistence.normalizedPageSize(saved.pageSize)
            sort = saved.sort
            page = max(1, saved.page)
            pageInput = String(page)
            anchorID = saved.anchorID
        }
        restoringSnapshot = false
    }

    private func resetCriteria() {
        guard !restoringSnapshot else { return }
        page = 1; pageInput = "1"; total = 0; items = []; highlightCounts = [:]
        anchorID = nil
        loadID = UUID(); isLoading = true
        persist()
    }

    private func persist() {
        persistence.save(Snapshot(query: query, page: page, pageSize: selectedPageSize, sort: sort, anchorID: anchorID), for: "articles")
    }

    func rememberArticle(_ id: Int64?) {
        guard let id, items.contains(where: { $0.id == id }) else { return }
        anchorID = id
        persist()
    }

    func goToPage(_ requested: Int) {
        let target = min(max(1, requested), pageCount)
        pageInput = String(target)
        guard target != page else { return }
        anchorID = nil
        page = target
        items = []
        highlightCounts = [:]
        loadID = UUID()
        isLoading = true
        persist()
    }

    /// 搜索、翻页或更新后，早先的请求不能把列表换回旧内容。
    @discardableResult
    func apply(_ result: ArticlePage, requestID: UUID, query requestedQuery: String, page requestedPage: Int,
               pageSize requestedPageSize: Int? = nil, sort requestedSort: ArticleSort? = nil) -> Bool {
        guard loadID == requestID, query == requestedQuery, page == requestedPage,
              requestedPageSize == nil || selectedPageSize == requestedPageSize,
              requestedSort == nil || sort == requestedSort else { return false }
        total = result.total
        items = result.items
        highlightCounts = result.highlightCounts
        page = result.page
        pageInput = String(result.page)
        persist()
        return true
    }
}

struct ArticlesView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let article = store.openArticle {
            ArticleReaderView(article: article)
        } else {
            ArticleListView()
        }
    }
}

struct ArticleListView: View {
    @Environment(LibraryStore.self) private var store
    private var state: ArticleListState { store.articleList }

    private struct LoadKey: Hashable {
        var query: String
        var page: Int
        var pageSize: Int
        var sort: ArticleSort
        var revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.items.isEmpty {
                if state.isLoading {
                    ProgressView("正在载入网页存档…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(state.query.isEmpty ? "还没有存档的网页" : "没有找到", systemImage: "globe")
                    } description: {
                        Text("点右上角“存档网页”，粘贴网址即可。也可以在浏览器里用“整页存档”书签一键发送（见 设置 → 摘录）。")
                    } actions: {
                        Button("存档网页…") { store.showAddArticle() }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                List(state.items) { a in
                    ArticleRow(article: a, highlightCount: a.id.flatMap { state.highlightCounts[$0] } ?? 0)
                        .id(a.id ?? -1)
                        .contentShape(Rectangle())
                        .onTapGesture { store.open(a) }
                        .contextMenu {
                            Button("阅读") { store.open(a) }
                            Button("在浏览器中打开原网页") {
                                if let u = URL(string: a.url) { NSWorkspace.shared.open(u) }
                            }
                            Divider()
                            Button("删除存档（保留摘录）…", role: .destructive) { store.articlePendingDeletion = a }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onAppear { restoreArticleAnchor(proxy) }
                .onChange(of: state.items.map(\.id)) { _, _ in restoreArticleAnchor(proxy) }
                }
            }
            Divider()
            pageControls
        }
        .navigationTitle("网页存档")
        .navigationSubtitle("共 \(state.total) 篇")
        .searchable(text: Bindable(state).query, prompt: "搜索标题、网站、作者")
        .task(id: LoadKey(query: state.query, page: state.page, pageSize: state.selectedPageSize, sort: state.sort, revision: store.revision)) {
            await load()
        }
        .toolbar {
            ToolbarItem {
                Picker("排序", selection: Bindable(state).sort) {
                    ForEach(ArticleSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 120)
            }
            ToolbarItem {
                Button {
                    store.showAddArticle()
                } label: {
                    Label("存档网页", systemImage: "plus")
                }
                .help("存档网页（⌘L）")
            }
        }
    }

    private func restoreArticleAnchor(_ proxy: ScrollViewProxy) {
        if let anchor = state.anchorID, state.items.contains(where: { $0.id == anchor }) {
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .center) }
        }
    }

    private var pageControls: some View {
        HStack(spacing: 10) {
            Picker("每页", selection: Bindable(state).selectedPageSize) {
                ForEach(ListPositionPersistence.pageSizes, id: \.self) { Text("\($0) 篇").tag($0) }
            }
            .frame(width: 110)
            Text(pageRangeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { state.goToPage(state.page - 1) } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(state.page <= 1 || state.isLoading)
            Text("第 \(state.page) / \(state.pageCount) 页").monospacedDigit()
            Button { state.goToPage(state.page + 1) } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(state.page >= state.pageCount || state.isLoading)
            TextField("页码", text: Bindable(state).pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.center)
                .onSubmit(jumpToPage)
                .accessibilityLabel("跳转到页码")
            Button("跳转", action: jumpToPage).disabled(state.isLoading)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pageRangeLabel: String {
        guard state.total > 0 else { return "共 0 篇" }
        let first = (state.page - 1) * state.selectedPageSize + 1
        let last = min(state.page * state.selectedPageSize, state.total)
        return "第 \(first)–\(last) 篇，共 \(state.total) 篇"
    }

    private func jumpToPage() {
        state.goToPage(Int(state.pageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? state.page)
    }

    @MainActor
    private func load() async {
        let requestedQuery = state.query
        let requestedPage = state.page
        let requestedPageSize = state.selectedPageSize
        let requestedSort = state.sort
        let requestedRevision = store.revision
        let requestID = UUID()
        state.loadID = requestID
        state.isLoading = true
        defer { if state.loadID == requestID { state.isLoading = false } }
        do {
            let result = try await store.db.articlePage(query: requestedQuery, page: requestedPage,
                                                       pageSize: requestedPageSize, sort: requestedSort)
            guard !Task.isCancelled, store.revision == requestedRevision else { return }
            state.apply(result, requestID: requestID, query: requestedQuery, page: requestedPage,
                        pageSize: requestedPageSize, sort: requestedSort)
        } catch {
            if !Task.isCancelled, state.loadID == requestID { store.report(error) }
        }
    }
}

struct ArticleRow: View {
    let article: Article
    let highlightCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if !article.isRead {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                }
                Text(article.title).font(.headline).lineLimit(2)
            }
            if let ex = article.excerpt {
                Text(ex).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 10) {
                Text([article.siteName ?? URL(string: article.url)?.host, article.author].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                Text("约 \(article.readingMinutes) 分钟")
                if highlightCount > 0 {
                    Label("\(highlightCount)", systemImage: "highlighter")
                }
                Spacer()
                Text(article.savedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 阅读器

struct ArticleReaderView: View {
    @Environment(LibraryStore.self) private var store
    @FocusState private var findFocused: Bool
    let article: Article
    private var reading: ArticleReadingState { store.articleReading }

    var body: some View {
        let _ = store.revision
        let marks = ((try? store.db.highlights(sourceId: article.sourceId)) ?? [])
            .compactMap { h in h.id.map { ReaderPage.Mark(id: $0, text: h.text) } }
        VStack(spacing: 0) {
            if reading.showsFind {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("在正文中查找", text: Bindable(reading).query)
                        .textFieldStyle(.roundedBorder)
                        .focused($findFocused)
                        .onSubmit { reading.move(1) }
                        .onExitCommand { reading.closeFind() }
                    Text(reading.query.isEmpty ? "" : reading.matchCount == 0 ? "无匹配" : "\(reading.currentMatch) / \(reading.matchCount)")
                        .font(.caption).monospacedDigit().frame(minWidth: 60)
                    Button { reading.move(-1) } label: { Image(systemName: "chevron.up") }
                        .help("上一处").disabled(reading.matchCount == 0)
                    Button { reading.move(1) } label: { Image(systemName: "chevron.down") }
                        .help("下一处").disabled(reading.matchCount == 0)
                    Button { reading.closeFind() } label: { Image(systemName: "xmark") }
                        .help("关闭查找")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
            }
            ReaderWebView(article: article, marks: marks, store: store,
                          findQuery: reading.query, findRevision: reading.searchRevision)
        }
            .navigationTitle(article.title)
            .navigationSubtitle(marks.isEmpty ? "选中文字后按 H 摘录" : "已摘录 \(marks.count) 条 · 选中文字后按 H 摘录")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        store.closeArticle()
                    } label: {
                        Label("返回列表", systemImage: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                }
                ToolbarItemGroup {
                    Button {
                        reading.showsFind = true
                        findFocused = true
                    } label: { Label("文内查找", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("在正文中查找（⌘F）")
                    Button {
                        ReaderBridge.shared.sendSelection()
                    } label: {
                        Label("摘录选中文字", systemImage: "highlighter")
                    }
                    .help("摘录选中文字（H）")
                    Button {
                        if let u = URL(string: article.url) { NSWorkspace.shared.open(u) }
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                    }
                    Button {
                        if let id = article.id {
                            store.articleSourceDraft = ArticleSourceDraft(articleId: id, html: article.contentHTML)
                        }
                    } label: {
                        Label("编辑正文", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("以 HTML 编辑存档正文（删去无关段落、改错字等）")
                    Button {
                        store.selection = article.sourceId.map(SidebarItem.source) ?? .all
                        store.openArticle = nil
                    } label: {
                        Label("查看本文摘录", systemImage: "text.quote")
                    }
                    .disabled(marks.isEmpty)
                }
            }
    }
}

/// 工具栏按钮通过它调用当前阅读器里的脚本
@MainActor
final class ReaderBridge {
    static let shared = ReaderBridge()
    weak var webView: WKWebView?

    func sendSelection() {
        webView?.evaluateJavaScript("window.kgSendSelection && window.kgSendSelection();", completionHandler: nil)
    }
}

struct ReaderWebView: NSViewRepresentable {
    let article: Article
    let marks: [ReaderPage.Mark]
    let store: LibraryStore
    let findQuery: String
    let findRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "kg")
        // 图片经由本地处理器取：先查缓存，没有再带合适的 Referer 下载（解决防盗链、http 图片不显示）
        LocalSchemeHandler.register(on: config, store: store)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.allowsMagnification = true
        ReaderBridge.shared.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        let needsLoad = c.loadedArticleID != article.id || c.loadedContentHTML != article.contentHTML
        if needsLoad, c.isLoaded { c.capturePosition(wv) }
        c.store = store
        c.article = article
        c.marks = marks
        ReaderBridge.shared.webView = wv
        if needsLoad {
            c.loadedArticleID = article.id
            c.loadedContentHTML = article.contentHTML
            c.isLoaded = false
            c.appliedMarks = nil
            c.session = UUID().uuidString
            c.appliedQuery = nil
            c.appliedSearchRevision = -1
            c.navigation = wv.loadHTMLString(ReaderPage.html(for: article), baseURL: URL(string: article.url))
        } else if c.isLoaded {
            if c.appliedMarks != marks { c.applyMarks(wv) }
            c.applyFind(wv)
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        coordinator.capturePosition(wv)
        wv.evaluateJavaScript("window.kgReader && window.kgReader.dispose();", completionHandler: nil)
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "kg")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var store: LibraryStore?
        var article: Article?
        var marks: [ReaderPage.Mark] = []
        var appliedMarks: [ReaderPage.Mark]?
        var loadedArticleID: Int64?
        var loadedContentHTML: String?
        var isLoaded = false
        var navigation: WKNavigation?
        var session = UUID().uuidString
        var appliedQuery: String?
        var appliedSearchRevision = -1

        func applyMarks(_ wv: WKWebView) {
            appliedMarks = marks
            wv.evaluateJavaScript(ReaderPage.applyScript(marks) + "window.kgReader && window.kgReader.refresh();", completionHandler: nil)
        }

        func applyFind(_ wv: WKWebView) {
            guard let reading = store?.articleReading else { return }
            guard appliedQuery != reading.query || appliedSearchRevision != reading.searchRevision else { return }
            let direction = appliedQuery == reading.query ? reading.moveDirection : 0
            appliedQuery = reading.query
            appliedSearchRevision = reading.searchRevision
            wv.evaluateJavaScript(ArticleReaderScript.find(reading.query, direction: direction), completionHandler: nil)
        }

        func capturePosition(_ wv: WKWebView) {
            guard let reading = store?.articleReading, let id = article?.id else { return }
            let capturedSession = session
            wv.evaluateJavaScript("window.kgReader ? {session:window.kgReader.session,position:window.kgReader.snapshot()} : null") { result, _ in
                guard let envelope = result as? [String: Any], envelope["session"] as? String == capturedSession,
                      let value = envelope["position"] as? [String: Any], let position = Self.position(value) else { return }
                MainActor.assumeIsolated { reading.save(position, for: id) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let expected = self.navigation, navigation === expected else { return }
            isLoaded = true
            applyMarks(webView)
            let installedSession = session
            let position = store?.articleReading.position(for: article?.id)
            webView.evaluateJavaScript(ArticleReaderScript.install(position: position, session: session)) { [weak self, weak webView] _, error in
                guard error == nil, let self, let webView else { return }
                MainActor.assumeIsolated {
                    guard self.isLoaded, self.session == installedSession else { return }
                    self.appliedQuery = nil
                    self.appliedSearchRevision = -1
                    self.applyFind(webView)
                }
            }
        }

        /// 正文里的链接用默认浏览器打开，阅读器本身不跳走
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String,
                  let store, let article else { return }
            switch type {
            case "readerPosition":
                guard body["session"] as? String == session,
                      let value = body["position"] as? [String: Any], let position = Self.position(value) else { return }
                store.articleReading.save(position, for: article.id)
            case "readerFind":
                guard body["session"] as? String == session,
                      body["query"] as? String == store.articleReading.query else { return }
                store.articleReading.matchCount = max(0, (body["total"] as? NSNumber)?.intValue ?? 0)
                store.articleReading.currentMatch = max(0, (body["current"] as? NSNumber)?.intValue ?? 0)
            case "highlight":
                guard isLoaded else { return }
                if let text = body["text"] as? String {
                    store.addHighlight(from: article, text: text)
                }
            case "open":
                guard isLoaded else { return }
                if let id = (body["id"] as? NSNumber)?.int64Value,
                   let h = try? store.db.highlights(ids: [id]).first {
                    store.edit(h)
                }
            default:
                break
            }
        }

        private static func position(_ body: [String: Any]) -> ArticleReadingPosition? {
            guard let ratio = (body["ratio"] as? NSNumber)?.doubleValue, ratio.isFinite else { return nil }
            return ArticleReadingPosition(ratio: ratio, anchor: body["anchor"] as? String ?? "",
                                          anchorOffset: (body["anchorOffset"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
}

/// WKUserContentController 会强引用消息处理者；用弱引用中转，避免阅读器关闭后对象无法释放
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - 添加网页

struct AddArticleView: View {
    @Environment(LibraryStore.self) private var store

    private var urlBinding: Binding<String> {
        Binding(
            get: { store.addArticleDraft?.urlText ?? "" },
            set: { store.addArticleDraft?.urlText = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("存档网页").font(.title2.bold())
            Text("粘贴文章网址。KongReview 会打开网页、提取正文并保存一份副本，之后在应用里阅读、划线；原网页改版或删除也不影响。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://", text: urlBinding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.saveArticle(from: urlBinding.wrappedValue) }
            if let hint = store.addArticleDraft?.hint {
                Label(hint, systemImage: "safari").font(.caption).foregroundStyle(.secondary)
            }
            if let err = store.addArticleDraft?.error {
                Text(err).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let p = store.articleProgress {
                    ProgressView().controlSize(.small)
                    Text(p).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { store.addArticleDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("存档") { store.saveArticle(from: urlBinding.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(store.articleProgress != nil || urlBinding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}


// MARK: - 编辑存档正文（HTML / Markdown）

struct ArticleSourceEditorView: View {
    @Environment(LibraryStore.self) private var store

    private var html: Binding<String> {
        Binding(get: { store.articleSourceDraft?.html ?? "" }, set: { store.articleSourceDraft?.html = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑存档正文").font(.title2.bold())
            Text("直接编辑存档正文的 HTML 源码；标签、属性和链接按输入保存。已划下的摘录不受影响。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RichEditor(text:html,mode:.card,placeholder:"存档正文 HTML",minHeight:300,slot:"article-source").richEditorFrame()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.articleSourceDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.saveArticleSource()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .handCursor()
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }
}
