import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V242CardPagingTests: XCTestCase {
    func testEveryCardIsReachableAcrossPagesIncludingSuspendedCards() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for index in 0..<451 {
            try db.save(Card(deck: "分页牌组", front: "第\(index)张", isSuspended: index.isMultiple(of: 17),
                             createdAt: Date(timeIntervalSince1970: Double(1000 + index / 7))))
        }
        try db.save(Card(deck: "别的牌组", front: "不在此牌组"))
        try db.save(Card(deck: "分页牌组", front: "已删除", deletedAt: Date()))

        let expected = try db.cards(deck: "分页牌组")
        XCTAssertEqual(expected.count, 451, "学习等完整查询仍能读取牌组内全部卡片")
        var loaded: [Card] = []
        for offset in stride(from: 0, to: expected.count, by: 200) {
            let page = try await db.cardPage(deck: "分页牌组", query: "", limit: 200, offset: offset)
            XCTAssertEqual(page.total, expected.count)
            XCTAssertEqual(page.items.count, min(200, expected.count - offset))
            loaded += page.items
        }
        XCTAssertEqual(loaded.compactMap(\.id), expected.compactMap(\.id))
        XCTAssertEqual(Set(loaded.compactMap(\.id)).count, 451)
        XCTAssertEqual(loaded.filter(\.isSuspended).count, 27)
        for (left, right) in zip(loaded, loaded.dropFirst()) {
            XCTAssertTrue(left.createdAt > right.createdAt ||
                          (left.createdAt == right.createdAt && left.id! > right.id!))
        }
    }

    func testPageFiltersDeckSearchDeletedCardsAndWhitespace() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let front = try db.save(Card(deck: "甲", front: "红卫兵研究"))
        let back = try db.save(Card(deck: "甲", front: "问题", back: "紅衛兵研究", isSuspended: true))
        try db.save(Card(deck: "甲", front: "无关"))
        try db.save(Card(deck: "甲", front: "红卫兵已删除", deletedAt: Date()))
        try db.save(Card(deck: "乙", front: "红卫兵其他牌组"))

        let first = try await db.cardPage(deck: "甲", query: "  紅衛兵\n", limit: 1, offset: 0)
        let second = try await db.cardPage(deck: "甲", query: "红卫兵", limit: 1, offset: 1)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(second.total, 2)
        XCTAssertEqual(Set((first.items + second.items).compactMap(\.id)), Set([front.id!, back.id!]))
        let noMatch = try await db.cardPage(deck: "不存在", query: "", limit: 200, offset: 0)
        XCTAssertEqual(noMatch.total, 0)
        XCTAssertTrue(noMatch.items.isEmpty)
        let blank = try await db.cardPage(deck: "甲", query: " \n ", limit: 200, offset: 0)
        XCTAssertEqual(blank.total, 3)
    }

    func testTagAndSectionSearchMatchesBothChineseScriptsInPagedAndFullQueries() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let tagCard = try db.save(Card(deck: "历史", front: "标签题", tags: ["近現代史", "紅衛兵"]))
        var sectionCard = Card(deck: "历史", front: "栏目题")
        sectionCard.sections = [CardSection(name: "参考", text: "近现代史")]
        sectionCard = try db.save(sectionCard)
        try db.save(Card(deck: "其他", front: "其他题", tags: ["近现代史"]))

        for query in ["近现代史", "近現代史"] {
            let page = try await db.cardPage(deck: "历史", query: query, limit: 200, offset: 0)
            XCTAssertEqual(page.total, 2)
            XCTAssertEqual(Set(page.items.compactMap(\.id)), Set([tagCard.id!, sectionCard.id!]))
            XCTAssertEqual(page.items.compactMap(\.id), try db.cards(deck: "历史", query: query).compactMap(\.id))
        }
        let tags = try await db.cardPage(deck: "历史", query: "红卫兵", limit: 200, offset: 0)
        XCTAssertEqual(tags.items.first?.id, tagCard.id)
        XCTAssertEqual(tags.total, 1)
    }

    func testSearchEscapesLikeWildcardsAndDecodesTagJSON() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let percent = try db.save(Card(deck: "甲", front: "100%完成"))
        let underscore = try db.save(Card(deck: "甲", front: "问题", back: "a_b"))
        var section = Card(deck: "甲", front: "栏目题")
        section.sections = [CardSection(name: "例句", text: "50%_已完成")]
        section = try db.save(section)
        let escapedTag = "标签\"\\100%_"
        let tag = try db.save(Card(deck: "甲", front: "标签题", tags: [escapedTag]))
        try db.save(Card(deck: "甲", front: "100个完成", back: "axb"))

        let cases: [(String, Set<Int64>)] = [
            ("%", Set([percent.id!, section.id!, tag.id!])),
            ("_", Set([underscore.id!, section.id!, tag.id!])),
            ("\\", Set([tag.id!])),
            (escapedTag, Set([tag.id!]))
        ]
        for (query, expected) in cases {
            let page = try await db.cardPage(deck: "甲", query: query, limit: 200, offset: 0)
            XCTAssertEqual(Set(page.items.compactMap(\.id)), expected, query)
            XCTAssertEqual(page.total, expected.count, query)
            XCTAssertEqual(Set(try db.cards(deck: "甲", query: query).compactMap(\.id)), expected, query)
        }
    }

    func testLastPageCountUpdatesAfterDeletionAndMovingCards() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for index in 0..<405 {
            try db.save(Card(deck: "甲", front: "卡片\(index)", createdAt: Date(timeIntervalSince1970: 1000)))
        }
        let last = try await db.cardPage(deck: "甲", query: "", limit: 200, offset: 400)
        XCTAssertEqual(last.total, 405)
        XCTAssertEqual(last.items.count, 5)
        try db.deleteCards([try XCTUnwrap(last.items.first?.id)])
        var softDeleted = last.items[1]
        softDeleted.deletedAt = Date()
        try db.save(softDeleted)
        for var card in last.items.dropFirst(2) {
            card.deck = "乙"
            try db.save(card)
        }

        let emptyLast = try await db.cardPage(deck: "甲", query: "", limit: 200, offset: 400)
        XCTAssertEqual(emptyLast.total, 400)
        XCTAssertTrue(emptyLast.items.isEmpty)
        let previous = try await db.cardPage(deck: "甲", query: "", limit: 200, offset: 200)
        XCTAssertEqual(previous.total, 400)
        XCTAssertEqual(previous.items.count, 200)
        let destination = try await db.cardPage(deck: "乙", query: "", limit: 200, offset: 0)
        XCTAssertEqual(destination.total, 3)
    }
}
