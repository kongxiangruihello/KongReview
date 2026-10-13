import XCTest
@testable import KongReviewCore

final class ReviewSchedulerTests: XCTestCase {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makeHighlights(_ n: Int, sourceId: Int64, startId: Int64 = 1) -> [Highlight] {
        (0..<n).map { i in
            Highlight(id: startId + Int64(i), sourceId: sourceId, text: "摘录 \(i)")
        }
    }

    func testSessionSizeAndNoDuplicates() {
        let hs = makeHighlights(50, sourceId: 1)
        var rng = SeededGenerator(seed: 42)
        let s = ReviewScheduler().makeSession(highlights: hs, sourceWeights: [:], now: now, using: &rng)
        XCTAssertEqual(s.regular.count, 10)
        XCTAssertEqual(Set(s.regular.compactMap(\.id)).count, 10)
    }

    func testSmallLibraryReturnsEverything() {
        let hs = makeHighlights(3, sourceId: 1)
        var rng = SeededGenerator(seed: 1)
        let s = ReviewScheduler().makeSession(highlights: hs, sourceWeights: [:], now: now, using: &rng)
        XCTAssertEqual(s.regular.count, 3)
    }

    func testDiscardedAndMutedSourcesNeverAppear() {
        var hs = makeHighlights(20, sourceId: 1)
        hs += makeHighlights(20, sourceId: 2, startId: 100)
        hs[0].isDiscarded = true
        var rng = SeededGenerator(seed: 7)
        let s = ReviewScheduler().makeSession(highlights: hs, sourceWeights: [2: 0], now: now, using: &rng)
        XCTAssertFalse(s.regular.contains { $0.sourceId == 2 })
        XCTAssertFalse(s.regular.contains { $0.id == 1 })
    }

    /// 摘录多的书被抽中的比例应大致与摘录数成正比（Readwise 的规则）
    func testProportionalToHighlightCount() {
        let hs = makeHighlights(80, sourceId: 1) + makeHighlights(20, sourceId: 2, startId: 1000)
        var config = ReviewScheduler.Config.default
        config.dailyCount = 1
        let scheduler = ReviewScheduler(config: config)
        var rng = SeededGenerator(seed: 2026)
        var countA = 0
        let trials = 4000
        for _ in 0..<trials {
            let s = scheduler.makeSession(highlights: hs, sourceWeights: [:], now: now, using: &rng)
            if s.regular.first?.sourceId == 1 { countA += 1 }
        }
        let share = Double(countA) / Double(trials)
        XCTAssertEqual(share, 0.8, accuracy: 0.03)
    }

    func testRecentlySurfacedIsPenalized() {
        let scheduler = ReviewScheduler()
        var h = Highlight(id: 1, sourceId: 1, text: "x")
        let fresh = scheduler.weight(of: h, sourceWeight: 1, now: now)
        h.lastSurfacedAt = now.addingTimeInterval(-day)
        let yesterday = scheduler.weight(of: h, sourceWeight: 1, now: now)
        h.lastSurfacedAt = now.addingTimeInterval(-30 * day)
        let monthAgo = scheduler.weight(of: h, sourceWeight: 1, now: now)
        XCTAssertEqual(fresh, 1)
        XCTAssertLessThan(yesterday, 0.05)
        XCTAssertEqual(monthAgo, 0.5, accuracy: 1e-9)
    }

    func testMasteryDueAfterHalfLife() {
        let scheduler = ReviewScheduler()
        var h = Highlight(id: 1, sourceId: 1, text: "学而时习之")
        h = scheduler.grade(.soon, h, now: now)
        XCTAssertTrue(scheduler.dueMastery(from: [h], now: now.addingTimeInterval(6 * day)).isEmpty)
        XCTAssertEqual(scheduler.dueMastery(from: [h], now: now.addingTimeInterval(7 * day)).count, 1)
        XCTAssertEqual(scheduler.recallProbability(of: h, now: now.addingTimeInterval(7 * day))!, 0.5, accuracy: 1e-9)
    }

    func testMasteryCardsGoLastAndAreNotDuplicated() {
        let scheduler = ReviewScheduler()
        var hs = makeHighlights(5, sourceId: 1)
        hs[2] = scheduler.grade(.soon, hs[2], now: now.addingTimeInterval(-10 * day))
        var rng = SeededGenerator(seed: 3)
        let s = scheduler.makeSession(highlights: hs, sourceWeights: [:], now: now, using: &rng)
        XCTAssertEqual(s.mastery.map(\.id), [3])
        XCTAssertFalse(s.regular.contains { $0.id == 3 })
        XCTAssertEqual(s.all.last?.id, 3)
    }

    func testSameDaySeedIsStable() {
        let hs = makeHighlights(100, sourceId: 1)
        var r1 = SeededGenerator.forDay(now)
        var r2 = SeededGenerator.forDay(now)
        let a = ReviewScheduler().makeSession(highlights: hs, sourceWeights: [:], now: now, using: &r1)
        let b = ReviewScheduler().makeSession(highlights: hs, sourceWeights: [:], now: now, using: &r2)
        XCTAssertEqual(a.regular.map(\.id), b.regular.map(\.id))
    }

    func testActions() {
        let scheduler = ReviewScheduler()
        let h = Highlight(id: 1, text: "x")
        let d = scheduler.apply(.discard, to: h, now: now)
        XCTAssertTrue(d.isDiscarded)
        XCTAssertEqual(d.surfacedCount, 1)
        XCTAssertEqual(d.lastSurfacedAt, now)
        XCTAssertTrue(scheduler.apply(.favorite, to: h, now: now).isFavorite)
        XCTAssertTrue(scheduler.addToMastery(h, now: now).isInMastery)
        XCTAssertFalse(scheduler.removeFromMastery(scheduler.addToMastery(h), now: now).isInMastery)
    }
}

final class CaptureRequestTests: XCTestCase {
    func testParsesFullLink() {
        let url = URL(string: "kongreview://add?text=%E5%AD%A6%E8%80%8C%E6%97%B6%E4%B9%A0%E4%B9%8B&title=%E8%AE%BA%E8%AF%AD&location=%E5%AD%A6%E8%80%8C%E7%AC%AC%E4%B8%80&tags=%E8%AE%BA%E8%AF%AD,%E5%AD%A6")!
        let r = CaptureRequest(url: url)
        XCTAssertEqual(r?.text, "学而时习之")
        XCTAssertEqual(r?.title, "论语")
        XCTAssertEqual(r?.location, "学而第一")
        XCTAssertEqual(r?.tags, ["论语", "学"])
    }

    func testRejectsMissingTextOrWrongScheme() {
        XCTAssertNil(CaptureRequest(url: URL(string: "kongreview://add?title=x")!))
        XCTAssertNil(CaptureRequest(url: URL(string: "https://add?text=x")!))
        XCTAssertNil(CaptureRequest(url: URL(string: "kongreview://open?text=x")!))
    }
}

