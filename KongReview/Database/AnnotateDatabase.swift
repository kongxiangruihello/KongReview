import Foundation
import GRDB
import KongReviewCore

// MARK: - 6.0.4：每天标注几篇文章
//
// “全部摘录”里有不少整篇文章（多从 Readwise 导入），存成了一条很长的摘录，里面还没有划出要点。
// 今日试卷每天从中抽几篇（默认 5 篇，设置里可改，0 为不出）。打开一篇，在正文里选中一段按 H（或点“划为摘录”），
// 这一段就存为同一出处下的一条新摘录（原文不动），并在正文里标黄；看完点“这篇标完了”。
// 文章：原文至少 1000 字、去掉标记后至少 600 字、未删除、未弃置。
// 已标注：在这里标过（article_annotation 有记录），或同一出处下已有短摘录、其文字出现在这篇正文里（以前在 Readwise 等处划过的；
// 在这里从别的文章划出的不算，免得同一本书里重复的句子把整本书都判成标过）。
// 每天的篇目在当天第一次组卷时抽定（以日期为种子随机），存在 app_progress“annotate.<日期>”；划过或标完即算今天这篇完成。

/// 今天要标注的一篇
struct AnnotateItem: Identifiable, Equatable, Sendable {
    var id: Int64
    var sourceId: Int64?
    var title: String
    var author: String
    /// 去掉标记后的字数
    var length: Int
    /// 今天在这篇里划了几条
    var marksToday: Int
    /// 在这里一共划了几条
    var marks: Int
    /// 今天点过“这篇标完了”
    var finishedToday: Bool
    /// 以前点过标完（今天又抽到不会发生，留作显示）
    var finished: Bool
    /// 今天算完成：划过至少一条，或点了标完
    var doneToday: Bool { marksToday > 0 || finishedToday }
}

/// 今天的标注任务
struct AnnotateToday: Equatable, Sendable {
    var items: [AnnotateItem] = []
    /// 今天这几篇之外，还没在这里标过的长文篇数（不扣除以前在别处划过的，故为约数）
    var remaining = 0
    var done: Int { items.filter(\.doneToday).count }
    var left: Int { items.count - done }
    static let empty = AnnotateToday()
}

enum AnnotateSettings {
    static let perDayKey = "annotate.perDay"
    static let defaultPerDay = 5
    /// 每天标注几篇（0 为不出，至多 20）
    static func perDay(_ defaults: UserDefaults = .standard) -> Int {
        max(0, min(20, defaults.object(forKey: perDayKey) as? Int ?? defaultPerDay))
    }
    /// 原文（含标记）至少多少字才算文章
    static let minimumRawLength = 1000
    /// 去掉标记后至少多少字
    static let minimumPlainLength = 600
}

extension AppDatabase {
    /// v26：文章标注记录（article_annotation：每篇一行；article_mark：从哪篇划出的哪条摘录）
    static func installAnnotate(in db: Database) throws {
        try db.create(table: "article_annotation", ifNotExists: true) { t in
            t.column("highlightId", .integer).primaryKey()
                .references("highlight", onDelete: .cascade)
            t.column("marks", .integer).notNull().defaults(to: 0)
            t.column("firstAt", .datetime)
            t.column("lastMarkAt", .datetime)
            t.column("finishedAt", .datetime)
        }
        try db.create(table: "article_mark", ifNotExists: true) { t in
            t.column("markId", .integer).primaryKey()
                .references("highlight", onDelete: .cascade)
            t.column("articleId", .integer).notNull().indexed()
                .references("highlight", onDelete: .cascade)
        }
    }

    static func annotateKey(_ day: String) -> String { "annotate." + day }

