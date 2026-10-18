import XCTest
import AppKit
import GRDB
import KongReviewCore
@testable import KongReview

final class V360EditingTests: XCTestCase {
    @MainActor func testNativeChineseCompositionCommitsWithoutLosingText() {
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:400,height:120))
        view.isRichText = false; view.isEditable = true
        view.string = "<p>"
        view.setSelectedRange(NSRange(location:3,length:0))
        view.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("中文",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        view.unmarkText()
        view.insertText("。</p>",replacementRange:view.selectedRange())
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string,"<p>中文。</p>")
    }
    func testHTMLDiagnosticsOffersBoundedRepairAndPreservesValidMarkup() {
        let bad = #"<a href="gemini.google.com>gemini</>"#
        let result = HTMLDiagnostics.inspect(bad)
        XCTAssertTrue(result.issues.contains { $0.contains("引号") })
        XCTAssertEqual(result.proposed,#"<a href="https://gemini.google.com">gemini</a>"#)
        XCTAssertTrue(HTMLDiagnostics.inspect(result.proposed).issues.isEmpty)
        for valid in [#"<p><strong>文字</strong><br><img src="a.png"></p>"#, #"<a href="https://example.com/?q=a>b">链接</a>"#, "<!-- <b> --> <p>正文</p>"] {
            let report = HTMLDiagnostics.inspect(valid)
            XCTAssertTrue(report.issues.isEmpty,report.issues.joined())
            XCTAssertEqual(report.proposed,valid)
        }
        XCTAssertEqual(HTMLDiagnostics.inspect("<p><em>文字").proposed,"<p><em>文字</em></p>")
        let mismatched = "<p><em>文字</p>"
        XCTAssertFalse(HTMLDiagnostics.inspect(mismatched).issues.isEmpty)
        XCTAssertEqual(HTMLDiagnostics.inspect(mismatched).proposed,mismatched)
    }
    func testLiveDuplicateFindsActiveBeforeTrashAndExcludesCurrentCard() async throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.save(Card(front:"hello",deletedAt:Date()))
        let live = try db.save(Card(deck:"正式",front:"HELLO"))
        let found = try await db.liveCardDuplicate(Card(front:" Hello "))
        XCTAssertEqual(found?.id,live.id)
        let own = try await db.liveCardDuplicate(live)
        XCTAssertNotNil(own?.deletedAt)
        let empty = try await db.liveCardDuplicate(Card(front:"<p><br></p>"))
        XCTAssertNil(empty)
    }
    func testHistoryRecordsContentOnlyAndRestoresWithoutSchedulingChanges() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try db.save(Card(deck:"牌组",front:"问题",back:"答案一",state:.review,interval:30,reps:8))
        card = try XCTUnwrap(db.card(id:card.id!))
        card.back = "答案二"; card = try db.saveInputCards([card])[0]
        let history = try db.cardContentHistory(id:card.id!)
        XCTAssertEqual(history.map(\.card.back),["答案二","答案一"])
        card.reps = 20; card.interval = 80; card.deck = "新牌组"; card.tags = ["保留标签"]
        _ = try db.save(card)
        XCTAssertEqual(try db.cardContentHistory(id:card.id!).count,2)
        let restored = history.last!.applying(to:card)
        XCTAssertEqual(restored.back,"答案一"); XCTAssertEqual(restored.reps,20)
        XCTAssertEqual(restored.interval,80); XCTAssertEqual(restored.deck,"新牌组"); XCTAssertEqual(restored.tags,["保留标签"])
        _ = try db.saveInputCards([restored])
        XCTAssertEqual(try db.cardContentHistory(id:card.id!).first?.card.back,"答案一")
    }
    func testAppendIsExplicitAtomicAndRejectsStaleSnapshot() throws {
        let db = try AppDatabase(DatabaseQueue())
        let inserted = try db.save(Card(deck:"原牌组",front:"问题",back:"原答案",state:.review,reps:7))
        let old = try XCTUnwrap(db.card(id:inserted.id!))
        let incoming = Card(deck:"新牌组",front:"问题",back:"新答案")
        let saved = try db.appendCardAnswer(from:incoming,to:old)
        XCTAssertTrue(saved.back.contains("原答案")); XCTAssertTrue(saved.back.contains("新答案"))
        XCTAssertEqual(saved.reps,7); XCTAssertEqual(saved.deck,"原牌组")
        XCTAssertEqual(try db.cardCount(),1)
        XCTAssertThrowsError(try db.appendCardAnswer(from:incoming,to:old))
        XCTAssertEqual(try db.cardContentHistory(id:old.id!).count,2)
        let fresh = try XCTUnwrap(db.card(id:old.id!))
        XCTAssertThrowsError(try db.appendCardAnswer(from:Card(front:"问题",back:"<p><br></p>"),to:fresh))
        XCTAssertEqual(try db.card(id:old.id!)?.back,fresh.back)
    }
    func testAppendToTemplateDoesNotAlterFrontFields() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.save(NoteTemplate(name:"字段模板",fieldNames:["问题","解释"],front:[0],back:[1]))
        var card = Card(front:"正面",back:"解释"); card.noteType = "字段模板"; card.fields = ["正面","解释"]
        card = try db.save(card); card = try XCTUnwrap(db.card(id:card.id!))
        let saved = try db.appendCardAnswer(from:Card(front:"正面",back:"补充解释"),to:card)
        XCTAssertEqual(saved.fields[0],"正面"); XCTAssertTrue(saved.fields[1].contains("补充解释"))
    }
}
