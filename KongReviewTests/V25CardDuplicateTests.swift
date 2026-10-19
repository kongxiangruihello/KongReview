import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V25CardDuplicateTests: XCTestCase {
    /// SQLite 日期会经编码后再读取；完整快照断言应与落库值比较，不能与落库前纳秒精度的值比较。
    private func saveStored(_ card: Card, to db: AppDatabase) throws -> Card {
        let saved = try db.save(card)
        let id = try XCTUnwrap(saved.id)
        return try XCTUnwrap(db.card(id: id))
    }

    func testScanFindsTrimmedCanonicalUnicodeAndSectionDuplicatesAcrossDecks() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var first = Card(deck: "甲", front: "  cafe\u{301}\n", back: " 答案 ", tags: ["甲标签"])
        first.sections = [CardSection(id: "uuid-a", name: " 注释 ", text: " 内容\n", folded: false)]
        var second = Card(deck: "乙", front: "café", back: "答案", state: .review, interval: 30, reps: 20)
        second.sections = [CardSection(id: "uuid-b", name: "注释", text: "内容", folded: true),
                           CardSection(name: " ", text: "\n")]
        let a = try saveStored(first, to: db)
        let b = try saveStored(second, to: db)
        _ = try db.save(Card(front: "其他题目", back: "答案"))
        _ = try db.save(Card(front: "café", back: "答案", deletedAt: Date()))
        let groups = try await db.cardDuplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.ids, [a.id!, b.id!])
        XCTAssertEqual(groups.first?.cards.map(\.deck), ["甲", "乙"])
    }

    func testDifferentTemplatesOrFieldsCannotBeClassifiedAsDuplicates() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var original = Card(front: "缓存正面", back: "缓存背面")
        original.noteType = "模板甲"
        original.fields = ["正面", "答案", "出处甲"]
        var otherTemplate = original
        otherTemplate.noteType = "模板乙"
        var otherFields = original
        otherFields.fields[2] = "出处乙"
        var whitespaceField = original
        whitespaceField.fields[2] += " "
        _ = try db.save(original)
        _ = try db.save(otherTemplate)
        _ = try db.save(otherFields)
        _ = try db.save(whitespaceField)
        let groups = try await db.cardDuplicateGroups()
        XCTAssertTrue(groups.isEmpty)
    }

    func testDifferentSectionContentAndOrderRemainSeparate() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var first = Card(front: "问题", back: "答案")
        first.sections = [CardSection(name: "注释", text: "甲"), CardSection(name: "出处", text: "乙")]
        var different = first
        different.sections?[0].text = "不同内容"
        var reordered = first
        reordered.sections = Array(first.sections!.reversed())
        _ = try db.save(first)
        _ = try db.save(different)
        _ = try db.save(reordered)
        let groups = try await db.cardDuplicateGroups()
        XCTAssertTrue(groups.isEmpty)
    }

    func testStableGroupSignatureDoesNotDependOnDatabaseIDsOrMetadata() {
        let first = Card(id: 1, deck: "甲", front: "问题", back: "答案", tags: ["甲"], interval: 10, reps: 3)
        let second = Card(id: 900, deck: "乙", front: "问题", back: "答案", tags: ["乙"], interval: 90, reps: 30)
        let firstSignature = CardDuplicateSignature(first)
        XCTAssertEqual(firstSignature, CardDuplicateSignature(second))
        XCTAssertEqual(firstSignature.stableID, CardDuplicateSignature(second).stableID)
        XCTAssertEqual(firstSignature.stableID.count, 64)
    }

    func testResolvePreservesKeeperExactlyAndSoftDeletesOnlyOtherCards() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var learned = Card(deck: "保留牌组", front: "问题", back: "答案", tags: ["保留标签"],
                           state: .review, step: 2, interval: 58.2, ease: 2.1, reps: 27, lapses: 3)
        learned.stability = 40.3
        learned.difficulty = 4.7
        learned.lastReview = Date()
        let keeper = try saveStored(learned, to: db)
        let other = try saveStored(Card(deck: "其他牌组", front: "问题", back: "答案", tags: ["其他标签"]), to: db)
        let unrelated = try saveStored(Card(front: "无关问题", back: "答案"), to: db)
        db.log(ReviewEvent(kind: .card, cardId: keeper.id, answer: 3))
        db.log(ReviewEvent(kind: .card, cardId: other.id, answer: 1))
        let eventsBefore = try db.events()
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let undo = try db.resolveCardDuplicateGroup(group, keeperID: keeper.id!, now: now)
        XCTAssertEqual(try db.card(id: keeper.id!), keeper)
        XCTAssertEqual(try db.card(id: unrelated.id!), unrelated)
        XCTAssertEqual(try db.card(id: other.id!)?.deletedAt, now)
        XCTAssertEqual(try db.card(id: other.id!)?.tags, other.tags)
        XCTAssertEqual(try db.cardCount(), 2)
        XCTAssertEqual(undo.cardIds, [other.id!])
        XCTAssertEqual(undo.cards, [other])
        XCTAssertEqual(try db.events(), eventsBefore)
    }

    func testDeletedCandidateMakesWholeResolutionStaleWithoutPartialDeletion() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let cards = try (0..<3).map { try saveStored(Card(deck: "牌组\($0)", front: "问题", back: "答案"), to: db) }
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        var deleted = cards[2]
        deleted.deletedAt = Date()
        _ = try db.save(deleted)
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: cards[0].id!)) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .staleScan)
        }
        XCTAssertNil(try db.card(id: cards[1].id!)?.deletedAt)
        XCTAssertEqual(try db.card(id: cards[0].id!), cards[0])
    }

    func testProgressChangeAfterScanPreventsDeletingOrOverwritingEitherCard() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        _ = try db.answer(second, .good)
        let answered = try XCTUnwrap(db.card(id: second.id!))
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: first.id!)) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .staleScan)
        }
        XCTAssertEqual(try db.card(id: second.id!), answered)
        XCTAssertNil(try db.card(id: first.id!)?.deletedAt)
        XCTAssertEqual(try db.events().count, 1)
    }

    func testTagOrDeckChangeAfterScanAlsoRequiresRescan() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        var changed = first
        changed.deck = "后来移动的牌组"
        changed.tags = ["新增标签"]
        changed = try saveStored(changed, to: db)
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: first.id!))
        XCTAssertEqual(try db.card(id: first.id!), changed)
        XCTAssertEqual(try db.card(id: second.id!), second)
    }

    func testInvalidKeeperAndTamperedSignatureAreRejected() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let groups = try await db.cardDuplicateGroups()
        var group = try XCTUnwrap(groups.first)
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: 999)) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .invalidKeeper)
        }
        group.signature.front = "不是这些卡片的内容"
        XCTAssertThrowsError(try db.resolveCardDuplicateGroup(group, keeperID: first.id!)) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .staleScan)
        }
        XCTAssertEqual(try db.card(id: first.id!), first)
        XCTAssertEqual(try db.card(id: second.id!), second)
    }

    func testBackupFailureAbortsBeforeAnyDatabaseChange() async throws {
        enum Failure: Error { case noBackup }
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        var attempted = 0
        XCTAssertThrowsError(try CardDuplicateCleanup.resolve(db: db, group: group, keeperID: first.id!,
                                                             backupRequired: true) {
            attempted += 1
            throw Failure.noBackup
        })
        XCTAssertEqual(attempted, 1)
        XCTAssertEqual(try db.card(id: first.id!), first)
        XCTAssertEqual(try db.card(id: second.id!), second)
    }

    func testChangesDuringBackupAreCheckedAfterBackupBeforeDeleting() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        XCTAssertThrowsError(try CardDuplicateCleanup.resolve(db: db, group: group, keeperID: first.id!,
                                                             backupRequired: true) {
            var changed = second
            changed.back = "备份期间更新的答案"
            _ = try db.save(changed)
        }) {
            XCTAssertEqual($0 as? CardDuplicateCleanupError, .staleScan)
        }
        XCTAssertNil(try db.card(id: second.id!)?.deletedAt)
        XCTAssertEqual(try db.card(id: second.id!)?.back, "备份期间更新的答案")
    }

    func testUndoRestoresDeletedCardsAndLeavesKeeperAndReviewHistoryUntouched() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saveStored(Card(front: "问题", back: "答案"), to: db)
        let second = try saveStored(Card(front: "问题", back: "答案"), to: db)
        db.log(ReviewEvent(kind: .card, cardId: second.id, answer: 3))
        let groups = try await db.cardDuplicateGroups()
        let group = try XCTUnwrap(groups.first)
        var backupCalls = 0
        let undo = try CardDuplicateCleanup.resolve(db: db, group: group, keeperID: first.id!, backupRequired: false) {
            backupCalls += 1
        }
        XCTAssertEqual(backupCalls, 0)
        _ = try db.answer(first, .good)
        let learnedKeeper = try XCTUnwrap(db.card(id: first.id!))
        try db.restore(undo)
        XCTAssertEqual(try db.card(id: first.id!), learnedKeeper)
        XCTAssertEqual(try db.card(id: second.id!), second)
        XCTAssertEqual(try db.events().count, 2)
        XCTAssertEqual(try db.cardCount(), 2)
    }
}
