import AppKit
import KongReviewCore

/// 需要 AppKit / WebKit 的网页操作（与 LibraryStore 分开，便于在命令行测试数据层）
extension LibraryStore {
    /// 6.3.3：打开“添加网页”面板——优先填入浏览器当前页面的网址，其次是剪贴板里的网址
    func showAddWebPage() {
        guard !fullBackupBusy else { return }
        var draft = AddArticleDraft()
        if let page = BrowserWatcher.shared.currentPage() {
            draft.urlText = page.url.absoluteString
            draft.hint = "已自动填入 \(page.browser) 当前页面"
        } else if let clip = NSPasteboard.general.string(forType: .string),
                  let url = CaptureRequest.normalizeWebURL(clip), clip.lowercased().hasPrefix("http") {
            draft.urlText = url.absoluteString
            draft.hint = "已自动填入剪贴板里的网址"
        }
        addArticleDraft = draft
    }

    /// 6.3.3：打开网页、提取正文，整篇存为一条摘录（出处为这个网页），存后打开这个出处
    func saveWebPage(from raw: String) {
        guard let url = CaptureRequest.normalizeWebURL(raw) else {
            addArticleDraft?.error = "网址格式不对。"
            return
        }
        guard articleProgress == nil else { return }
        articleProgress = "正在打开 \(url.host ?? url.absoluteString)…"
        addArticleDraft?.error = nil
        Task { @MainActor in
            do {
                let extraction = try await WebArticleFetcher.fetch(url)
                articleProgress = "正在保存…"
                let saved = try db.saveWebPage(extraction, url: url.absoluteString)
                articleProgress = nil
                addArticleDraft = nil
                reload()
                if let sid = saved.source.id { selection = .source(sid) }
                let length = ArticleText.wordCount(saved.highlight.text)
                if saved.existed {
                    infoMessage = "这个网页以前已存过（《\(saved.source.title)》），没有重复添加。"
                } else {
                    infoMessage = "已把《\(saved.source.title)》整篇存为一条摘录（约 \(length) 字），出处是这个网页。"
                        + (saved.highlight.text.count >= AnnotateSettings.minimumRawLength
                           ? "它已进入“今日标注”的待标文章（按录入先后轮到）。" : "正文不足 \(AnnotateSettings.minimumRawLength) 字，不进“今日标注”。")
                }
            } catch {
                articleProgress = nil
                if addArticleDraft != nil {
                    addArticleDraft?.error = error.localizedDescription
                } else {
                    report(error)
                }
            }
        }
    }
}