final class ExporterTests: XCTestCase {
    func testTagParser() {
        XCTAssertEqual(TagParser.parse("论语, 仁 #礼，仁  孔子"), ["论语", "仁", "礼", "孔子"])
        XCTAssertEqual(TagParser.parse("   "), [])
    }

    func testCitation() {
        let s = Source(id: 1, title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980")
        let h = Highlight(id: 1, sourceId: 1, text: "x", location: "第1页")
        XCTAssertEqual(CitationFormatter.citation(for: h, source: s), "杨伯峻：《论语译注》，中华书局，1980年，第1页。")
    }

    func testMarkdownExportSkipsDiscarded() {
        let s = Source(id: 1, title: "论语", author: "")
        var a = Highlight(id: 1, sourceId: 1, text: "学而时习之\n不亦说乎", note: "按语", tags: ["论语"])
        a.translation = "学了又按时温习"
        var b = Highlight(id: 2, sourceId: 1, text: "弃置的条目")
        b.isDiscarded = true
        let md = MarkdownExporter.export(source: s, highlights: [a, b], exportedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(md.hasPrefix("---\ntitle: \"论语\"\n"))
        XCTAssertTrue(md.contains("> 学而时习之\n> 不亦说乎\n"))
        XCTAssertTrue(md.contains("译：学了又按时温习"))
        XCTAssertTrue(md.contains("按：按语"))
        XCTAssertTrue(md.contains("#论语"))
        XCTAssertFalse(md.contains("弃置的条目"))
        XCTAssertEqual(MarkdownExporter.fileName(for: Source(title: "a/b:c")), "a-b-c.md")
    }

    func testSearchHelpers() {
        XCTAssertFalse(SearchQuery.usesFullText("克己"))
        XCTAssertTrue(SearchQuery.usesFullText("克己复礼"))
        XCTAssertEqual(SearchQuery.fts5Phrase("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(SearchQuery.likePattern("50%_"), "%50\\%\\_%")
    }
}

final class V02Tests: XCTestCase {
    func testRoutes() {
        let add = CaptureRequest.route(for: URL(string: "kongreview://add?text=abc&title=T")!)
        XCTAssertEqual(add, .add(CaptureRequest(text: "abc", title: "T")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongreview://quick")!), .quick(nil))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongreview://quick?text=x")!), .quick(CaptureRequest(text: "x")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongreview://review")!), .review)
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongreview://add")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongreview://unknown")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "https://x.com")!))
    }

    func testBackupPolicy() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9))!
        XCTAssertEqual(BackupPolicy.fileName(for: d, calendar: cal), "review-2026-10-06.sqlite")
        XCTAssertTrue(BackupPolicy.needsBackup(existing: ["review-2026-10-05.sqlite"], now: d, calendar: cal))
        XCTAssertFalse(BackupPolicy.needsBackup(existing: ["review-2026-10-06.sqlite"], now: d, calendar: cal))
        let files = (1...35).map { String(format: "review-2026-09-%02d.sqlite", min($0, 30)) } .uniqued() + ["other.txt", "review-bad.sqlite"]
        let prune = BackupPolicy.filesToPrune(existing: files, keep: 28)
        XCTAssertEqual(prune, ["review-2026-09-01.sqlite", "review-2026-09-02.sqlite"])
        XCTAssertEqual(BackupPolicy.filesToPrune(existing: ["review-2026-09-01.sqlite"], keep: 30), [])
    }

    func testTrashPolicyAndDeletedExcludedFromReview() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(TrashPolicy.isExpired(deletedAt: now.addingTimeInterval(-29 * 86_400), now: now))
        XCTAssertTrue(TrashPolicy.isExpired(deletedAt: now.addingTimeInterval(-30 * 86_400), now: now))
        var h = Highlight(id: 1, text: "x")
        h.deletedAt = now
        XCTAssertTrue(h.isDeleted)
        XCTAssertEqual(ReviewScheduler().weight(of: h, sourceWeight: 1, now: now), 0)
        var rng = SeededGenerator(seed: 1)
        XCTAssertTrue(ReviewScheduler().makeSession(highlights: [h], sourceWeights: [:], now: now, using: &rng).regular.isEmpty)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

final class ReadwiseImportTests: XCTestCase {
    let sample = "\u{FEFF}Highlight,Book Title,Book Author,Amazon Book ID,Note,Color,Tags,Location Type,Location,Highlighted at,Document tags\r\n"
        + "\"学而时习之，不亦说乎？\",论语译注,杨伯峻,,开篇,yellow,\"论语, favorite\",page,1,2023-05-01 12:34:56+00:00,经部\r\n"
        + "\"多行\n摘录，含\"\"引号\"\"\",论语译注,杨伯峻,,,,.h1,page,2,2023-05-02 08:00:00+00:00,经部\r\n"
        + "Some web text,An Article,Jane Doe,,,,,order,3,2024-01-01T00:00:00Z,\r\n"
        + ",空行,,,,,,,,,\r\n"
        + "Kindle text,Kindle Book,Someone,B00ABC,,,,location,1234,\"March 3, 2022 10:15:00 AM\",\r\n"

    func testParsesReadwiseCSV() throws {
        let r = try ReadwiseCSVImporter.parse(sample)
        XCTAssertEqual(r.sources.map(\.title), ["论语译注", "An Article", "Kindle Book"])
        XCTAssertEqual(r.highlightCount, 4)
        XCTAssertEqual(r.skippedRows, 1)

        let lunyu = r.sources[0]
        XCTAssertEqual(lunyu.author, "杨伯峻")
        XCTAssertEqual(lunyu.kind, .book)
        let h1 = lunyu.highlights[0]
        XCTAssertEqual(h1.text, "学而时习之，不亦说乎？")
        XCTAssertEqual(h1.note, "开篇")
        XCTAssertEqual(h1.location, "第1页")
        XCTAssertEqual(h1.tags, ["论语", "经部"])
        XCTAssertTrue(h1.isFavorite)
        XCTAssertEqual(h1.highlightedAt, ISO8601DateFormatter().date(from: "2023-05-01T12:34:56Z"))

        let h2 = lunyu.highlights[1]
        XCTAssertEqual(h2.text, "多行\n摘录，含\"引号\"")
        XCTAssertEqual(h2.tags, ["经部"], "dot tags dropped")
        XCTAssertFalse(h2.isFavorite)
        XCTAssertFalse(h2.isDiscarded)

        XCTAssertNil(r.sources[1].highlights[0].location, "order is not a real location")
        XCTAssertNotNil(r.sources[1].highlights[0].highlightedAt)
        XCTAssertEqual(r.sources[2].highlights[0].location, "Kindle 位置 1234")
        XCTAssertNotNil(r.sources[2].highlights[0].highlightedAt)
    }

    func testDiscardTagAndDocumentFavorite() throws {
        let csv = "Highlight,Book Title,Book Author,Amazon Book ID,Note,Color,Tags,Location Type,Location,Highlighted at,Document tags\n"
            + "a,T,,,,,discard,offset,10,2023-01-18 15:43:26+00:00,\"林乐知, favorite\"\n"
        let h = try ReadwiseCSVImporter.parse(csv).sources[0].highlights[0]
        XCTAssertTrue(h.isDiscarded)
        XCTAssertFalse(h.isFavorite, "document-level favorite is not a highlight favorite")
        XCTAssertEqual(h.tags, ["林乐知", "favorite"])
        XCTAssertNil(h.location, "offset is not a real location")
    }

    func testFastDateParse() {
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(ReadwiseCSVImporter.fastParse("2023-01-18 15:43:26+00:00"), iso.date(from: "2023-01-18T15:43:26Z"))
        XCTAssertEqual(ReadwiseCSVImporter.fastParse("2023-01-18T23:43:26+08:00"), iso.date(from: "2023-01-18T15:43:26Z"))
        XCTAssertEqual(ReadwiseCSVImporter.fastParse("2024-02-29T00:00:00Z"), iso.date(from: "2024-02-29T00:00:00Z"))
        XCTAssertEqual(ReadwiseCSVImporter.fastParse("1999-12-31 23:59:59"), iso.date(from: "1999-12-31T23:59:59Z"))
        XCTAssertEqual(ReadwiseCSVImporter.fastParse("2023-01-18 15:43:26.500000+00:00")!.timeIntervalSince1970,
                       iso.date(from: "2023-01-18T15:43:26Z")!.timeIntervalSince1970 + 0.5, accuracy: 1e-6)
        XCTAssertNil(ReadwiseCSVImporter.fastParse("March 3, 2022"))
        XCTAssertNil(ReadwiseCSVImporter.fastParse("2023-13-01 00:00:00"))
    }

    func testRejectsNonReadwise() {
        XCTAssertThrowsError(try ReadwiseCSVImporter.parse("a,b\n1,2\n")) { e in
            XCTAssertEqual(e as? ReadwiseCSVImporter.ImportError, .missingHighlightColumn(found: ["a", "b"]))
        }
        XCTAssertThrowsError(try ReadwiseCSVImporter.parse(""))
    }

    func testCSVEdgeCases() {
        XCTAssertEqual(CSV.parse("a,\"b,c\",d\nx,,z"), [["a", "b,c", "d"], ["x", "", "z"]])
        XCTAssertEqual(CSV.parse("a\r\n\r\nb\r\n"), [["a"], ["b"]])
    }
}

final class ArticleTests: XCTestCase {
    func testTitleCleanup() {
        XCTAssertEqual(ArticleText.cleanTitle("明清之际的思想转向 - 某学术博客", h1: "明清之际的思想转向", siteName: "某学术博客"), "明清之际的思想转向")
        XCTAssertEqual(ArticleText.cleanTitle("明清之际的思想转向_某学术博客", h1: nil, siteName: "某学术博客"), "明清之际的思想转向")
        XCTAssertEqual(ArticleText.cleanTitle("论语札记｜澎湃新闻", h1: "论语札记", siteName: nil), "论语札记")
        XCTAssertEqual(ArticleText.cleanTitle("A - B - C", h1: nil, siteName: nil), "A - B - C")
        XCTAssertEqual(ArticleText.cleanTitle("  只有标题  ", h1: "完全不同的大标题", siteName: "X"), "只有标题")
    }

    func testBylineAndCounts() {
        XCTAssertEqual(ArticleText.cleanByline("作者：张三"), "张三")
        XCTAssertEqual(ArticleText.cleanByline("文/李四\n2025-01-01"), "李四")
        XCTAssertNil(ArticleText.cleanByline("   "))
        XCTAssertEqual(ArticleText.wordCount("学而 时习\n之 ab"), 7)
        XCTAssertEqual(ArticleText.normalize("  a \n\n\n  b \n\n"), "a\n\nb")
    }

    func testDecodeExtraction() throws {
        let body = String(repeating: "晚明思想界的变动。", count: 10)
        let json = #"{"title":"标题 - 站","byline":"作者：王五","siteName":"站","publishedTime":"2025-03-01T08:00:00+08:00","excerpt":"摘要","content":"<p>x</p>","textContent":"\#(body)","length":90,"h1":"标题","url":"https://a.cn/1"}"#
        let e = try ArticleExtraction.decode(json)
        let a = e.makeArticle(url: "https://fallback")
        XCTAssertEqual(a.title, "标题")
        XCTAssertEqual(a.author, "王五")
        XCTAssertEqual(a.url, "https://a.cn/1")
        XCTAssertEqual(a.publishedYear, "2025")
        XCTAssertEqual(a.wordCount, 90)
        XCTAssertThrowsError(try ArticleExtraction.decode("null")) { XCTAssertEqual($0 as? ArticleExtraction.ParseError, .noArticle) }
        XCTAssertThrowsError(try ArticleExtraction.decode(#"{"error":"boom"}"#)) { XCTAssertEqual($0 as? ArticleExtraction.ParseError, .script("boom")) }
        let short = #"{"title":"t","content":"<p>x</p>","textContent":"太短"}"#
        XCTAssertThrowsError(try ArticleExtraction.decode(short)) { XCTAssertEqual($0 as? ArticleExtraction.ParseError, .tooShort) }
    }

    func testSaveRouteAndURLNormalize() {
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongreview://save?url=https%3A%2F%2Fa.cn%2Fp%3Fid%3D1")!), .save(URL(string: "https://a.cn/p?id=1")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongreview://save?url=javascript%3Aalert(1)")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongreview://save")!))
        XCTAssertEqual(CaptureRequest.normalizeWebURL(" www.thepaper.cn/a "), URL(string: "https://www.thepaper.cn/a"))
        XCTAssertEqual(CaptureRequest.normalizeWebURL("http://x.org"), URL(string: "http://x.org"))
        XCTAssertNil(CaptureRequest.normalizeWebURL("not a url"))
        XCTAssertNil(CaptureRequest.normalizeWebURL("localhost"))
    }

    func testReaderPage() {
        let a = Article(url: "https://a.cn/?x=1&y=\"2\"", title: "<标题>", author: "张三", siteName: "站", publishedAt: "2025-03-01T08:00", contentHTML: "<p>正文</p>", contentText: "正文", wordCount: 2)
        let html = ReaderPage.html(for: a)
        XCTAssertTrue(html.contains("<h1>&lt;标题&gt;</h1>"))
        XCTAssertTrue(html.contains("张三 · 站 · 2025-03-01"))
        XCTAssertTrue(html.contains("href=\"https://a.cn/?x=1&amp;y=&quot;2&quot;\""))
        XCTAssertTrue(html.contains("<article id=\"kg-content\"><p>正文</p></article>"))
        XCTAssertTrue(html.contains("window.kgApply = function"))
        XCTAssertEqual(ReaderPage.applyScript([.init(id: 3, text: "a\"b")]), #"window.kgApply && window.kgApply([{"id":3,"text":"a\"b"}]);"#)
        XCTAssertTrue(WebScripts.readability.contains("function Readability("))
        XCTAssertTrue(WebScripts.extract.contains("new Readability("))
    }
}

final class V05CoreTests: XCTestCase {
    let accessed = ISO8601DateFormatter().date(from: "2026-10-06T04:00:00Z")!

    func testFootnoteStyles() {
        let book = Source(id: 1, title: "国史旧闻", author: "陈登原", publisher: "中华书局", year: "2000", place: "北京")
        let h = Highlight(id: 1, sourceId: 1, text: "x", location: "第29页")
        XCTAssertEqual(CitationFormatter.citation(for: h, source: book), "陈登原：《国史旧闻》，北京：中华书局，2000年，第29页。")
        let art = Source(id: 2, title: "蓝田生物群", author: "袁训来", kind: .article, year: "2012", container: "科学通报", issue: "第34期")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(text: "x", location: "第3219页"), source: art),
                       "袁训来：《蓝田生物群》，《科学通报》2012年第34期，第3219页。")
    }

    func testGBT7714() {
        // 标准 4.1 示例：陈登原.国史旧闻:第1卷[M].北京:中华书局,2000:29.
        let book = Source(id: 1, title: "国史旧闻:第1卷", author: "陈登原", publisher: "中华书局", year: "2000", place: "北京")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(text: "x", location: "第29页"), source: book, style: .gbt7714),
                       "陈登原.国史旧闻:第1卷[M].北京:中华书局,2000:29.")
        // 标准 4.4 示例：袁训来,陈哲,肖书海,等.蓝田生物群…[J].科学通报,2012,55(34):3219.
        let art = Source(id: 2, title: "蓝田生物群", author: "袁训来、陈哲、肖书海、张三", kind: .article, year: "2012", container: "科学通报", issue: "55(34)")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(text: "x", location: "3219"), source: art, style: .gbt7714),
                       "袁训来,陈哲,肖书海,等.蓝田生物群[J].科学通报,2012,55(34):3219.")
        let web = Source(id: 3, title: "某文", author: "", kind: .web, url: "https://a.cn/1", year: "2025")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(text: "x"), source: web, style: .gbt7714, accessed: accessed),
                       "某文[EB/OL].(2025)[2026-10-06].https://a.cn/1.")
        XCTAssertEqual(CitationFormatter.gbtAuthors("Smith, Jones, Lee, Kim"), "Smith,Jones,Lee, et al")
    }

    func testPages() {
        XCTAssertEqual(CitationFormatter.pages(from: "第12页"), "12")
        XCTAssertEqual(CitationFormatter.pages(from: "第12—15页"), "12-15")
        XCTAssertEqual(CitationFormatter.pages(from: "p. 7"), "7")
        XCTAssertEqual(CitationFormatter.pages(from: "33"), "33")
        XCTAssertNil(CitationFormatter.pages(from: "Kindle 位置 1234"))
        XCTAssertNil(CitationFormatter.pages(from: "学而第一"))
        XCTAssertNil(CitationFormatter.pages(from: nil))
    }

    func testCompilation() {
        let sources: [Int64: Source] = [
            1: Source(id: 1, title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980"),
            2: Source(id: 2, title: "孟子译注", author: "杨伯峻"),
        ]
        let t0 = Date(timeIntervalSince1970: 1_000)
        let hs = [
            Highlight(id: 1, sourceId: 1, text: "后一条", note: "按语", location: "第20页", createdAt: t0),
            Highlight(id: 2, sourceId: 1, text: "前一条", location: "第3页", createdAt: t0.addingTimeInterval(10)),
            Highlight(id: 3, sourceId: 2, text: "孟子一条", createdAt: t0.addingTimeInterval(5)),
            Highlight(id: 4, text: "无出处", createdAt: t0.addingTimeInterval(1)),
        ]
        let c = CompilationBuilder.build(highlights: hs, sources: sources, options: .init(title: "专题：仁", date: accessed))
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c.sections.map(\.heading), ["《论语译注》 杨伯峻", "《孟子译注》 杨伯峻", "未注明出处"])
        XCTAssertEqual(c.sections[0].items.map(\.text), ["前一条", "后一条"], "ordered by page")
        XCTAssertEqual(c.sections[0].items[1].note, "按语")
        let md = CompilationBuilder.markdown(c)
        XCTAssertTrue(md.hasPrefix("# 专题：仁\n\n*共 4 条摘录 · 2026-10-06 整理"))
        XCTAssertTrue(md.contains("## 《论语译注》 杨伯峻\n\n> 前一条\n\n—— 杨伯峻：《论语译注》，中华书局，1980年，第3页。"))

        var o = CompilationOptions(title: "t", grouping: .chronological, includeNotes: false, date: accessed)
        o.style = .gbt7714
        let c2 = CompilationBuilder.build(highlights: hs, sources: sources, options: o)
        XCTAssertEqual(c2.sections.count, 1)
        XCTAssertEqual(c2.sections[0].items.map(\.text), ["后一条", "无出处", "孟子一条", "前一条"])
        XCTAssertNil(c2.sections[0].items[0].note)
    }

    func testAnki() {
        let sources: [Int64: Source] = [1: Source(id: 1, title: "论语", author: "")]
        let hs = [Highlight(id: 1, sourceId: 1, text: "学而时习之\n不亦说乎<b>", translation: "学了\t按时温习", tags: ["论语 选读"])]
        let out = AnkiExporter.export(highlights: hs, sources: sources)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(lines.prefix(6)), ["#separator:tab", "#html:true", "#notetype:Basic", "#deck:KongReview", "#columns:Front;Back;Tags", "#tags column:3"])
        let cols = lines[6].split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(cols.count, 3)
        XCTAssertEqual(cols[0], "学而时习之<br>不亦说乎&lt;b&gt;")
        XCTAssertEqual(cols[1], "学了 按时温习<br><br><small>《论语》。</small>")
        XCTAssertEqual(cols[2], "论语_选读 KongReview")
    }

    func testDedup() {
        XCTAssertEqual(SourceDedup.key("论语译注（修订本）"), SourceDedup.key("《论语译注》"))
        XCTAssertEqual(SourceDedup.key("The  Analects"), SourceDedup.key("the analects:"))
        let ss = [Source(id: 1, title: "论语译注"), Source(id: 2, title: "论语 译注"), Source(id: 3, title: "孟子"), Source(id: 4, title: "论语译注 (第二版)")]
        XCTAssertEqual(SourceDedup.duplicateGroups(ss), [[1, 2, 4]])
        // 上下篇不是重复
        XCTAssertNotEqual(SourceDedup.key("鄭玄六天説析論（上）"), SourceDedup.key("鄭玄六天説析論（下）"))
        XCTAssertEqual(SourceDedup.key("邓小南：我的学术自述"), SourceDedup.key("邓小南 | 我的学术自述"))
    }
}

