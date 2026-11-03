import AppKit
import KongReviewCore

/// 需要 AppKit / WebKit 的文章操作（与 LibraryStore 分开，便于在命令行测试数据层）
extension LibraryStore {

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
