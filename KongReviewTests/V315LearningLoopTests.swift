import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 3.15：本期焦点、回顾与记忆卡互补、按语计入成果、学习质量、今日功课与札记
final class V315LearningLoopTests: XCTestCase {
    // 6.0.1：这里测的是已舍弃、代码暂留到 6.0.3 的旧功能——测试时临时打开
    override func setUp() { super.setUp(); SlimSwitch.featuresOff = false }
    override func tearDown() { SlimSwitch.featuresOff = true; super.tearDown() }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 20, hour: 12))! }
    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    // MARK: 焦点

    func testFocusBoostsNotebookHighlightsAndIsClearedWhenNotebookIsDeleted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Highlight(text: "焦点摘录"))
        let b = try db.save(Highlight(text: "其他摘录"))
        let notebook = try db.createNotebook(title: "何以为士")
        _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 1, kind: .highlight, highlightId: a.id)], into: notebook.id!, after: nil)
        let focus = LearningFocus(kind: .notebook, id: notebook.id!, title: "何以为士")
        try db.setLearningFocus(focus)
        XCTAssertEqual(try db.validatedLearningFocus()?.title, "何以为士")
        let bias = try db.reviewBias(now: now, focus: try db.validatedLearningFocus())
        XCTAssertEqual(bias.multipliers[a.id!], ReviewBias.focusBoost)
        XCTAssertNil(bias.multipliers[b.id!])
        try db.deleteNotebook(notebook.id!)
        XCTAssertNil(try db.validatedLearningFocus(), "专题删除后焦点失效")
    }

    func testSourceFocusAndDeckCounts() throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "论语译注"))
        let h = try db.save(Highlight(sourceId: source.id, text: "学而时习之"))
        _ = try db.save(Card(deck: "论语", front: "学而", highlightId: h.id))
        _ = try db.save(Card(deck: "其他", front: "无关"))
        let focus = LearningFocus(kind: .source, id: source.id!, title: "论语译注")
        XCTAssertEqual(try db.focusHighlightIDs(focus), [h.id!])
        XCTAssertEqual(try db.focusDeckCounts(focus), ["论语": 1])
    }

    // MARK: 回顾与记忆卡互补

    func testMatureCardsDampReviewAndLapsesBringOriginalBack() throws {
        let db = try AppDatabase(DatabaseQueue())
        let mature = try db.save(Highlight(text: "已熟记"))
        _ = try db.save(Card(front: "熟记卡", highlightId: mature.id, state: .review, interval: 30, due: day(10)))
        let hard = try db.save(Highlight(text: "总记不住"))
        let card = try db.save(Card(front: "难卡", highlightId: hard.id, state: .review, interval: 2, due: day(-1)))
        for d in [-3, -2, -1] { db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 1, at: day(d))) }
        let recent = try db.save(Highlight(text: "刚出现过", lastSurfacedAt: day(-1)))
        let recentCard = try db.save(Card(front: "近期难卡", highlightId: recent.id, state: .review, interval: 1, due: day(-1)))
        for d in [-3, -2, -1] { db.log(ReviewEvent(kind: .card, cardId: recentCard.id, answer: 1, at: day(d))) }
        let bias = try db.reviewBias(now: now)
        XCTAssertEqual(bias.multipliers[mature.id!], ReviewBias.matureDamping)
        XCTAssertEqual(bias.refresh.map(\.id), [hard.id!], "最近 3 天出现过的不再安排")
        XCTAssertEqual(bias.refresh.first?.lapses, 3)
        XCTAssertEqual(try db.recentLapses(highlightIDs: [hard.id!, mature.id!], now: now), [hard.id!: 3])
        // 一周以前的重来不计
        let old = try db.save(Highlight(text: "很久以前"))
        let oldCard = try db.save(Card(front: "旧难卡", highlightId: old.id))
        for d in [-12, -11, -10] { db.log(ReviewEvent(kind: .card, cardId: oldCard.id, answer: 1, at: day(d))) }
        XCTAssertFalse(try db.reviewBias(now: now).refresh.contains { $0.id == old.id })
    }

    // MARK: 按语与质量

    func testNotesAreAGrowthMetricAndEditorSavesLogThem() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "君子不器", createdAt: day(-1)))
        db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: day(0)))
        db.log(ReviewEvent(kind: .note, highlightId: h.id, at: day(0)))
        let start = day(-2), end = day(1)
        let summary = try await db.growthSummary(start: start, end: end)
        XCTAssertEqual(summary[.notes], 1)
        XCTAssertEqual(summary[.highlights], 1, "写按语不重复计入回顾")
        let details = try await db.growthDetails(metric: .notes, start: start, end: end, offset: 0)
        XCTAssertEqual(details.total, 1)
        let groups = try await db.growthBreakdown(metric: .notes, grouping: .source, start: start, end: end)
        XCTAssertEqual(groups.items.map(\.count), [1])

        try await MainActor.run {
            let store = LibraryStore(db: db)
            var draft = HighlightDraft(highlight: h)
            draft.highlight.note = "器者，各适其用而不能相通。"
            XCTAssertTrue(store.save(draft: draft))
            draft.highlight = try XCTUnwrap(try db.highlights(ids: [h.id!]).first)
            XCTAssertTrue(store.save(draft: draft), "按语未改动时不再记录")
        }
        let notes = try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_event WHERE kind = 'note'") }
        XCTAssertEqual(notes, 2)
    }

    func testQualityMetrics() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let start = day(-2), end = day(1)
        let reviewCard = try db.save(Card(front: "复习卡", state: .review, interval: 5, due: day(-1)))
        _ = try db.answer(reviewCard, .good, now: day(0))
        let refreshed = try XCTUnwrap(try db.card(id: reviewCard.id!))
        _ = try db.answer(refreshed, .again, now: day(0).addingTimeInterval(60))
        let newCard = try db.save(Card(front: "新卡"))
        _ = try db.answer(newCard, .good, now: day(0))
        let a = try db.save(Highlight(text: "甲", createdAt: day(-1)))
        let b = try db.save(Highlight(text: "乙", createdAt: day(-1)))
        _ = try db.save(Card(front: "甲卡", highlightId: a.id))
        for (kind, h) in [(ReviewEvent.Kind.keep, a), (.favorite, a), (.note, a), (.keep, b), (.discard, b)] { db.log(ReviewEvent(kind: kind, highlightId: h.id, at: day(0))) }
        // 只写了按语、本期没回顾过的摘录不进入分母，也不进入分子
        let c = try db.save(Highlight(text: "丙", createdAt: day(-10)))
        db.log(ReviewEvent(kind: .note, highlightId: c.id, at: day(0)))
        let q = try await db.growthQuality(start: start, end: end)
        XCTAssertEqual(q.reviewRatings, 2, "只算评分前已是复习状态的卡")
        XCTAssertEqual(q.retention, 0.5)
        XCTAssertEqual(q.reviewed, 2)
        XCTAssertEqual(q.curated, 2, "同一条既收藏又写按语只计一次")
        XCTAssertEqual(q.noted, 2)
        XCTAssertEqual(q.curationRate, 1, "筛选率不会超过 100%")
        XCTAssertEqual(q.newHighlights, 2)
        XCTAssertEqual(q.cardingRate, 0.5)
    }

    func testFocusProgress() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "国史大纲"))
        let a = try db.save(Highlight(sourceId: source.id, text: "温情与敬意", createdAt: day(0)))
        _ = try db.save(Highlight(sourceId: source.id, text: "未回顾", createdAt: day(-5)))
        let card = try db.save(Card(front: "卡", highlightId: a.id))
        _ = try db.answer(card, .good, now: day(0))
        db.log(ReviewEvent(kind: .keep, highlightId: a.id, at: day(0)))
        db.log(ReviewEvent(kind: .note, highlightId: a.id, at: day(0)))
        let p = try await db.focusProgress(LearningFocus(kind: .source, id: source.id!, title: "国史大纲"), start: day(-1), end: day(1))
        XCTAssertEqual(p, FocusProgress(totalHighlights: 2, reviewedHighlights: 1, newHighlights: 1, notes: 1, totalCards: 1, studiedCards: 1))
    }

    // MARK: 札记

    func testNotebookEntriesAndMarkdown() throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "论语译注", author: "杨伯峻"))
        let a = try db.save(Highlight(sourceId: source.id, text: "学而时习之", note: "习，温习也。", location: "第1页"))
        let b = try db.save(Highlight(text: "未归类收藏"))
        let c = try db.save(Highlight(sourceId: source.id, text: "只是看过"))
        db.log(ReviewEvent(kind: .note, highlightId: a.id, at: day(0)))
        db.log(ReviewEvent(kind: .favorite, highlightId: b.id, at: day(0)))
        db.log(ReviewEvent(kind: .keep, highlightId: c.id, at: day(0)))
        db.log(ReviewEvent(kind: .favorite, highlightId: a.id, at: day(-20)))
        let entries = try db.notebookEntries(start: day(-1), end: day(1))
        XCTAssertEqual(entries.map(\.highlight.id), [a.id, b.id], "出处在前，未归类在后；只看过的不收")
        XCTAssertEqual(entries.first?.favorited, false, "本期以外的收藏不计")
        let md = LearningMaterialExport.notebookMarkdown(entries: entries, window: GrowthPeriod.week.window(containing: now, now: now))
        XCTAssertTrue(md.contains("## 《论语译注》　杨伯峻"))
        XCTAssertTrue(md.contains("1. 学而时习之（第1页）〔按语〕"))
        XCTAssertTrue(md.contains("> 按：习，温习也。"))
        XCTAssertTrue(md.contains("## 未归类"))
    }

    // MARK: 学习会话

    func testFocusCardsComeFirstAndTodayWorkStartsWithReview() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let source = try db.save(Source(title: "焦点书"))
            let h = try db.save(Highlight(sourceId: source.id, text: "焦点"))
            _ = try db.save(Card(deck: "甲", front: "普通新卡", createdAt: Date().addingTimeInterval(-500)))
            let focusCard = try db.save(Card(deck: "甲", front: "焦点新卡", highlightId: h.id, createdAt: Date().addingTimeInterval(-100)))
            try db.setLearningFocus(LearningFocus(kind: .source, id: source.id!, title: "焦点书"))
            let store = LibraryStore(db: db)
            XCTAssertEqual(store.learningFocus?.title, "焦点书")
            XCTAssertEqual(store.focusDeckCounts, ["甲": 1])
            store.startStudy(deck: "甲")
            XCTAssertEqual(store.study.current?.id, focusCard.id)
            store.openCardsHome()
            store.startTodayWork()
            XCTAssertEqual(store.selection, .review, "今天的回顾还没完成时先进入回顾")
            store.setLearningFocus(nil)
            XCTAssertNil(store.learningFocus)
            XCTAssertTrue(store.focusHighlightIDs.isEmpty)
        }
    }

    func testTodayWorkMinutes() {
        XCTAssertEqual(LibraryStore.todayWorkMinutes(reviewPending: 0, cards: .init()), 0)
        XCTAssertEqual(LibraryStore.todayWorkMinutes(reviewPending: 6, cards: .init()), 3)
        XCTAssertEqual(LibraryStore.todayWorkMinutes(reviewPending: 2, cards: .init(new: 3)), 2)
    }
}
