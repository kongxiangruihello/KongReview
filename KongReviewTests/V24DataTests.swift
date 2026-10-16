import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V24DataTests: XCTestCase {
    func testAnkiIdenticalMediaReusesOriginalName() throws {
        let db = try AppDatabase(DatabaseQueue())
        let image = Data([1, 2, 3])
        let first = AnkiNote(front: #"<img src="image.png">"#, back: "第一张", tags: [], deck: "甲", guid: "first", schedule: nil)
        let second = AnkiNote(front: first.front, back: "第二张", tags: [], deck: "乙", guid: "second", schedule: nil)
        XCTAssertEqual(try db.importAnki([first], media: ["image.png": image]).media, 1)
        let report = try db.importAnki([second], media: ["image.png": image])
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.media, 0)
        XCTAssertTrue(try db.cards().allSatisfy { $0.front == first.front })
        XCTAssertEqual(try db.media(named: "image.png"), image)
    }

    func testAnkiMediaConflictsPreserveOldCardsAndReuseNewMedia() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = Data([1, 2, 3]), incoming = Data([4, 5, 6])
        let old = AnkiNote(front: #"<img src="image.png">"#, back: "", tags: [], deck: "旧包", guid: "old", schedule: nil)
        try db.importAnki([old], media: ["image.png": original])
        var note = AnkiNote(front: #"<img src='image.png'> 正文 image.png"#, back: "[sound:image.png]", tags: [], deck: "新包", guid: "new", schedule: nil)
        note.noteType = "图片笔记"
        note.fieldNames = ["正面", "背面"]
        note.fields = [#"<img src="image.png">"#, "![图片](kr-media://media/image.png)"]

        let report = try db.importAnki([note], media: ["image.png": incoming])
        let name = "image-" + SHA1.hex(incoming) + ".png"
        let cards = try db.cards()
        let oldCard = try XCTUnwrap(cards.first { $0.ankiGuid == "old" })
        let newCard = try XCTUnwrap(cards.first { $0.ankiGuid == "new" })
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.media, 1)
        XCTAssertEqual(oldCard.front, old.front)
        XCTAssertEqual(try db.media(named: "image.png"), original)
        XCTAssertEqual(try db.media(named: name), incoming)
        XCTAssertEqual(newCard.front, "<img src='\(name)'> 正文 image.png")
        XCTAssertEqual(newCard.back, "[sound:\(name)]")
        XCTAssertTrue(newCard.fields.allSatisfy { $0.contains(name) })
        let repeated = try db.importAnki([note], media: ["image.png": incoming])
        XCTAssertEqual(repeated.duplicates, 1)
        XCTAssertEqual(repeated.media, 0)
        XCTAssertEqual(try db.cards().count, 2)
    }

    func testAnkiDuplicateGUIDUpgradeUsesRenamedFieldMedia() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = Data([1]), incoming = Data([2])
        let old = AnkiNote(front: #"<img src="image.png">"#, back: "", tags: [], deck: "旧包", guid: "same", schedule: nil)
        try db.importAnki([old], media: ["image.png": original])
        var upgrade = old
        upgrade.noteType = "新版图片笔记"
        upgrade.fieldNames = ["正面"]
        upgrade.fields = [old.front]
        let report = try db.importAnki([upgrade], media: ["image.png": incoming])
        let name = "image-" + SHA1.hex(incoming) + ".png"
        let card = try XCTUnwrap(db.cards().first)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(report.upgraded, 1)
        XCTAssertEqual(card.front, old.front, "保留原卡的手工内容")
        XCTAssertEqual(card.fields, ["<img src=\"\(name)\">"])
        XCTAssertEqual(try db.media(named: "image.png"), original)
        XCTAssertEqual(try db.media(named: name), incoming)
    }

    func testAnkiRenamedMediaDoesNotOverwriteAnExistingGeneratedName() throws {
        let db = try AppDatabase(DatabaseQueue())
        let incoming = Data([2])
        let base = "image-" + SHA1.hex(incoming)
        try db.saveMedia(["image.png": Data([1]), base + ".png": Data([3])])
        let note = AnkiNote(front: #"<img src="image.png">"#, back: "", tags: [], deck: "新包", guid: "new", schedule: nil)
        try db.importAnki([note], media: ["image.png": incoming])
        XCTAssertEqual(try db.media(named: base + ".png"), Data([3]))
        XCTAssertEqual(try db.media(named: base + "-1.png"), incoming)
        XCTAssertEqual(try db.importAnki([note], media: ["image.png": incoming]).media, 0)
    }

    func testCompactKeepsCardMediaAfterDeletingOriginalHighlight() throws {
        let db = try AppDatabase(DatabaseQueue())
        let image = Data([1, 2, 3])
        try db.saveMedia(["liquid text.png": image, "field.png": image, "section.png": image, "audio.mp3": image, "orphan.png": image])
        let highlight = try db.save(Highlight(text: "![图片](kr-media://media/liquid%20text.png)"))
        try db.makeCards(fromHighlights: [highlight.id!])
        var card = try XCTUnwrap(db.cards().first)
        card.fields = [#"<img src="field.png">"#]
        card.sections = [CardSection(name: "图片", text: "![图](section.png)")]
        card.back = "[sound:audio.mp3]"
        try db.save(card)
        try db.deletePermanently(highlight)

        XCTAssertEqual(try db.compact().mediaRemoved, 1)
        for name in ["liquid text.png", "field.png", "section.png", "audio.mp3"] {
            XCTAssertEqual(try db.media(named: name), image, name)
        }
        XCTAssertNil(try db.media(named: "orphan.png"))
    }

    func testRenameDeckMigratesOptionsAndKeepsExistingTargetOptions() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(Card(deck: "旧牌组", front: "问题"))
        let original = DeckOptions(deck: "旧牌组", newPerDay: 8, reviewsPerDay: 42, algorithm: .fsrs, desiredRetention: 0.87)
        try db.save(original)
        try db.renameDeck("旧牌组", to: "新牌组")
        var expected = original
        expected.deck = "新牌组"
        XCTAssertEqual(try db.deckOptions()["新牌组"], expected)
        XCTAssertNil(try db.deckOptions()["旧牌组"])
        XCTAssertEqual(try db.cards().first?.deck, "新牌组")

        let target = DeckOptions(deck: "目标牌组", newPerDay: 30, reviewsPerDay: 900, algorithm: .sm2, desiredRetention: 0.95)
        try db.save(target)
        try db.renameDeck("新牌组", to: "目标牌组")
        XCTAssertEqual(try db.deckOptions()["目标牌组"], target)
        XCTAssertNil(try db.deckOptions()["新牌组"])
        try db.renameDeck("目标牌组", to: "目标牌组")
        XCTAssertEqual(try db.deckOptions()["目标牌组"], target)
    }

    func testRenameDeckRollsBackCardsIfOptionsMigrationFails() throws {
        let queue = try DatabaseQueue()
        let db = try AppDatabase(queue)
        try db.save(Card(deck: "旧", front: "问题"))
        try db.save(DeckOptions(deck: "旧", newPerDay: 8))
        try queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_options BEFORE INSERT ON deck_options
                WHEN NEW.deck = '新' BEGIN SELECT RAISE(ABORT, '测试失败'); END;
                """)
        }
        XCTAssertThrowsError(try db.renameDeck("旧", to: "新"))
        XCTAssertEqual(try db.cards().first?.deck, "旧")
        XCTAssertNotNil(try db.deckOptions()["旧"])
        XCTAssertNil(try db.deckOptions()["新"])
    }

    func testDuplicateCardsCompareBothFacesAcrossDecksAndIgnoreSelfAndDeleted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let existing = try db.save(Card(deck: "甲", front: " café \n", back: "答案\t"))
        let duplicate = Card(deck: "乙", front: "\u{00A0}cafe\u{0301}\t", back: "\n答案 ")
        XCTAssertEqual(try db.duplicateCard(for: duplicate)?.id, existing.id)
        XCTAssertNil(try db.duplicateCard(for: existing))
        XCTAssertNil(try db.duplicateCard(for: Card(front: "café", back: "另一答案")))
        XCTAssertNil(try db.duplicateCard(for: Card(front: "另一问题", back: "答案")))
        try db.save(Card(front: "已删除", back: "答案", deletedAt: Date()))
        XCTAssertNil(try db.duplicateCard(for: Card(front: "已删除", back: "答案")))
    }
}
