import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V39CardPreviewTests: XCTestCase {
    func testPreviewUsesUnsavedAnswersSectionsAndMediaWithoutChangingSavedCard() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(deck:"原牌组",front:"问题",back:"已保存答案",state:.review,interval:20,reps:9))
        let saved = try XCTUnwrap(db.card(id:inserted.id!))
        let store = LibraryStore(db:db)
        store.editCard(saved)
        store.cardEditor?.card.back = "<p>未保存答案</p><img src=\"krmedia://sample.png\">"
        store.cardEditor?.card.sections = [.init(name:"例句",text:"折叠的例句",folded:true)]
        let draft = try XCTUnwrap(store.cardEditor)
        let snapshot = CardEditorPreviewSnapshot(draft:draft,templates:store.noteTemplates)
        XCTAssertEqual(snapshot.draftID,draft.id)
        XCTAssertEqual(snapshot.front,"问题")
        XCTAssertTrue(snapshot.back.contains("未保存答案"))
        XCTAssertTrue(snapshot.back.contains("<details"))
        XCTAssertTrue(snapshot.back.contains("sample.png"))
        XCTAssertTrue(CardWebView.page(front:snapshot.front,back:nil).contains("问题"))
        XCTAssertFalse(CardWebView.page(front:snapshot.front,back:nil).contains("未保存答案"))
        XCTAssertTrue(CardWebView.page(front:snapshot.front,back:snapshot.back).contains("未保存答案"))
        XCTAssertEqual(try db.card(id:saved.id!),saved)
        XCTAssertEqual(store.cardEditor?.card,draft.card)
        XCTAssertEqual(store.cardWorkflow.addedCount,0)
    }

    func testPreviewUsesActualTemplateFrontAndCollapsedBackAndFreezesSnapshot() {
        let template = NoteTemplate(name:"多字段",fieldNames:["备注","问题","解释"],front:[1],back:[2,0],collapsed:[0])
        var card = Card(front:"旧缓存",back:"旧缓存背面")
        card.noteType = template.name
        card.fields = ["折叠备注","<b>真正题面</b>","<a href=\"https://example.com\">解释链接</a>"]
        var draft = CardDraft(card:card)
        let snapshot = CardEditorPreviewSnapshot(draft:draft,templates:[template.name:template])
        let expected = card.faces(using:template)
        XCTAssertEqual(snapshot.front,expected.front)
        XCTAssertEqual(snapshot.back,expected.back)
        XCTAssertTrue(snapshot.front.contains("真正题面"))
        XCTAssertFalse(snapshot.front.contains("旧缓存"))
        XCTAssertTrue(snapshot.back.contains("<details"))
        XCTAssertTrue(snapshot.back.contains("https://example.com"))
        draft.card.fields[1] = "后来的输入"
        XCTAssertFalse(snapshot.front.contains("后来的输入"))
    }

    func testReturningSameDraftIDDoesNotReactivateOldFieldCallbacks() throws {
        let store = LibraryStore(db:try AppDatabase(DatabaseQueue()))
        store.newCard(deck:nil)
        store.cardEditor?.card.front = "原来输入"
        let retained = try XCTUnwrap(store.cardEditor)
        let old = CardEditorSessionBindings.value(store,\.card.front,fallback:"")
        store.cardEditor = CardDraft(card:Card(front:"另一份草稿"))
        store.cardEditor = retained
        old.wrappedValue = "迟到的旧输入"
        XCTAssertEqual(store.cardEditor?.card.front,"原来输入")
        XCTAssertEqual(old.wrappedValue,"")
        let fresh = CardEditorSessionBindings.value(store,\.card.front,fallback:"")
        fresh.wrappedValue = "返回后的正常输入"
        XCTAssertEqual(store.cardEditor?.card.front,"返回后的正常输入")
    }
}
