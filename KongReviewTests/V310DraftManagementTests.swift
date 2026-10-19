import XCTest
import KongReviewCore
@testable import KongReview

final class V310DraftManagementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func highlight(_ text: String, id: UUID = UUID(), seconds: TimeInterval = 0) -> SavedHighlightDraft {
        var value = SavedHighlightDraft(draft: HighlightDraft(highlight: Highlight(text: text)),
                                        original: nil, originalEditionPages: [:])
        value.id = id; value.savedAt = now.addingTimeInterval(seconds)
        return value
    }

    private func card(_ front: String, deck: String = "默认", id: UUID = UUID(), seconds: TimeInterval = 0) -> SavedCardDraft {
        var value = SavedCardDraft(draft: CardDraft(card: Card(deck: deck, front: front)), original: nil)
        value.id = id; value.savedAt = now.addingTimeInterval(seconds)
        return value
    }

    func testRecentFirstMixedKindsAndStableTieOrder() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let highlights = [highlight("最早", seconds: -2), highlight("最新", seconds: 2)]
        let cards = [card("卡乙", id: b), card("卡甲", id: a)]
        let first = EditorDraftQuery().page(highlights: highlights, cards: cards, requestedPage: 1)
        let reordered = EditorDraftQuery().page(highlights: highlights.reversed(), cards: cards.reversed(), requestedPage: 1)
        XCTAssertEqual(first.items.map(\.id), reordered.items.map(\.id))
        XCTAssertEqual(first.items.map(\.title), ["最新", "卡甲", "卡乙", "最早"])
    }

    func testFiftyRowsPerPageNoDuplicatesAndClampsAfterRemoval() {
        let values = (0..<121).map { card("卡片 \($0)", seconds: Double($0)) }
        let query = EditorDraftQuery()
        let first = query.page(highlights: [], cards: values, requestedPage: 1)
        let second = query.page(highlights: [], cards: values, requestedPage: 2)
        let third = query.page(highlights: [], cards: values, requestedPage: 3)
        XCTAssertEqual([first.items.count, second.items.count, third.items.count], [50, 50, 21])
        XCTAssertEqual(first.pageCount, 3); XCTAssertEqual(third.total, 121)
        XCTAssertEqual(Set((first.items + second.items + third.items).map(\.id)).count, 121)
        XCTAssertEqual(second.rangeText, "第 51–100 份，共 121 份")
        let shrunk = query.page(highlights: [], cards: Array(values.prefix(51)), requestedPage: 3)
        XCTAssertEqual(shrunk.page, 2); XCTAssertEqual(shrunk.items.count, 1)
        let empty = query.page(highlights: [], cards: [], requestedPage: Int.max)
        XCTAssertEqual(empty.page, 1); XCTAssertEqual(empty.pageCount, 1)
        XCTAssertEqual(empty.rangeText, "共 0 份草稿")
        XCTAssertEqual(query.page(highlights: [], cards: values, requestedPage: -5).page, 1)
    }

    func testTypeAndDeckFiltersHaveExplicitCardOnlyScope() {
        let highlights = [highlight("统一")]
        let cards = [card("统一", deck: "历史"), card("统一", deck: "文学"), card("其他", deck: "历史")]
        var query = EditorDraftQuery(keyword: "统一", kind: .highlight)
        XCTAssertEqual(query.page(highlights: highlights, cards: cards, requestedPage: 1).total, 1)
        query.kind = .card
        XCTAssertEqual(query.page(highlights: highlights, cards: cards, requestedPage: 1).total, 2)
        query.kind = .all
        XCTAssertEqual(query.page(highlights: highlights, cards: cards, requestedPage: 1).total, 3)
        query.deck = "历史"
        let scoped = query.page(highlights: highlights, cards: cards, requestedPage: 1)
        XCTAssertEqual(scoped.total, 1)
        XCTAssertTrue(scoped.items.allSatisfy { if case .card = $0 { return true }; return false })
        query.kind = .highlight
        XCTAssertEqual(query.page(highlights: highlights, cards: cards, requestedPage: 1).total, 1)
        XCTAssertEqual(EditorDraftQuery.decks(in: cards), ["历史", "文学"])
    }

    func testSearchMatchesTraditionalFullWidthTagsSourceAndAllCardColumns() {
        var h = highlight("<p>中國近代史 &amp; 文獻</p>")
        h.highlight.translation = "统一译文"; h.highlight.note = "按语线索"
        h.newSourceTitle = "史料集"; h.newSourceAuthor = "作者某"; h.tagsText = "研究"
        var c = card("题面", deck: "歷史")
        c.card.back = "背面说明"; c.card.fields = ["字段答案 ＡＢＣ"]
        c.card.sections = [.init(name: "解释", text: "折叠释义")]; c.tagsText = "重点"
        for term in ["中国", "文献", "统一译文", "按语线索", "史料集", "作者某", "研究", "文獻 &"] {
            XCTAssertEqual(EditorDraftQuery(keyword: term).page(highlights: [h], cards: [], requestedPage: 1).total, 1, term)
        }
        for term in ["历史", "背面说明", "字段答案 abc", "折叠释义", "解释", "重点"] {
            XCTAssertEqual(EditorDraftQuery(keyword: term).page(highlights: [], cards: [c], requestedPage: 1).total, 1, term)
        }
        XCTAssertEqual(EditorDraftQuery(keyword: "字段答案 不存在").page(highlights: [], cards: [c], requestedPage: 1).total, 0)
    }

    func testLiteralSearchAndLongTextAreCompleteWithoutMutatingFixtures() throws {
        let long = String(repeating: "古籍正文", count: 10_000) + "末尾线索 50%_"
        var h = highlight(long); h.highlight.note = "完整按语"
        var c = card("问题"); c.card.back = long
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeHighlights = try encoder.encode([h]), beforeCards = try encoder.encode([c])
        let results = EditorDraftQuery(keyword: "末尾线索 50%_").page(highlights: [h], cards: [c], requestedPage: 1)
        XCTAssertEqual(results.total, 2)
        for item in results.items {
            switch item {
            case .highlight(let saved): XCTAssertEqual(saved.highlight.text, long); XCTAssertEqual(saved.highlight.note, "完整按语")
            case .card(let saved): XCTAssertEqual(saved.card.back, long)
            }
        }
        XCTAssertEqual(try encoder.encode([h]), beforeHighlights)
        XCTAssertEqual(try encoder.encode([c]), beforeCards)
    }

    func testFrozenPreviewRejectsMissingOrUpdatedDraftEvenWithSameIDAndDate() {
        var h = highlight("原正文"), c = card("原题面")
        let savedHighlight = EditorDraftItem.highlight(h), savedCard = EditorDraftItem.card(c)
        XCTAssertTrue(savedHighlight.matches(.highlight(h))); XCTAssertTrue(savedCard.matches(.card(c)))
        h.highlight.note = "后台新内容"; c.card.back = "后台新答案"
        XCTAssertFalse(savedHighlight.matches(.highlight(h))); XCTAssertFalse(savedCard.matches(.card(c)))
        XCTAssertFalse(savedHighlight.current(in: [h], cards: [c]).map { savedHighlight.matches($0) } ?? false)
        XCTAssertNil(savedCard.current(in: [h], cards: []))
        var onlyDate = card("原题面", id: c.id)
        onlyDate.savedAt = c.savedAt.addingTimeInterval(1)
        XCTAssertFalse(savedCard.matches(.card(onlyDate)))
    }

    func testSameUUIDAcrossKindsRemainsDistinctAndSafe() {
        let id = UUID(), h = highlight("摘录", id: id), c = card("记忆卡", id: id)
        let result = EditorDraftQuery().page(highlights: [h], cards: [c], requestedPage: 1)
        XCTAssertEqual(Set(result.items.map(\.id)).count, 2)
        XCTAssertFalse(EditorDraftItem.highlight(h).matches(.card(c)))
        XCTAssertTrue(EditorDraftItem.card(c).current(in: [h], cards: [c]).map { EditorDraftItem.card(c).matches($0) } ?? false)
    }
}
