import XCTest
@testable import KongGleanCore

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
        let url = URL(string: "kongglean://add?text=%E5%AD%A6%E8%80%8C%E6%97%B6%E4%B9%A0%E4%B9%8B&title=%E8%AE%BA%E8%AF%AD&location=%E5%AD%A6%E8%80%8C%E7%AC%AC%E4%B8%80&tags=%E8%AE%BA%E8%AF%AD,%E5%AD%A6")!
        let r = CaptureRequest(url: url)
        XCTAssertEqual(r?.text, "学而时习之")
        XCTAssertEqual(r?.title, "论语")
        XCTAssertEqual(r?.location, "学而第一")
        XCTAssertEqual(r?.tags, ["论语", "学"])
    }

    func testRejectsMissingTextOrWrongScheme() {
        XCTAssertNil(CaptureRequest(url: URL(string: "kongglean://add?title=x")!))
        XCTAssertNil(CaptureRequest(url: URL(string: "https://add?text=x")!))
        XCTAssertNil(CaptureRequest(url: URL(string: "kongglean://open?text=x")!))
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
        let add = CaptureRequest.route(for: URL(string: "kongglean://add?text=abc&title=T")!)
        XCTAssertEqual(add, .add(CaptureRequest(text: "abc", title: "T")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongglean://quick")!), .quick(nil))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongglean://quick?text=x")!), .quick(CaptureRequest(text: "x")))
        XCTAssertEqual(CaptureRequest.route(for: URL(string: "kongglean://review")!), .review)
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongglean://add")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "kongglean://unknown")!))
        XCTAssertNil(CaptureRequest.route(for: URL(string: "https://x.com")!))
    }

    func testBackupPolicy() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9))!
        XCTAssertEqual(BackupPolicy.fileName(for: d, calendar: cal), "glean-2026-10-06.sqlite")
        XCTAssertTrue(BackupPolicy.needsBackup(existing: ["glean-2026-10-05.sqlite"], now: d, calendar: cal))
        XCTAssertFalse(BackupPolicy.needsBackup(existing: ["glean-2026-10-06.sqlite"], now: d, calendar: cal))
        let files = (1...35).map { String(format: "glean-2026-09-%02d.sqlite", min($0, 30)) } .uniqued() + ["other.txt", "glean-bad.sqlite"]
        let prune = BackupPolicy.filesToPrune(existing: files, keep: 28)
        XCTAssertEqual(prune, ["glean-2026-09-01.sqlite", "glean-2026-09-02.sqlite"])
        XCTAssertEqual(BackupPolicy.filesToPrune(existing: ["glean-2026-09-01.sqlite"], keep: 30), [])
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
