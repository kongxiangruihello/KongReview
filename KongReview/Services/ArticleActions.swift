import AppKit
import KongReviewCore

/// 需要 AppKit / WebKit 的文章操作（与 LibraryStore 分开，便于在命令行测试数据层）
extension LibraryStore {
    /// 打开“存档网页”面板：优先填入浏览器当前页面的网址，其次是剪贴板里的网址
    func showAddArticle() {
        var draft = AddArticleDraft()
        if let page = BrowserWatcher.shared.currentPage() {
            draft.urlText = page.url.absoluteString
            draft.hint = "已自动填入 \(page.browser) 当前页面"
        } else if let clip = NSPasteboard.general.string(forType: .string),
           let url = CaptureRequest.normalizeWebURL(clip), clip.lowercased().hasPrefix("http") {
            draft.urlText = url.absoluteString
            draft.hint = "已填入剪贴板里的网址"
        }
        addArticleDraft = draft
    }

    /// 抓取并存档网页；同一网址已存档时直接打开
    func saveArticle(from raw: String) {
        guard let url = CaptureRequest.normalizeWebURL(raw) else {
            addArticleDraft?.error = "网址格式不对。"
            return
        }
        if let existing = try? db.article(url: url.absoluteString) {
            addArticleDraft = nil
            open(existing)
            return
        }
        guard articleProgress == nil else { return }
        articleProgress = "正在打开 \(url.host ?? url.absoluteString)…"
        addArticleDraft?.error = nil
        Task { @MainActor in
            do {
                let extraction = try await WebArticleFetcher.fetch(url)
                articleProgress = "正在保存…"
                let saved = try db.saveArticle(extraction.makeArticle(url: url.absoluteString))
                articleProgress = nil
                addArticleDraft = nil
                reload()
                open(saved)
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