    /// 去掉标签、空白、标点与符号，只留文字，用来判断一段是否出现在正文里
    nonisolated static func annotateNormalize(_ s: String) -> String {
        let plain = Markdown.plainText(fromHTML: s)
        var out = String.UnicodeScalarView()
        for u in plain.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u)
            && !CharacterSet.punctuationCharacters.contains(u) && !CharacterSet.symbols.contains(u) {
            out.append(u)
        }
        return String(out)
    }

    /// 同一出处下以前划过的短摘录是否出现在这篇正文里（取每条的前 30 个字比对，6 个字以下的不算）
    nonisolated static func annotateAlreadyMarked(body: String, shorts: [String]) -> Bool {
        guard !shorts.isEmpty else { return false }
        let b = annotateNormalize(body) as NSString
        for s in shorts {
            let piece = String(annotateNormalize(s).prefix(30))
            if piece.count >= 6 && b.range(of: piece, options: .literal).location != NSNotFound { return true }
        }
        return false
    }

    /// 还没在这里标过的长文（只按长度、删除、弃置与标注记录筛，便宜），录入早的在前
    static func annotateCandidates(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT h.id FROM highlight h
            WHERE h.deletedAt IS NULL AND h.isDiscarded = 0 AND length(h.text) >= ?
              AND h.id NOT IN (SELECT highlightId FROM article_annotation)
            ORDER BY h.createdAt, h.id
            """, arguments: [AnnotateSettings.minimumRawLength])
    }

    /// 当天抽定的篇目（题目、字数一并存下，之后刷新只查标注进度，不再读正文）
    struct AnnotatePlan: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var id: Int64
            var title: String
            var author: String
            var length: Int
        }
        var entries: [Entry] = []
        /// 抽的时候还没在这里标过的长文篇数
        var pool = 0
        /// 当天按几篇抽过（库里不够时不再反复抽；设置调得更多才补）
        var requested = 0
    }

    /// 今天的篇目：已抽定就沿用（设置调多了就补足，调少了只显示前几篇）；否则从还没标注的文章里按日期随机抽
    func annotateToday(count: Int = AnnotateSettings.perDay(), now: Date = Date()) throws -> AnnotateToday {
        let key = Self.annotateKey(Self.revisitDay(now))
        let (start, end) = Self.dayBounds(now)
        return try writer.write { db in
            let saved = try Data.fetchOne(db, sql: "SELECT payload FROM app_progress WHERE key = ?", arguments: [key])
                .flatMap { try? JSONDecoder().decode(AnnotatePlan.self, from: $0) }
            var plan = saved ?? AnnotatePlan()
            if plan.entries.count < count && count > plan.requested {
                plan.requested = count
                let candidates = try Self.annotateCandidates(db)
                var rng = SeededGenerator.forDay(now)
                let taken = Set(plan.entries.map(\.id))
                for id in candidates.filter({ !taken.contains($0) }).shuffled(using: &rng) where plan.entries.count < count {
                    if let entry = try Self.annotateEntry(db, id: id) { plan.entries.append(entry) }
                }
                plan.pool = candidates.count + plan.entries.filter { !candidates.contains($0.id) }.count
                if plan != saved {
                    try db.execute(sql: "INSERT INTO app_progress(key,payload,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload, updatedAt=excluded.updatedAt",
                                   arguments: [key, try JSONEncoder().encode(plan), now])
                }
            }
            var items: [AnnotateItem] = []
            for e in plan.entries.prefix(count) {
                guard let row = try Row.fetchOne(db, sql: "SELECT sourceId, deletedAt FROM highlight WHERE id = ?", arguments: [e.id]),
                      (row["deletedAt"] as Date?) == nil else { continue }
                var marks = 0, finished = false, finishedToday = false
                if let a = try Row.fetchOne(db, sql: "SELECT marks, finishedAt FROM article_annotation WHERE highlightId = ?", arguments: [e.id]) {
                    marks = a["marks"]
                    if let f: Date = a["finishedAt"] { finished = true; finishedToday = f >= start && f < end }
                }
                let marksToday = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM article_mark m JOIN highlight x ON x.id = m.markId
                    WHERE m.articleId = ? AND x.deletedAt IS NULL AND x.createdAt >= ? AND x.createdAt < ?
                    """, arguments: [e.id, start, end]) ?? 0
                items.append(AnnotateItem(id: e.id, sourceId: row["sourceId"], title: e.title, author: e.author, length: e.length,
                                          marksToday: marksToday, marks: marks, finishedToday: finishedToday, finished: finished))
            }
            // 今天这几篇之外，还没在这里标过的长文（含以前在别处划过的，故为约数）
            let remaining = max(0, plan.pool - plan.entries.count)
            return AnnotateToday(items: items, remaining: remaining)
        }
    }

    /// 这一篇能不能出（够长，且以前没在别处划过）；能出就取题目、作者、字数
    static func annotateEntry(_ db: Database, id: Int64) throws -> AnnotatePlan.Entry? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT h.sourceId, h.text, s.title, s.author FROM highlight h LEFT JOIN source s ON s.id = h.sourceId WHERE h.id = ?
            """, arguments: [id]) else { return nil }
        let text: String = row["text"]
        let plain = Markdown.plainText(fromHTML: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.count >= AnnotateSettings.minimumPlainLength else { return nil }
        if let sid: Int64 = row["sourceId"] {
            let shorts = try String.fetchAll(db, sql: """
                SELECT text FROM highlight WHERE sourceId = ? AND id != ? AND deletedAt IS NULL AND length(text) < ?
                  AND id NOT IN (SELECT markId FROM article_mark)
                """, arguments: [sid, id, AnnotateSettings.minimumRawLength])
            if annotateAlreadyMarked(body: text, shorts: shorts) { return nil }
        }
        return .init(id: id, title: annotateTitle(sourceTitle: row["title"], plain: plain), author: row["author"] ?? "", length: plain.count)
    }

    /// 题目：正文开头像标题的一行（不长于 40 字）优先，否则用出处名，再否则取开头
    nonisolated static func annotateTitle(sourceTitle: String?, plain: String) -> String {
        let firstLine = plain.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#*>_ \t　")) } ?? ""
        let source = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty && firstLine.count <= 40 && firstLine != source {
            return source.isEmpty ? firstLine : firstLine + "（" + source + "）"
        }
        if !source.isEmpty { return source }
        return String(firstLine.prefix(40)) + (firstLine.count > 40 ? "…" : "")
    }

    /// 在文章里划出一段：存为同一出处下的新摘录（位置随原文），记下来自哪篇
    @discardableResult
    func addAnnotationMark(articleId: Int64, text: String, now: Date = Date()) throws -> Highlight? {
        let clean = ArticleText.cleanSelection(text)
        guard !clean.isEmpty else { return nil }
        return try writer.write { db in
            guard let article = try Highlight.fetchOne(db, key: articleId) else { return nil }
            var h = Highlight(sourceId: article.sourceId, text: clean, location: article.location, createdAt: now, updatedAt: now)
            try h.insert(db)
            try db.execute(sql: "INSERT OR IGNORE INTO article_mark(markId, articleId) VALUES (?, ?)", arguments: [h.id, articleId])
            try db.execute(sql: """
                INSERT INTO article_annotation(highlightId, marks, firstAt, lastMarkAt) VALUES (?, 1, ?, ?)
                ON CONFLICT(highlightId) DO UPDATE SET marks = marks + 1, lastMarkAt = excluded.lastMarkAt
                """, arguments: [articleId, now, now])
            return h
        }
    }

    /// 这篇标完了（一条也没划也可以）
    func finishAnnotation(articleId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO article_annotation(highlightId, marks, firstAt, finishedAt) VALUES (?, 0, ?, ?)
                ON CONFLICT(highlightId) DO UPDATE SET finishedAt = excluded.finishedAt
                """, arguments: [articleId, now, now])
        }
    }

    /// 正文里要标黄的摘录：在这里从这篇划出的，以及同一出处下的短摘录（文字不在正文里的标不上，无妨）
    func annotationMarks(articleId: Int64) throws -> [ReaderPage.Mark] {
        try writer.read { db in
            guard let article = try Highlight.fetchOne(db, key: articleId) else { return [] }
            var ids = Set(try Int64.fetchAll(db, sql: "SELECT markId FROM article_mark WHERE articleId = ?", arguments: [articleId]))
            if let sid = article.sourceId {
                ids.formUnion(try Int64.fetchAll(db, sql: """
                    SELECT id FROM highlight WHERE sourceId = ? AND id != ? AND length(text) < ? AND deletedAt IS NULL
                    """, arguments: [sid, articleId, AnnotateSettings.minimumRawLength]))
            }
            guard !ids.isEmpty else { return [] }
            return try Highlight.filter(keys: Array(ids)).filter(Column("deletedAt") == nil).order(Column("id")).fetchAll(db)
                .compactMap { h in h.id.map { ReaderPage.Mark(id: $0, text: Markdown.plainText(fromHTML: Markdown.richHTML(h.text))) } }
        }
    }

    /// 打开标注用的阅读页：把这条长摘录当作一篇文章（id 取负，免得与网页存档混淆）
    func annotationArticle(articleId: Int64) throws -> Article? {
        try writer.read { db in
            guard let h = try Highlight.fetchOne(db, key: articleId) else { return nil }
            let source = try h.sourceId.flatMap { try Source.fetchOne(db, key: $0) }
            let html = Markdown.richHTML(h.text)
            let plain = Markdown.plainText(fromHTML: html)
            return Article(id: -articleId, sourceId: h.sourceId, url: source?.url ?? "",
                           title: Self.annotateTitle(sourceTitle: source?.title, plain: plain),
                           author: (source?.author).flatMap { $0.isEmpty ? nil : $0 }, siteName: h.location,
                           contentHTML: html, contentText: plain, wordCount: plain.count, savedAt: h.createdAt)
        }
    }
}
