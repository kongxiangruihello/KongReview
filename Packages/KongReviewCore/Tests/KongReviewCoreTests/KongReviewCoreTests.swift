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
