import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V28CardSimilarityTests: XCTestCase {
    private let front = "请解释中国近代历史发展进程中的社会结构变化，以及这些变化产生的具体历史条件和持续影响。"
    private let back = "社会经济发展推动制度与思想发生变化，不同地区的具体发展阶段和历史背景决定了变化的方向与速度。"
    private func stored(_ card: Card, _ db: AppDatabase) throws -> Card {
        let value = try db.save(card)
        return try XCTUnwrap(db.card(id: XCTUnwrap(value.id)))
    }

    func testBothFacesNeedHighSimilarityAndFormattingIsNormalized() {
        let a = Card(front: front, back: back)
        let b = Card(front: "<b>" + front + "</b>", back: "<p>" + back + "</p>")
        XCTAssertEqual(CardSimilarity.score(a, b), 1)
        let near = Card(front: front.replacingOccurrences(of: "持续影响", with: "长期影响"), back: back)
        XCTAssertGreaterThan(CardSimilarity.score(a, near) ?? 0, 0.92)
        XCTAssertNil(CardSimilarity.score(a, Card(front: front, back: "完全不同的答案")))
        XCTAssertNil(CardSimilarity.score(Card(front: "成立时间", back: "1912年"), Card(front: "成立时间", back: "1913年")))
    }

    func testTemplateFieldsSectionsAndMediaDifferencesAreNotSuggested() {
        let a = Card(front: front, back: back)
        var differentType = a
        differentType.noteType = "不同模板"
        XCTAssertNil(CardSimilarity.score(a, differentType))
        var fields = a
        fields.fields = ["独立字段"]
        XCTAssertNil(CardSimilarity.score(a, fields))
        var section = a
        section.sections = [CardSection(name: "出处", text: "不同来源")]
        XCTAssertNil(CardSimilarity.score(a, section))
        let pictureA = Card(front: front + "<img src=\"one.png\">", back: back)
        let pictureB = Card(front: front + "<img src=\"two.png\">", back: back)
        XCTAssertNil(CardSimilarity.score(pictureA, pictureB))
        XCTAssertNil(CardSimilarity.score(Card(front: front + "<img src=one.png>", back: back),
                                          Card(front: front + "<img src=two.png>", back: back)))
        let audioA = Card(front: front, back: back + " [sound:one.mp3]")
        let audioB = Card(front: front, back: back + " [sound:two.mp3]")
        XCTAssertNil(CardSimilarity.score(audioA, audioB))
    }

    func testSimilarityScanIsSeparateFromExactDuplicatesAndIgnoresDeletedCards() async throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(front: front, back: back))
        _ = try db.save(Card(front: front, back: back))
        let similar = try db.save(Card(front: "<b>" + front + "</b>", back: back))
        _ = try db.save(Card(front: "<i>" + front + "</i>", back: back, deletedAt: Date()))
        let exact = try await db.cardDuplicateGroups()
        let scan = try await db.similarCardGroups()
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(scan.groups.count, 2)
        XCTAssertTrue(scan.groups.allSatisfy { $0.similarityScore == 1 && $0.ids.contains(similar.id!) })
    }

    func testDeckScopedScanCanCompareOlderCardsWithoutPullingOtherDecks() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Card(deck: "旧牌组", front: front, back: back))
        let b = try db.save(Card(deck: "旧牌组", front: "<b>" + front + "</b>", back: back))
        _ = try db.save(Card(deck: "其他牌组", front: "<i>" + front + "</i>", back: back))
        let scan = try await db.similarCardGroups(deck: "旧牌组")
        XCTAssertEqual(scan.groups.count, 1)
        XCTAssertEqual(Set(scan.groups.first?.ids ?? []), [a.id!, b.id!])
        XCTAssertEqual(scan.scannedCount, 2)
    }

    func testSimilarityResolutionPreservesKeeperScheduleHistoryAndUndo() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var learned = Card(deck: "已学牌组", front: front, back: back, tags: ["保留"], state: .review,
                           interval: 84, ease: 2.2, reps: 30, lapses: 3)
        learned.stability = 50
        learned.difficulty = 4
        let keeper = try stored(learned, db)
        let other = try stored(Card(deck: "导入牌组", front: "<b>" + front + "</b>", back: back), db)
        db.log(ReviewEvent(kind: .card, cardId: other.id, answer: 2))
        let events = try db.events()
        let scan = try await db.similarCardGroups()
        let group = try XCTUnwrap(scan.groups.first)
        var backups = 0
        let undo = try CardDuplicateCleanup.resolve(db: db, group: group, keeperID: keeper.id!, backupRequired: true) {
            backups += 1
        }
        XCTAssertEqual(backups, 1)
        XCTAssertEqual(try db.card(id: keeper.id!), keeper)
        XCTAssertNotNil(try db.card(id: other.id!)?.deletedAt)
        XCTAssertEqual(try db.events(), events)
        try db.restore(undo)
        XCTAssertEqual(try db.card(id: other.id!), other)
        XCTAssertEqual(try db.card(id: keeper.id!), keeper)
    }

    func testUpdatedScheduleMakesSimilaritySnapshotStale() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try stored(Card(front: front, back: back), db)
        let b = try stored(Card(front: "<i>" + front + "</i>", back: back), db)
        let scan = try await db.similarCardGroups()
        let group = try XCTUnwrap(scan.groups.first)
        _ = try db.answer(b, .good)
        let updated = try db.card(id: b.id!)
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: a.id!)) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .staleScan)
        }
        XCTAssertNil(try db.card(id: a.id!)?.deletedAt)
        XCTAssertEqual(try db.card(id: b.id!), updated)
    }

    func testOverlongFacesAreSkippedInsteadOfComparingTruncatedContent() throws {
        let text = String(repeating: "长", count: CardSimilarity.textLimit + 1)
        let scan = try CardSimilarity.scan([Card(id: 1, front: text, back: back), Card(id: 2, front: text + "不同结尾", back: back)], total: 2)
        XCTAssertTrue(scan.groups.isEmpty)
        XCTAssertEqual(scan.omittedCount, 2)
    }

    func testSuggestionsAreBoundedAndReportAdditionalUnscannedCards() throws {
        let cards = (0..<200).map { Card(id: Int64($0 + 1), front: "<span class=\"variant-\($0)\">" + front + "</span>", back: back) }
        let scan = try CardSimilarity.scan(cards, total: CardSimilarity.cardLimit + 200)
        XCTAssertEqual(scan.groups.count, CardSimilarity.suggestionLimit)
        XCTAssertTrue(scan.suggestionsLimited)
        XCTAssertGreaterThanOrEqual(scan.omittedCount, CardSimilarity.cardLimit)
        XCTAssertTrue(scan.groups.allSatisfy { $0.cards.count == 2 })
        XCTAssertEqual(Set(scan.groups.map(\.id)).count, scan.groups.count)
    }
}
