import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V354CardInputDuplicateTests: XCTestCase {
    func testFrontOnlyCaseWidthWhitespaceAndFormattingAcrossDecks() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try db.save(Card(deck:"甲",front:"<p><strong>Ａ Book</strong></p>",back:"旧答案"))
        for front in [" a book ", "A\t BOOK\n", "<div>a&nbsp;<em>book</em></div>", "**a book**", "<p>&#65;&#32;Book</p>"] {
            XCTAssertEqual(try db.duplicateCard(for:Card(deck:"乙",front:front,back:"不同答案"))?.id,first.id)
        }
        for front in ["abook","a book!","一本書","一本书"] {
            XCTAssertNil(try db.duplicateCard(for:Card(front:front)))
        }
        XCTAssertNil(try db.duplicateCard(for:first))
        var edited = first; edited.back = "新答案"
        XCTAssertEqual(try db.saveInputCards([edited]).first?.back,"新答案")
    }
    func testMediaIdentityUsesBytesAndDoesNotTreatEmptyFrontsAsDuplicates() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.writer.write { sql in
            for (name,bytes) in [("a.png",Data([1,2])),("alias.png",Data([1,2])),("b.png",Data([3])),("voice.mp3",Data([4]))] {
                try sql.execute(sql:"INSERT INTO card_media(name,data) VALUES (?,?)",arguments:[name,bytes])
            }
        }
        let first = try db.save(Card(front:"<img src='a.png'>"))
        XCTAssertEqual(try db.duplicateCard(for:Card(front:"<img width='100' src=\"kr-media://media/alias.png\">"))?.id,first.id)
        XCTAssertNil(try db.duplicateCard(for:Card(front:"<img src='b.png'>")))
        XCTAssertNil(try db.duplicateCard(for:Card(front:"<p><br></p>")))
        let sound = try db.save(Card(front:"[sound:voice.mp3]"))
        XCTAssertEqual(try db.duplicateCard(for:Card(front:"<audio src='voice.mp3'></audio>"))?.id,sound.id)
        XCTAssertNil(try db.duplicateCard(for:Card(front:"[sound:other.mp3]")))
    }
    func testDeletedPromptCanBeBypassedAndRestoreKeepsLearningState() throws {
        let db = try AppDatabase(DatabaseQueue())
        let deleted = try db.save(Card(deck:"旧牌组",front:"Hello",state:.review,interval:30,reps:12,deletedAt:Date()))
        let new = Card(front:" hello ",back:"新答案")
        XCTAssertThrowsError(try db.saveInputCards([new])) { error in
            guard case CardInputDuplicateError.deleted(let card) = error else { return XCTFail("Expected trash choice") }
            XCTAssertEqual(card.id,deleted.id)
        }
        XCTAssertEqual(try db.cardCount(),0)
        try db.restoreInputDuplicate(id:deleted.id!)
        let restored = try XCTUnwrap(db.card(id:deleted.id!))
        XCTAssertNil(restored.deletedAt); XCTAssertEqual(restored.reps,12); XCTAssertEqual(restored.interval,30)
        XCTAssertThrowsError(try db.saveInputCards([new],allowDeleted:true),"Trash bypass cannot bypass an active duplicate")
        var again = restored; again.deletedAt = Date(); _ = try db.save(again)
        _ = try db.saveInputCards([new],allowDeleted:true)
        XCTAssertEqual(try db.cardCount(),1)
        XCTAssertThrowsError(try db.restoreInputDuplicate(id:deleted.id!))
    }
    func testClozePositionsRemainSeparateAndBatchFailureIsAtomic() throws {
        let db = try AppDatabase(DatabaseQueue())
        let text = "{{c1::甲}}与{{c2::乙}}"
        let cards = [1,2].map { n in let c = AnkiContent.cloze(text,number:n); return Card(front:c.front,back:c.back) }
        _ = try db.saveInputCards(cards)
        XCTAssertEqual(try db.cardCount(),2)
        XCTAssertThrowsError(try db.saveInputCards([Card(front:"新的题目"),cards[0]]))
        XCTAssertEqual(try db.cardCount(),2)
        XCTAssertThrowsError(try db.saveInputCards([Card(front:"批内"),Card(front:" 批内 ")]))
        XCTAssertEqual(try db.cardCount(),2)
    }
    func testTemplateUsesActuallyDisplayedFront() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(NoteTemplate(name:"多字段",fieldNames:["缓存","问题","答案"],front:[1],back:[2]))
        var first = Card(front:"缓存甲"); first.noteType = "多字段"; first.fields = ["缓存甲","Actual Question","答案甲"]
        let saved = try db.save(first)
        var second = first; second.front = "缓存乙"; second.fields = ["缓存乙"," actual QUESTION ","答案乙"]
        XCTAssertEqual(try db.duplicateCard(for:second)?.id,saved.id)
        second.fields[1] = "Another question"
        XCTAssertNil(try db.duplicateCard(for:second))
    }
    @MainActor func testEditorKeepsDraftAndExposesDuplicateCard() throws {
        let db = try AppDatabase(DatabaseQueue())
        let existing = try db.save(Card(deck:"原牌组",front:"QUESTION",back:"原答案"))
        let store = LibraryStore(db:db)
        store.newCard(deck:"新牌组"); store.cardEditor?.card.front = " question "; store.cardEditor?.card.back = "输入保留"
        store.commitCardEditor()
        XCTAssertEqual(store.cardEditor?.duplicate?.id,existing.id)
        XCTAssertEqual(store.cardEditor?.card.back,"输入保留")
        XCTAssertEqual(try db.cardCount(),1)
    }
}
