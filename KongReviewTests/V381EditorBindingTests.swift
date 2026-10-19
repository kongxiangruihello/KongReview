import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V381EditorBindingTests: XCTestCase {
    func testLateCallbacksFromOldEditorCannotChangeOriginalCard() throws {
        let store = LibraryStore(db:try AppDatabase(DatabaseQueue()))
        store.newCard(deck:"输入牌组")
        store.cardEditor?.card.front = "输入题面"
        store.cardEditor?.card.fields = ["旧字段"]
        store.cardEditor?.card.sections = [.init(id:"shared",name:"旧栏目",text:"旧内容")]
        let front = CardEditorSessionBindings.value(store,\.card.front,fallback:"")
        let tags = CardEditorSessionBindings.value(store,\.tagsText,fallback:"")
        let field = CardEditorSessionBindings.field(store,index:0)
        let section = CardEditorSessionBindings.section(store,id:"shared",keyPath:\.text,fallback:"")
        var original = Card(deck:"原牌组",front:"原题面",back:"原答案",tags:["保留"])
        original.fields = ["原字段"];original.sections = [.init(id:"shared",name:"原栏目",text:"原内容")]
        store.cardEditor = CardDraft(card:original,tagsText:"保留")
        let current = try XCTUnwrap(store.cardEditor)
        front.wrappedValue = "迟到正面";tags.wrappedValue = "迟到标签";field.wrappedValue = "迟到字段";section.wrappedValue = "迟到栏目"
        XCTAssertEqual(store.cardEditor?.card,current.card);XCTAssertEqual(store.cardEditor?.tagsText,current.tagsText)
        XCTAssertEqual(front.wrappedValue,"")
        let fresh = CardEditorSessionBindings.value(store,\.card.back,fallback:"")
        fresh.wrappedValue = "正常新输入";XCTAssertEqual(store.cardEditor?.card.back,"正常新输入")
    }
    func testBindingsContinueWithinSessionAndIgnoreRemovedFields() throws {
        let store = LibraryStore(db:try AppDatabase(DatabaseQueue()))
        store.newCard(deck:nil);store.cardEditor?.card.fields = ["字段一"]
        let front = CardEditorSessionBindings.value(store,\.card.front,fallback:"")
        let field = CardEditorSessionBindings.field(store,index:0)
        front.wrappedValue = "第一笔";front.wrappedValue = "第二笔";field.wrappedValue = "字段新值"
        XCTAssertEqual(store.cardEditor?.card.front,"第二笔");XCTAssertEqual(store.cardEditor?.card.fields,["字段新值"])
        store.cardEditor?.card.fields = []
        field.wrappedValue = "迟到字段";XCTAssertEqual(store.cardEditor?.card.fields,[])
        store.cardEditor = nil;front.wrappedValue = "关闭后的回调";XCTAssertNil(store.cardEditor)
    }
}
