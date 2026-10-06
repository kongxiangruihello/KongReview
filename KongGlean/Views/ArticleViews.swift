import SwiftUI
import WebKit
import KongGleanCore

// MARK: - 网页存档页（列表 / 阅读器）

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

    var body: some View {
        let _ = store.revision
        let articles = (try? store.db.articles(query: store.list.query)) ?? []
        let counts = (try? store.db.articleHighlightCounts()) ?? [:]
        Group {
            if articles.isEmpty {
                ContentUnavailableView {
                    Label(store.list.query.isEmpty ? "还没有存档的网页" : "没有找到", systemImage: "globe")
                } description: {
                    Text("点右上角“存档网页”，粘贴网址即可。也可以在浏览器里用“整页存档”书签一键发送（见 设置 → 摘录）。")
                } actions: {
                    Button("存档网页…") { store.showAddArticle() }
                }
            } else {
                List(articles) { a in
                    ArticleRow(article: a, highlightCount: a.id.flatMap { counts[$0] } ?? 0)
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
            }
        }
        .navigationTitle("网页存档")
        .navigationSubtitle("\(articles.count) 篇")
        .searchable(text: Bindable(store.list).query, prompt: "搜索标题、网站、作者")
        .toolbar {
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
    let article: Article

    var body: some View {
        let _ = store.revision
        let marks = ((try? store.db.highlights(sourceId: article.sourceId)) ?? [])
            .compactMap { h in h.id.map { ReaderPage.Mark(id: $0, text: h.text) } }
        ReaderWebView(article: article, marks: marks, store: store)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "kg")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.allowsMagnification = true
        ReaderBridge.shared.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.store = store
        c.article = article
        c.marks = marks
        ReaderBridge.shared.webView = wv
        if c.loadedArticleID != article.id {
            c.loadedArticleID = article.id
            c.isLoaded = false
            c.appliedMarks = nil
            wv.loadHTMLString(ReaderPage.html(for: article), baseURL: URL(string: article.url))
        } else if c.isLoaded, c.appliedMarks != marks {
            c.applyMarks(wv)
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "kg")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var store: LibraryStore?
        var article: Article?
        var marks: [ReaderPage.Mark] = []
        var appliedMarks: [ReaderPage.Mark]?
        var loadedArticleID: Int64?
        var isLoaded = false

        func applyMarks(_ wv: WKWebView) {
            appliedMarks = marks
            wv.evaluateJavaScript(ReaderPage.applyScript(marks), completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            applyMarks(webView)
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
            case "highlight":
                if let text = body["text"] as? String {
                    store.addHighlight(from: article, text: text)
                }
            case "open":
                if let id = (body["id"] as? NSNumber)?.int64Value,
                   let h = try? store.db.highlights(ids: [id]).first {
                    store.edit(h)
                }
            default:
                break
            }
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
            Text("粘贴文章网址。KongGlean 会打开网页、提取正文并保存一份副本，之后在应用里阅读、划线；原网页改版或删除也不影响。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://", text: urlBinding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.saveArticle(from: urlBinding.wrappedValue) }
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
                    .disabled(store.articleProgress != nil || urlBinding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
