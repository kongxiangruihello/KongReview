import Foundation
import GRDB
import KongReviewCore

/// 6.3.3：添加网页——整篇正文存为一条摘录，出处是这个网页（按网址认出处）
extension AppDatabase {
    struct SavedWebPage: Equatable {
        var highlight: Highlight
        var source: Source
        /// 这个网页以前已存过整篇，这次没有新增
        var existed: Bool
    }

    /// 存一个网页：出处按网址找（找不到就新建，不按标题并入同名出处）；同一网址下已有整篇正文就不再存
    func saveWebPage(_ extraction: ArticleExtraction, url fallbackURL: String, now: Date = Date()) throws -> SavedWebPage {
        let article = extraction.makeArticle(url: fallbackURL, now: now)
        return try writer.write { db in
            var source: Source
            if let found = try Source.filter(Column("url") == article.url).order(Column("id")).fetchOne(db) {
                source = found
            } else {
                source = Source(title: article.title, author: article.author ?? "", kind: .web, url: article.url)
                source.createdAt = now
                try source.insert(db)
            }
            let sid = source.id!
            // 同一网页已存过整篇（正文相同，或已有一条够长的长文）：直接用那一条
            if let existing = try Highlight
                .filter(Column("sourceId") == sid && Column("deletedAt") == nil)
                .filter(Column("text") == article.contentText || length(Column("text")) >= AnnotateSettings.minimumRawLength)
                .order(Column("id")).fetchOne(db) {
                return SavedWebPage(highlight: existing, source: source, existed: true)
            }
            var h = Highlight(sourceId: sid, text: article.contentText, createdAt: now, updatedAt: now)
            try h.insert(db)
            return SavedWebPage(highlight: h, source: source, existed: false)
        }
    }
}
