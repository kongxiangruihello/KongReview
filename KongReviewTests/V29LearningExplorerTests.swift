import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V29LearningExplorerTests: XCTestCase {
    func testKeywordMappingHandlesTraditionalEmojiAndLiteralSymbols() {
        let text = "😀統一關鍵字 50%_ 統一關鍵字"
        let ranges = KeywordHighlight.ranges(in: text, query: "统一关键字")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["統一關鍵字", "統一關鍵字"])
        XCTAssertEqual(KeywordHighlight.ranges(in: text, query: "50%_").map { String(text[$0]) }, ["50%_"])
        XCTAssertTrue(KeywordHighlight.ranges(in: text, query: " ").isEmpty)
    }
    func testLongPassagePreservesTextAndDoesNotSplitKeyword() {
        let text = String(repeating: "甲", count: 797) + "統一關鍵字" + String(repeating: "乙", count: 2000)
        let pieces = KeywordHighlight.passages(text, query: "统一关键字")
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertEqual(pieces.filter { !KeywordHighlight.ranges(in: $0, query: "统一关键字").isEmpty }.count, 1)
        XCTAssertGreaterThan(pieces.count, 2)
    }
    func testCalendarDayBoundsDeletedTargetsAndPagination() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let start = calendar.startOfDay(for: date), end = calendar.date(byAdding: .day, value: 1, to: start)!
        let highlight = try db.save(Highlight(text: "原文"))
        let card = try db.save(Card(front: "问题", deletedAt: date))
        for i in 0..<51 { db.log(ReviewEvent(kind: .keep, highlightId: highlight.id, at: start.addingTimeInterval(Double(i)))) }
        db.log(ReviewEvent(kind: .card, cardId: card.id, answer: 1, at: end.addingTimeInterval(-1)))
        db.log(ReviewEvent(kind: .keep, highlightId: highlight.id, at: start.addingTimeInterval(-1)))
        db.log(ReviewEvent(kind: .keep, highlightId: highlight.id, at: end))
        let first = try await db.learningExplorerPage(.day(date), calendar: calendar)
        let second = try await db.learningExplorerPage(.day(date), offset: 50, calendar: calendar)
        XCTAssertEqual(first.total, 52); XCTAssertEqual(first.rows.count, 50); XCTAssertEqual(second.rows.count, 2)
        XCTAssertNil(first.rows.first?.target)
        XCTAssertTrue(first.rows.first?.detail.contains("已删除") == true)
        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
    }
    func testDifficultCardsWindowDeckAndReadOnly() async throws {
        let db = try AppDatabase(DatabaseQueue()), now = Date()
        let card = try db.save(Card(deck: "甲", front: "难卡", back: "答案", isSuspended: true))
        let other = try db.save(Card(deck: "乙", front: "另一张"))
        let deleted = try db.save(Card(front: "已删除", deletedAt: now))
        for id in [card.id!,other.id!,deleted.id!] {
            for _ in 0..<3 { db.log(ReviewEvent(kind: .card, cardId: id, answer: 1, at: now)) }
        }
        let old = try db.save(Card(front: "很久以前"))
        for _ in 0..<4 { db.log(ReviewEvent(kind: .card, cardId: old.id, answer: 1, at: now.addingTimeInterval(-40*86400))) }
        let before = try db.card(id: card.id!)
        let page = try await db.learningExplorerPage(.difficult, deck: "甲", now: now)
        XCTAssertEqual(page.total, 1)
        XCTAssertTrue(page.rows[0].detail.contains("已暂停"))
        _ = try await db.resolveGlobalSearchTarget(page.rows[0].target!)
        XCTAssertEqual(try db.card(id: card.id!), before)
    }
    func testRelatedCardsExcludeDeletedAndPage() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "原文"))
        for i in 0..<53 { _ = try db.save(Card(front: "卡片\(i)", highlightId: h.id)) }
        _ = try db.save(Card(front: "删卡", highlightId: h.id, deletedAt: Date()))
        _ = try db.save(Card(front: "其他卡"))
        let first = try await db.learningExplorerPage(.related(h.id!))
        let second = try await db.learningExplorerPage(.related(h.id!), offset: 50)
        XCTAssertEqual(first.total, 53); XCTAssertEqual(second.rows.count, 3)
        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
    }
    @MainActor
    func testExistingLinkedCardOpensRelationsWithoutCreatingAnother() throws {
        let db = try AppDatabase(DatabaseQueue())
        let h = try db.save(Highlight(text: "原文"))
        _ = try db.makeCards(fromHighlights: [h.id!])
        let store = LibraryStore(db: db, positionDefaults: nil)
        store.makeCard(from: h)
        XCTAssertEqual(store.learningExplorer?.route, .related(h.id!))
        XCTAssertEqual(try db.cards(highlightIds: [h.id!]).count, 1)
        XCTAssertFalse(store.canShowGlobalSearch)
        XCTAssertFalse(store.cardRatingShortcutIsAvailable)
    }
    func testFullSimilarityFindsLongCardsAndResumeDoesNotRepeatPairs() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let front = String(repeating: "这是很长的古籍原文需要逐段核对内容。", count: 400)
        let back = String(repeating: "这是完整释义及出处说明。", count: 400)
        let a = try db.save(Card(front: front, back: back))
        let b = try db.save(Card(front: front + "补", back: back + "充"))
        for i in 0..<35 { _ = try db.save(Card(front: "无关题目\(i)", back: "答\(i)")) }
        let session = try await FullSimilaritySession.create(db: db, deck: nil)
        var batch = try await session.nextBatch()
        XCTAssertFalse(batch.finished)
        var groups = batch.groups
        let initialCompared = batch.compared
        // 保留会话即暂停；下一批从已提交游标继续。
        repeat { batch = try await session.nextBatch(); groups += batch.groups } while !batch.finished
        XCTAssertGreaterThan(batch.compared, initialCompared)
        XCTAssertEqual(batch.compared, 37*36/2)
        XCTAssertEqual(groups.filter { Set($0.ids) == Set([a.id!,b.id!]) }.count, 1)
        let saved = try XCTUnwrap(db.card(id: a.id!))
        XCTAssertEqual(saved.front, front)
    }
    func testCancelledBatchDoesNotAdvanceCursorAndLongCardCleanupKeepsSchedule() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let front = String(repeating: "一段完整历史文献的文字用于长卡片相似比较。", count: 1000)
        let back = String(repeating: "释义与出处说明文字。", count: 500)
        _ = try db.save(Card(front: front, back: back, state: .review, interval: 30))
        _ = try db.save(Card(front: front + "补", back: back + "注"))
        let session = try await FullSimilaritySession.create(db: db, deck: nil)
        let cancelled = Task {
            try await Task.sleep(for: .seconds(1))
            return try await session.nextBatch()
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("必须取消") } catch is CancellationError { }
        let progress = try await session.nextBatch()
        XCTAssertEqual(progress.compared, 1)
        let group = try XCTUnwrap(progress.groups.first)
        let keeper = group.cards[0]
        _ = try db.resolveCardDuplicateGroup(group, keeperID: keeper.id!)
        XCTAssertEqual(try db.card(id: keeper.id!), keeper)
    }

    func testFullSimilarityScopeAndNewRecordsSnapshot() async throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(deck: "甲", front: "这是足够长的问题文字甲乙丙丁戊己庚辛", back: "答案内容"))
        let session = try await FullSimilaritySession.create(db: db, deck: "甲")
        _ = try db.save(Card(deck: "甲", front: "后来加入", back: "答案"))
        let batch = try await session.nextBatch()
        XCTAssertTrue(batch.finished); XCTAssertEqual(batch.total, 1); XCTAssertEqual(batch.compared, 0)
    }
}