final class RenameTests: XCTestCase {
    func testLegacySchemeStillWorks() {
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongglean://add?text=x")!), .add(CaptureRequest(text: "x")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongreview://add?text=x")!), .add(CaptureRequest(text: "x")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongglean://save?url=https%3A%2F%2Fa.cn")!), .save(URL(string: "https://a.cn")!))
        XCTAssertNotNil(CaptureRequest(url: URL(string: "KONGGLEAN://add?text=y")!))
        XCTAssertTrue(CaptureRequest.bookmarklet.contains("kongreview://add"))
        XCTAssertTrue(CaptureRequest.saveBookmarklet.contains("kongreview://save"))
    }
}

final class V07CoreTests: XCTestCase {
    func testAIKindCitation() {
        let s = Source(id: 1, title: "关于“克己复礼”的解释", author: "Claude", kind: .ai, publisher: "Anthropic", year: "2026")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(text: "x"), source: s), "Claude：《关于“克己复礼”的解释》，Anthropic，人工智能生成内容，2026年。")
        XCTAssertTrue(CitationFormatter.citation(for: Highlight(text: "x"), source: s, style: .gbt7714).contains("[Z]"))
        XCTAssertEqual(SourceKind.ai.label, "人工智能")
    }

    func testMarkdown() {
        XCTAssertEqual(Markdown.html("# 标题\n正文**加粗**和*斜体*\n第二行"), "<h1>标题</h1>\n<p>正文<strong>加粗</strong>和<em>斜体</em><br>第二行</p>")
        XCTAssertEqual(Markdown.html("- 甲\n- 乙\n\n1. 一\n2. 二"), "<ul>\n<li>甲</li>\n<li>乙</li>\n</ul>\n<ol>\n<li>一</li>\n<li>二</li>\n</ol>")
        XCTAssertEqual(Markdown.html("> 引文\n\n`a<b`"), "<blockquote>引文</blockquote>\n<p><code>a&lt;b</code></p>")
        XCTAssertEqual(Markdown.html("[链接](https://a.cn)"), "<p><a href=\"https://a.cn\">链接</a></p>")
        XCTAssertEqual(Markdown.html("<div>已是 HTML</div>"), "<div>已是 HTML</div>")
        XCTAssertTrue(Markdown.looksLikeHTML("正面<br>第二行"))
        XCTAssertFalse(Markdown.looksLikeHTML("2 < 3 而 4 > 1"))
        XCTAssertEqual(Markdown.plainText(fromHTML: "<p>甲<br>乙</p><div>丙&amp;丁</div>"), "甲\n乙\n丙&丁")
    }

    func testImageRewrite() {
        let html = #"<p>x</p><img src="data:image/gif;base64,R0" data-src="/a/1.jpg" srcset="a 2x"><img src='http://b.cn/2.png' alt="图"><img src="https://mmbiz.qpic.cn/x?wx_fmt=png&amp;from=1">"#
        let r = ArticleImages.rewrite(html, base: "https://site.cn/post/9")
        XCTAssertEqual(r.urls, ["https://site.cn/a/1.jpg", "http://b.cn/2.png", "https://mmbiz.qpic.cn/x?wx_fmt=png&from=1"])
        XCTAssertFalse(r.html.contains("srcset"))
        XCTAssertTrue(r.html.contains(#"alt="图""#))
        XCTAssertEqual(r.html.components(separatedBy: "kr-img://img?").count, 4)
        // round-trip
        let m = try! NSRegularExpression(pattern: #"src="([^"]+)""#).firstMatch(in: r.html, range: NSRange(r.html.startIndex..., in: r.html))!
        let src = String(r.html[Range(m.range(at: 1), in: r.html)!]).replacingOccurrences(of: "&amp;", with: "&")
        let parsed = ArticleImages.parse(URL(string: src)!)!
        XCTAssertEqual(parsed.image.absoluteString, "https://site.cn/a/1.jpg")
        XCTAssertEqual(parsed.referer, "https://site.cn/post/9")
        XCTAssertFalse(ArticleImages.sendsReferer(for: URL(string: "https://mmbiz.qpic.cn/x")!))
        XCTAssertTrue(ArticleImages.sendsReferer(for: URL(string: "https://site.cn/a.jpg")!))
    }

    func testSchedulerLearningAndReview() {
        let s = CardScheduler()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var c = Card(front: "学而时习之", due: t0)
        let p = s.preview(c, now: t0)
        XCTAssertEqual(p[.again], "1分钟"); XCTAssertEqual(p[.hard], "6分钟"); XCTAssertEqual(p[.good], "10分钟"); XCTAssertEqual(p[.easy], "4天")
        c = s.answer(c, .good, now: t0)                       // 步骤 1 → 10 分钟
        XCTAssertEqual(c.state, .learning); XCTAssertEqual(c.step, 1)
        XCTAssertEqual(c.due.timeIntervalSince(t0), 600, accuracy: 0.1)
        c = s.answer(c, .good, now: t0 + 600)                 // 毕业 → 1 天
        XCTAssertEqual(c.state, .review); XCTAssertEqual(c.interval, 1)
        c = s.answer(c, .good, now: c.due)                    // 1 天 × 2.5 → 3 天（≥ 当前+1）
        XCTAssertEqual(c.interval, 3)
        c = s.answer(c, .easy, now: c.due)                    // 3 × 2.65 × 1.3 ≈ 10
        XCTAssertEqual(c.interval, 10); XCTAssertEqual(c.ease, 2.65, accuracy: 1e-9)
        c = s.answer(c, .again, now: c.due)                   // 遗忘：重学 10 分钟，难度 -0.2
        XCTAssertEqual(c.state, .relearning); XCTAssertEqual(c.lapses, 1); XCTAssertEqual(c.ease, 2.45, accuracy: 1e-9)
        let lapseAt = c.due
        c = s.answer(c, .good, now: lapseAt)                  // 重学完成 → 间隔 1 天
        XCTAssertEqual(c.state, .review); XCTAssertEqual(c.interval, 1)
        c = s.answer(c, .hard, now: c.due)
        XCTAssertEqual(c.interval, 2); XCTAssertEqual(c.ease, 2.30, accuracy: 1e-9)
        XCTAssertEqual(c.reps, 7)
    }

    func testStudyQueue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = [
            Card(id: 1, front: "新1", createdAt: now - 100),
            Card(id: 2, front: "新2", createdAt: now - 50),
            Card(id: 3, front: "复习", state: .review, interval: 3, due: now - 3600),
            Card(id: 4, front: "学习中", state: .learning, step: 1, due: now - 10),
            Card(id: 5, front: "未到期", state: .review, interval: 3, due: now + 3 * 86_400),
            Card(id: 6, front: "暂停", isSuspended: true),
        ]
        XCTAssertEqual(StudyQueue.next(from: cards, now: now, newLimitLeft: 20, reviewLimitLeft: 200)?.id, 4)
        XCTAssertEqual(StudyQueue.next(from: cards.filter { $0.id != 4 }, now: now, newLimitLeft: 20, reviewLimitLeft: 200)?.id, 3)
        XCTAssertEqual(StudyQueue.next(from: cards.filter { $0.id != 4 && $0.id != 3 }, now: now, newLimitLeft: 20, reviewLimitLeft: 200)?.id, 1)
        XCTAssertNil(StudyQueue.next(from: cards.filter { $0.id! >= 5 }, now: now, newLimitLeft: 20, reviewLimitLeft: 200))
        XCTAssertEqual(StudyQueue.counts(cards, now: now, newLimitLeft: 1, reviewLimitLeft: 200), StudyQueue.Counts(new: 1, learning: 1, review: 1))
    }

    func testClozeAndFaces() {
        let c = AnkiContent.cloze("{{c1::克己复礼::四字}}为仁。一日{{c2::克己复礼}}")
        XCTAssertEqual(c.front, #"<span class="cloze">[四字]</span>为仁。一日<span class="cloze">[…]</span>"#)
        XCTAssertEqual(c.back, #"<span class="cloze">克己复礼</span>为仁。一日<span class="cloze">克己复礼</span>"#)
        let f = AnkiContent.faces(fields: ["问[sound:a.mp3]", "答", "", "补充"], isClozeModel: false)
        XCTAssertEqual(f.front, "问"); XCTAssertEqual(f.back, "答<hr>补充")
    }

    func testAnkiTextImport() throws {
        let txt = "#separator:tab\n#html:true\n#guid column:1\n#notetype column:2\n#deck column:3\n#tags column:6\n"
            + "abc\tBasic\t论语\t学而时习之\t<b>学</b>了按时温习\t论语 经部\n"
            + "def\tCloze\t论语\t\"{{c1::仁}}者\t爱人\"\t\t\n"
        let r = try AnkiTextImporter.parse(txt)
        XCTAssertEqual(r.notes.count, 2)
        XCTAssertEqual(r.notes[0].fields, ["学而时习之", "<b>学</b>了按时温习"])
        XCTAssertEqual(r.notes[0].tags, ["论语", "经部"])
        XCTAssertEqual(r.notes[0].deck, "论语"); XCTAssertEqual(r.notes[0].guid, "abc"); XCTAssertEqual(r.notes[0].notetype, "Basic")
        XCTAssertEqual(r.notes[1].fields, ["{{c1::仁}}者\t爱人", ""])
        let plain = try AnkiTextImporter.parse("问题;答案\n")
        XCTAssertEqual(plain.notes.count, 1)  // 默认 tab：整行一个字段
        let semi = try AnkiTextImporter.parse("#separator:semicolon\n#html:false\n问题;a<b\n")
        XCTAssertEqual(semi.notes[0].fields, ["问题", "a&lt;b"])
        XCTAssertThrowsError(try AnkiTextImporter.parse("#separator:tab\n\n"))
    }

    func testReminderPlan() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 7))!
        let d1 = ReminderPlan.days(now: morning, hour: 8, minute: 30, reviewedToday: false, horizon: 3, calendar: cal)
        XCTAssertEqual(d1.map { ReminderPlan.dayKey($0, calendar: cal) }, ["2026-10-13", "2026-10-14", "2026-10-15"])
        let d2 = ReminderPlan.days(now: morning, hour: 8, minute: 30, reviewedToday: true, horizon: 3, calendar: cal)
        XCTAssertEqual(d2.map { ReminderPlan.dayKey($0, calendar: cal) }, ["2026-10-14", "2026-10-15"])
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 21))!
        XCTAssertEqual(ReminderPlan.days(now: evening, hour: 8, minute: 30, reviewedToday: false, horizon: 2, calendar: cal).count, 1)
        XCTAssertEqual(ReminderPlan.identifier(for: morning, calendar: cal), "kongreview.review.2026-10-13")
    }

    func testStats() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ d: Int, _ h: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
        let ev = [
            ReviewEvent(kind: .keep, at: at(13)), ReviewEvent(kind: .favorite, at: at(13)),
            ReviewEvent(kind: .card, answer: 1, at: at(13)), ReviewEvent(kind: .card, answer: 3, at: at(12)),
            ReviewEvent(kind: .keep, at: at(11)), ReviewEvent(kind: .note, at: at(10)),
            ReviewEvent(kind: .keep, at: at(5)), ReviewEvent(kind: .keep, at: at(6)), ReviewEvent(kind: .keep, at: at(7)), ReviewEvent(kind: .keep, at: at(8)),
        ]
        let s = ReviewStats.summarize(ev, now: at(13, 20), days: 7, calendar: cal)
        XCTAssertEqual(s.today.highlights, 2); XCTAssertEqual(s.today.cards, 1)
        XCTAssertEqual(s.currentStreak, 3)          // 11, 12, 13（10 日只写了按语，不算）
        XCTAssertEqual(s.longestStreak, 4)          // 5–8
        XCTAssertEqual(s.activeDays, 7)
        XCTAssertEqual(s.lastDays.count, 7); XCTAssertEqual(s.lastDays.last?.key, "2026-10-13")
        XCTAssertEqual(s.cardAccuracy!, 0.5, accuracy: 1e-9)
        let s2 = ReviewStats.summarize(ev, now: at(14, 8), days: 7, calendar: cal)
        XCTAssertEqual(s2.currentStreak, 3, "today not yet reviewed: count from yesterday")
    }
}

