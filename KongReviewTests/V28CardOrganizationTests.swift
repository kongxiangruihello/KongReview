import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V28CardOrganizationTests: XCTestCase {
    private func stored(_ card: Card, _ db: AppDatabase) throws -> Card {
        let saved = try db.save(card)
        return try XCTUnwrap(db.card(id: XCTUnwrap(saved.id)))
    }

    func testTagAndStateFiltersShareCountAndPagePredicateAndEscapeLiteralTags() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let literal = "专题%_\"\\标签"
        for i in 0..<7 {
            _ = try db.save(Card(deck: "甲", front: "查找题目 \(i)", tags: [literal], state: .review))
        }
        _ = try db.save(Card(deck: "甲", front: "查找其他", tags: [literal], state: .new))
        _ = try db.save(Card(deck: "甲", front: "查找暂停", tags: [literal], state: .review, isSuspended: true))
        _ = try db.save(Card(deck: "乙", front: "查找别组", tags: [literal], state: .review))
        _ = try db.save(Card(deck: "甲", front: "查找已删除", tags: [literal], state: .review, deletedAt: Date()))
        _ = try db.save(Card(deck: "甲", front: "查找非精确标签", tags: ["专题其他标签"], state: .review))
        let first = try await db.cardPage(deck: "甲", query: "查找", limit: 3, offset: 0, tag: literal, state: .review)
        let last = try await db.cardPage(deck: "甲", query: "查找", limit: 3, offset: 6, tag: literal, state: .review)
        XCTAssertEqual(first.total, 7)
        XCTAssertEqual(first.items.count, 3)
        XCTAssertEqual(last.total, 7)
        XCTAssertEqual(last.items.count, 1)
        XCTAssertTrue(Set(first.items.compactMap(\.id)).isDisjoint(with: Set(last.items.compactMap(\.id))))
        let suspended = try await db.cardPage(deck: "甲", query: "", limit: 200, offset: 0, state: .suspended)
        XCTAssertEqual(suspended.total, 1)
        let options = try await db.cardTagOptions(deck: "甲")
        XCTAssertEqual(Set(options), [literal, "专题其他标签"])
    }

    func testLearningFilterIncludesRelearningButExcludesSuspendedAndOtherStates() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for state: Card.State in [.new, .learning, .review, .relearning] {
            _ = try db.save(Card(front: "\(state)", state: state))
        }
        _ = try db.save(Card(front: "暂停重学", state: .relearning, isSuspended: true))
        let page = try await db.cardPage(deck: "默认", query: "", limit: 200, offset: 0, state: .learning)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(Set(page.items.map(\.state)), [.learning, .relearning])
    }

    func testBatchTagChangesOnlySelectedCardsPreserveScheduleAndUndoRestoresExactly() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = Card(deck: "甲", front: "问题", back: "答案", tags: ["原标签", "共享"], state: .review,
                        step: 2, interval: 41, ease: 2.3, reps: 9, lapses: 1, isSuspended: true)
        card.stability = 32
        card.difficulty = 5
        let a = try stored(card, db)
        let b = try stored(Card(deck: "甲", front: "第二张", tags: ["不同标签"]), db)
        let untouched = try stored(Card(deck: "甲", front: "未选择", tags: ["其他"]), db)
        db.log(ReviewEvent(kind: .card, cardId: a.id, answer: 3))
        let events = try db.events()
        let undo = try db.updateCardTags(ids: [a.id!, b.id!, a.id!], deck: "甲", tags: ["共享", "新标签"], mode: .add)
        var changedA = try XCTUnwrap(db.card(id: a.id!))
        XCTAssertEqual(changedA.tags, ["原标签", "共享", "新标签"])
        changedA.tags = a.tags
        changedA.updatedAt = a.updatedAt
        XCTAssertEqual(changedA, a)
        XCTAssertEqual(try db.card(id: b.id!)?.tags, ["不同标签", "共享", "新标签"])
        XCTAssertEqual(try db.card(id: untouched.id!), untouched)
        XCTAssertEqual(try db.events(), events)
        try db.restore(undo)
        var restoredA = try XCTUnwrap(db.card(id: a.id!))
        restoredA.updatedAt = a.updatedAt
        var restoredB = try XCTUnwrap(db.card(id: b.id!))
        restoredB.updatedAt = b.updatedAt
        XCTAssertEqual(restoredA, a)
        XCTAssertEqual(restoredB, b)
    }

    func testBatchRemovalUsesExactTagAndNoOpCreatesNoUndoEntries() throws {
        let db = try AppDatabase(DatabaseQueue())
        let card = try stored(Card(front: "题目", tags: ["史", "历史", "史料"]), db)
        let undo = try db.updateCardTags(ids: [card.id!], deck: "默认", tags: ["史"], mode: .remove)
        XCTAssertEqual(try db.card(id: card.id!)?.tags, ["历史", "史料"])
        XCTAssertEqual(undo.cards, [card])
        let noChange = try db.updateCardTags(ids: [card.id!], deck: "默认", tags: ["不存在"], mode: .remove)
        XCTAssertTrue(noChange.cardIds.isEmpty)
    }

    func testMovedDeletedOrMissingSelectionRollsBackEntireBatch() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try stored(Card(deck: "甲", front: "题一", tags: ["旧"]), db)
        let b = try stored(Card(deck: "乙", front: "题二", tags: ["旧"]), db)
        XCTAssertThrowsError(try db.updateCardTags(ids: [a.id!, b.id!], deck: "甲", tags: ["新"], mode: .add))
        XCTAssertEqual(try db.card(id: a.id!), a)
        XCTAssertThrowsError(try db.updateCardTags(ids: [a.id!, 999], deck: "甲", tags: ["新"], mode: .add))
        var deleted = b
        deleted.deck = "甲"
        deleted.deletedAt = Date()
        _ = try db.save(deleted)
        XCTAssertThrowsError(try db.updateCardTags(ids: [a.id!, b.id!], deck: "甲", tags: ["旧"], mode: .remove))
        XCTAssertEqual(try db.card(id: a.id!), a)
    }

    func testTagParserDeduplicatesAndAcceptsChineseSeparators() {
        XCTAssertEqual(AppDatabase.parsedCardTags(" #历史，历史 资料,  #文献\n资料 "), ["历史", "资料", "文献"])
        XCTAssertEqual(AppDatabase.parsedCardTags(" ,， ## "), [])
        XCTAssertEqual(AppDatabase.parsedCardTags("C# #历史"), ["C#", "历史"])
    }

    @MainActor
    func testFilterChangesClearPageSelectionAndStaleLoadTokenAndPersistPerDeck() throws {
        let suite = "KongReview.CardFilterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = StudyState(defaults: defaults)
        state.openCardBrowser("甲")
        state.browsePage = 4
        state.browseItems = [Card(id: 12, front: "题目")]
        state.browseSelection = [12]
        let token = state.browseLoadID
        state.browseTag = "历史"
        XCTAssertEqual(state.browsePage, 1)
        XCTAssertTrue(state.browseSelection.isEmpty)
        XCTAssertTrue(state.browseItems.isEmpty)
        XCTAssertNotEqual(state.browseLoadID, token)
        state.browseStateFilter = .review
        state.browsePage = 3
        state.openCardBrowser("乙")
        XCTAssertEqual(state.browseTag, "")
        XCTAssertEqual(state.browseStateFilter, .all)
        state.openCardBrowser("甲")
        XCTAssertEqual(state.browseTag, "历史")
        XCTAssertEqual(state.browseStateFilter, .review)
        XCTAssertEqual(state.browsePage, 3)
        let restored = StudyState(defaults: defaults)
        restored.openCardBrowser("甲")
        XCTAssertEqual(restored.browseTag, "历史")
        XCTAssertEqual(restored.browseStateFilter, .review)
    }

    func testOldBrowsePositionDecodesWithoutNewFilterFields() throws {
        let old = Data(#"{"query":"旧搜索","page":3,"pageSize":50,"anchorID":8}"#.utf8)
        let decoded = try JSONDecoder().decode(CardBrowsePosition.self, from: old)
        XCTAssertNil(decoded.tag)
        XCTAssertNil(decoded.stateFilter)
        XCTAssertEqual(decoded.page, 3)
    }

    @MainActor
    func testBatchActionRestrictsSelectionToVisiblePageAndRegistersUndoRedo() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let visible = try stored(Card(deck: "甲", front: "本页", tags: ["旧"]), db)
        let otherPage = try stored(Card(deck: "甲", front: "其他页", tags: ["旧"]), db)
        let store = LibraryStore(db: db, positionDefaults: nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.study.openCardBrowser("甲")
        store.study.browseItems = [visible]
        store.editCardTags(.add, ids: [visible.id!, otherPage.id!], deck: "甲")
        XCTAssertEqual(store.study.cardTagEdit?.cardIDs, [visible.id!])
        store.study.cardTagEdit?.text = "新"
        undo.beginUndoGrouping()
        store.applyCardTagEdit()
        for _ in 0..<100 {
            if store.study.cardTagEdit == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        undo.endUndoGrouping()
        XCTAssertNil(store.study.cardTagEdit)
        XCTAssertEqual(try db.card(id: visible.id!)?.tags, ["旧", "新"])
        XCTAssertEqual(try db.card(id: otherPage.id!), otherPage)
        XCTAssertTrue(undo.canUndo)
        // 标签之后评分属于另一套排程撤销；标签的 ⌘Z 不得把该评分及新标签覆盖。
        _ = try db.answer(try XCTUnwrap(db.card(id: visible.id!)), .good)
        var learned = try XCTUnwrap(db.card(id: visible.id!))
        learned.tags.append("之后添加")
        _ = try db.save(learned)
        learned = try XCTUnwrap(db.card(id: visible.id!))
        let events = try db.events()
        undo.undo()
        var undone = try XCTUnwrap(db.card(id: visible.id!))
        XCTAssertEqual(undone.tags, ["旧", "之后添加"])
        undone.tags = learned.tags
        undone.updatedAt = learned.updatedAt
        XCTAssertEqual(undone, learned)
        undo.redo()
        var redone = try XCTUnwrap(db.card(id: visible.id!))
        XCTAssertEqual(redone.tags, ["旧", "之后添加", "新"])
        redone.tags = learned.tags
        redone.updatedAt = learned.updatedAt
        XCTAssertEqual(redone, learned)
        XCTAssertEqual(try db.events(), events)
    }

    func testTagUndoDoesNotReviveDeletedOrMissingCards() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try stored(Card(front: "后来删除", tags: ["旧"]), db)
        let b = try stored(Card(front: "后来清空", tags: ["旧"]), db)
        let snapshot = try db.updateCardTags(ids: [a.id!, b.id!], deck: "默认", tags: ["新"], mode: .add)
        var deleted = try XCTUnwrap(db.card(id: a.id!))
        deleted.deletedAt = Date()
        _ = try db.save(deleted)
        try db.deleteCards([b.id!])
        try db.restore(snapshot)
        XCTAssertNotNil(try db.card(id: a.id!)?.deletedAt)
        XCTAssertNil(try db.card(id: b.id!))
    }
}