final class V07CardTests: XCTestCase {
    func testCardFromHighlightAndRender() {
        let s = Source(id: 1, title: "论语译注", author: "杨伯峻")
        let h = Highlight(id: 9, sourceId: 1, text: "**克己复礼**为仁", translation: "约束自己", note: "颜渊篇", tags: ["仁"])
        let c = Card.from(h, source: s)
        XCTAssertEqual(c.front, "**克己复礼**为仁")
        XCTAssertEqual(c.back, "约束自己\n\n按：颜渊篇\n\n—— 杨伯峻：《论语译注》。")
        XCTAssertEqual(c.highlightId, 9); XCTAssertEqual(c.deck, "摘录"); XCTAssertEqual(c.tags, ["仁"])
        XCTAssertEqual(Card.renderHTML(c.front), "<p><strong>克己复礼</strong>为仁</p>")
        XCTAssertEqual(Card.renderHTML(#"图<img src="paste-1.jpg">和<img src="https://a.cn/x.png">"#),
                       #"图<img src="kr-media://media/paste-1.jpg">和<img src="https://a.cn/x.png">"#)
    }

    func testAnkiScheduleConversion() {
        let crt = Date(timeIntervalSince1970: 1_600_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AnkiNote.schedule(type: 0, queue: 0, due: 5, ivl: 0, factor: 0, reps: 0, lapses: 0, collectionCreated: crt, now: now))
        let r = AnkiNote.schedule(type: 2, queue: 2, due: 100, ivl: 15, factor: 2300, reps: 6, lapses: 1, collectionCreated: crt, now: now)!
        XCTAssertEqual(r.state, .review); XCTAssertEqual(r.interval, 15); XCTAssertEqual(r.ease, 2.3)
        XCTAssertEqual(r.due, crt.addingTimeInterval(100 * 86_400))
        let l = AnkiNote.schedule(type: 1, queue: 1, due: 1_799_999_000, ivl: 0, factor: 2500, reps: 1, lapses: 0, collectionCreated: crt, now: now)!
        XCTAssertEqual(l.state, .learning); XCTAssertEqual(l.due, Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertTrue(AnkiNote.schedule(type: 2, queue: -1, due: 1, ivl: 3, factor: 2500, reps: 2, lapses: 0, collectionCreated: crt, now: now)!.suspended)
        let notes = AnkiNote.from(try! AnkiTextImporter.parse("#notetype column:1\nCloze\t{{c1::仁}}\n"), defaultDeck: "默认")
        XCTAssertEqual(notes[0].front, #"<span class="cloze">[…]</span>"#)
        XCTAssertEqual(notes[0].deck, "默认")
    }
}

final class ZstdTests: XCTestCase {
    func testDecompressText() throws {
        let z = Data(base64Encoded: "KLUv/WQOD6UDAAQG5a2m6ICM5pe25Lmg5LmL77yM5LiN5Lqm6K+05LmO77yB5pyJ5pyL6Ieq6L+c5pa55p2l5LmQVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRsYXp5IGRvZy4gBQAWQfUjCAUeUEjwAOAxp1BQjeeswA==")!
        XCTAssertTrue(Zstd.isZstd(z))
        let d = try Zstd.decompress(z)
        let expected = String(repeating: "学而时习之，不亦说乎！有朋自远方来，不亦乐乎！", count: 40)
            + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        XCTAssertEqual(String(decoding: d, as: UTF8.self), expected)
    }

    func testNotZstd() {
        XCTAssertThrowsError(try Zstd.decompress(Data("hello".utf8)))
    }

    func testAnkiMediaMap() {
        let pb = Data(base64Encoded: "KLUv/SAYwQAACgkKBWEuanBnEAUKCwoHYiBjLnBuZxAF")!
        XCTAssertEqual(AnkiPackage.mediaMap(pb), ["0": "a.jpg", "1": "b c.png"])
        XCTAssertEqual(AnkiPackage.mediaMap(Data(#"{"0":"x.png"}"#.utf8)), ["0": "x.png"])
        let refs = AnkiPackage.mediaReferences(in: #"<img src="a.jpg"> <img src='b%20c.png'> [sound:s.mp3]"#)
        XCTAssertTrue(refs.isSuperset(of: ["a.jpg", "b c.png", "s.mp3"]))
    }
}

#if canImport(Darwin)
final class MarkdownTextTests: XCTestCase {
    func testPlainTextUnchanged() {
        let s = "第一行\n\n第三行  有空格"
        XCTAssertEqual(String(MarkdownText.attributed(s).characters), s)
    }

    func testBlocksAndInline() {
        let a = MarkdownText.attributed("# 标题\n- 一\n- **二**\n> 引文\n```\nlet x = 1\n```\n末行 *斜*")
        XCTAssertEqual(String(a.characters), "标题\n• 一\n• 二\n┃ 引文\nlet x = 1\n末行 斜")
        let bold = a.runs.contains { run in
            String(a[run.range].characters) == "二" && run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(bold)
    }
}
#endif

final class HTMLFragmentTests: XCTestCase {
    func testScreenshotCase() {
        let src = "<h1>似乎没人介意</h1>。 <h1>我的朋友告诉我</h1>， 年长的使用者不会批评"
        XCTAssertEqual(Markdown.markdown(fromHTMLFragments: src), "**似乎没人介意**。 **我的朋友告诉我**， 年长的使用者不会批评")
    }

    func testCommonTags() {
        let src = #"<p>甲<b>乙</b><br>丙 <a href="https://x.org/a">链</a> &amp; &lt;t&gt; &#20013;</p><ul><li>一</li><li>二</li></ul>"#
        XCTAssertEqual(Markdown.markdown(fromHTMLFragments: src), "甲**乙**\n丙 [链](https://x.org/a) & <t> 中\n\n- 一\n- 二")
    }

    func testPlainUntouched() {
        let s = "a < b 且 c > d，**已是 Markdown**"
        XCTAssertFalse(Markdown.containsHTMLTag(s))
        XCTAssertEqual(Markdown.markdown(fromHTMLFragments: s), s)
    }
}

final class FSRSTests: XCTestCase {
    /// 与 py-fsrs 6.3.2（同样的默认参数、无学习步、无随机扰动）逐步对照
    func testMatchesReferenceImplementation() {
        let f = FSRS()
        let seq: [(Int, Int, Double, Double, Double)] = [
            (0, 3, 2.3065, 2.1181, 2), (0, 3, 2.3065, 2.1112, 2), (3, 3, 13.8358, 2.1043, 14),
            (10, 2, 34.0745, 4.7437, 34), (30, 1, 2.4266, 8.2575, 2), (1, 3, 3.9727, 8.2445, 4),
            (5, 4, 14.2732, 7.6431, 14), (60, 3, 53.0693, 7.6307, 53),
        ]
        var m: (s: Double, d: Double)?
        for (i, (dd, r, s, d, ivl)) in seq.enumerated() {
            m = f.nextMemory(m, elapsedDays: i == 0 ? 0 : dd, rating: r)
            XCTAssertEqual(m!.s, s, accuracy: 0.002, "step \(i) S")
            XCTAssertEqual(m!.d, d, accuracy: 0.002, "step \(i) D")
            XCTAssertEqual(f.interval(stability: m!.s), ivl, "step \(i) interval")
        }
    }

    func testAnswerFlowAndOrdering() {
        let f = FSRS()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var c = Card(front: "q")
        c = f.answer(c, .good, now: now)          // 学习第 1 步 → 10 分钟
        XCTAssertEqual(c.state, .learning)
        c = f.answer(c, .good, now: now.addingTimeInterval(600))
        XCTAssertEqual(c.state, .review)
        XCTAssertNotNil(c.stability)
        let later = now.addingTimeInterval(86_400 * Double(c.interval))
        let p = [CardAnswer.hard, .good, .easy].map { f.answer(c, $0, now: later).interval }
        XCTAssertTrue(p[0] <= p[1] && p[1] < p[2], "\(p)")
        let lapsed = f.answer(c, .again, now: later)
        XCTAssertEqual(lapsed.state, .relearning)
        XCTAssertEqual(lapsed.lapses, 1)
    }

    func testOptimizerDoesNotWorsen() {
        // 用“真实参数”略有不同的模型生成模拟记录，看优化后损失下降
        var truth = FSRS.defaultParameters
        truth[8] = 2.3; truth[10] = 1.1; truth[20] = 0.3
        let gen = FSRS(parameters: truth)
        var rng = SeededGenerator(seed: 7)
        var histories: [[FSRSReview]] = []
        for _ in 0..<300 {
            var h: [FSRSReview] = []
            var day = 0
            var m: (s: Double, d: Double)?
            for k in 0..<6 {
                var rating = 3
                if let cur = m {
                    let gap = Int(max(1, gen.interval(stability: cur.s) * Double.random(in: 0.5...1.6, using: &rng)))
                    day += gap
                    let r = gen.retrievability(elapsedDays: Double(gap), stability: cur.s)
                    rating = Double.random(in: 0...1, using: &rng) < r ? (Double.random(in: 0...1, using: &rng) < 0.15 ? 4 : 3) : 1
                } else {
                    rating = [1, 3, 3, 4][k % 4]
                }
                h.append(FSRSReview(day: day, rating: rating))
                m = gen.nextMemory(m, elapsedDays: h.count == 1 ? 0 : h[h.count - 1].day - h[h.count - 2].day, rating: rating)
            }
            histories.append(h)
        }
        let r = FSRSOptimizer.optimize(histories, maxEvaluations: 1500)
        XCTAssertGreaterThanOrEqual(r.reviewCount, FSRSOptimizer.minimumReviews)
        XCTAssertLessThanOrEqual(r.lossAfter, r.lossBefore)
        XCTAssertEqual(r.parameters.count, 21)
    }
}

final class NoteTemplateTests: XCTestCase {
    func testDefaultTemplateAndRender() {
        let t = NoteTemplate.defaultTemplate(name: "论语", fieldNames: ["正文", "注释", "译文", "解题", "备注"])
        XCTAssertEqual(t.front, [0])
        XCTAssertEqual(t.back, [1, 2, 3, 4])
        XCTAssertEqual(t.collapsed, [1, 4])
        var c = Card(front: "x")
        c.fields = ["子曰", "①子：孔子", "孔子说", "", ""]
        let f = c.faces(using: t)
        XCTAssertTrue(f.front.contains("子曰"))
        XCTAssertTrue(f.back.contains("<details class=\"kr-field\"><summary>注释</summary>①子：孔子</details>"))
        XCTAssertTrue(f.back.contains("<div class=\"kr-label\">译文</div>孔子说"))
        XCTAssertFalse(f.back.contains("解题"))   // 空字段不显示
    }

    func testSHA1() {
        XCTAssertEqual(SHA1.hex(Data("abc".utf8)), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(Data()), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testCardDataMemory() {
        let m = AnkiNote.memory(fromCardData: #"{"s":362.2,"d":8.406,"dr":0.9}"#)
        XCTAssertEqual(m?.stability ?? 0, 362.2, accuracy: 1e-9)
        XCTAssertNil(AnkiNote.memory(fromCardData: ""))
    }
}

final class RichHTMLTests: XCTestCase {
    func testRichHTML() {
        let h = Markdown.richHTML("# 标题\n正文 **粗** <img src=\"https://x.org/a.png\"> [链](https://x.org)")
        XCTAssertTrue(h.contains("<h1>标题</h1>"), h)
        XCTAssertTrue(h.contains(#"<img alt="" src="https://x.org/a.png">"#), h)
        XCTAssertTrue(h.contains(#"<a href="https://x.org">链</a>"#), h)
        XCTAssertTrue(h.contains("<strong>粗</strong>"), h)
    }
}

final class V09CoreTests: XCTestCase {
    func testClozeMaking() {
        var t = "学而时习之，不亦说乎"
        t = AnkiContent.wrapCloze(t, range: NSRange(location: 3, length: 2))
        XCTAssertEqual(t, "学而时{{c1::习之}}，不亦说乎")
        t = AnkiContent.wrapCloze(t, range: (t as NSString).range(of: "说"))
        XCTAssertEqual(AnkiContent.clozeNumbers(t), [1, 2])
        let c2 = AnkiContent.cloze(t, number: 2)
        XCTAssertTrue(c2.front.contains("习之") && c2.front.contains("[…]"))
        XCTAssertTrue(c2.back.contains(#"<span class="cloze">说</span>"#))
        XCTAssertEqual(AnkiContent.unwrapCloze(t), "学而时习之，不亦说乎")
        let same = AnkiContent.wrapCloze(t, range: (t as NSString).range(of: "乎"), sameNumber: true)
        XCTAssertEqual(AnkiContent.clozeNumbers(same), [1, 2])
    }

    func testFrequencyWeight() {
        let s = ReviewScheduler()
        var h = Highlight(id: 1, text: "x")
        let base = s.weight(of: h, sourceWeight: 1, now: Date())
        h.frequency = 1
        XCTAssertEqual(s.weight(of: h, sourceWeight: 1, now: Date()), base * 2.5, accuracy: 1e-9)
        h.frequency = -1
        XCTAssertEqual(s.weight(of: h, sourceWeight: 1, now: Date()), base * 0.35, accuracy: 1e-9)
    }

    func testInboxParse() throws {
        let json = #"{"version":1,"app":"KongPDF","source":{"title":"严复集","author":"严复","url":"file:///a.pdf"},"highlights":[{"id":"h1","text":"物竞天择","page":12,"tags":["严复"],"createdAt":"2026-10-13T08:00:00Z"},{"text":"适者生存","location":"卷一"}]}"#
        let f = try InboxPayload.parse(Data(json.utf8))
        XCTAssertEqual(f.source.sourceKind, .pdf)
        XCTAssertEqual(f.highlights[0].resolvedLocation, "第 12 页")
        XCTAssertEqual(f.highlights[1].resolvedLocation, "卷一")
        XCTAssertNotNil(f.highlights[0].createdAt)
        XCTAssertEqual(InboxPayload.key(app: f.app, item: f.highlights[0]), "KongPDF|h1")
        XCTAssertThrowsError(try InboxPayload.parse(Data(#"{"version":2,"source":{"title":"x"},"highlights":[{"text":"a"}]}"#.utf8)))
    }

    func testSearchTerms() {
        XCTAssertEqual(SearchTerms.terms("仁 “君子” #论语"), ["仁", "君子"])
        let r = SearchTerms.ranges(of: ["仁", "Ren"], in: "仁者爱人，ren 也；仁")
        XCTAssertEqual(r.count, 3)
    }
}
