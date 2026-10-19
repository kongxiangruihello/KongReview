import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V39AppendSelectionTests: XCTestCase {
    private func saved(_ card: Card, in db: AppDatabase) throws -> Card {
        let inserted = try db.save(card)
        return try XCTUnwrap(db.card(id:try XCTUnwrap(inserted.id)))
    }
    private func preview(_ incoming: Card, _ existing: Card,
                         sources: Set<CardAppendLocation> = [.back], target: CardAppendLocation = .back,
                         incomingTemplate: NoteTemplate? = nil, existingTemplate: NoteTemplate? = nil) throws -> CardAnswerAppendPreview {
        try CardAnswerAppendComposer.preview(from:incoming,to:existing,
            incomingTemplate:incomingTemplate,existingTemplate:existingTemplate,
            selection:.init(sourceIDs:sources,target:target))
    }

    func testSelectOnlyOneSectionAndAppendIntoExistingSection() throws {
        let db = try AppDatabase(DatabaseQueue())
        var original = Card(deck:"保留牌组",front:"问题",back:"保留背面",tags:["保留标签"],state:.review,interval:30,reps:9,lapses:2)
        original.sections = [.init(id:"definition",name:"释义",text:"原释义",folded:true),.init(id:"example",name:"例句",text:"原例句")]
        original.stability = 12; original.difficulty = 4; original.lastReview = Date(timeIntervalSince1970:100)
        original = try saved(original,in:db)
        var incoming = Card(deck:"不采用牌组",front:"问题",back:"不选择的答案",tags:["不采用标签"])
        incoming.sections = [.init(id:"new-note",name:"注释",text:"本次补充"),.init(id:"empty",name:"空栏目")]
        let plan = try preview(incoming,original,sources:[.section("new-note")],target:.section("definition"))
        XCTAssertEqual(CardAnswerAppendComposer.sources(for:incoming,template:nil).map(\.id),[.back,.section("new-note")])
        XCTAssertTrue(plan.result.sections![0].text.contains("本次补充"))
        XCTAssertFalse(plan.result.sections![0].text.contains("不选择的答案"))
        XCTAssertEqual(plan.result.sections![1],original.sections![1])
        XCTAssertTrue(plan.result.sections![0].folded)
        XCTAssertEqual(plan.result.back,original.back)
        let result = try db.appendCardAnswer(plan)
        var expected = original; expected.sections = plan.result.sections; expected.updatedAt = result.updatedAt
        XCTAssertEqual(result,expected)
        XCTAssertEqual(try db.cardCount(),1)
    }

    func testMultipleSelectedBlocksHaveDeterministicOrderAndExactPreview() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        var incoming = Card(front:"问题",back:"第一块")
        incoming.sections = [.init(id:"a",name:"释义",text:"第二块"),.init(id:"b",name:"例句",text:"第三块")]
        let plan = try preview(incoming,original,sources:[.section("b"),.back,.section("a")])
        let html = plan.result.back
        XCTAssertLessThan(try XCTUnwrap(html.range(of:"第一块")?.lowerBound),try XCTUnwrap(html.range(of:"第二块")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(html.range(of:"第二块")?.lowerBound),try XCTUnwrap(html.range(of:"第三块")?.lowerBound))
        let result = try db.appendCardAnswer(plan)
        var expected = plan.result; expected.updatedAt = result.updatedAt
        XCTAssertEqual(result,expected)
        let persisted = try XCTUnwrap(db.card(id:original.id!))
        expected.updatedAt = persisted.updatedAt
        XCTAssertEqual(persisted,expected)
    }

    func testTemplateChoicesNeverIncludeFrontOrSharedFields() throws {
        let template = NoteTemplate(name:"多字段",fieldNames:["题目","共享题干","解释","备注"],front:[0,1],back:[1,2,3,2])
        var card = Card(front:"题目缓存",back:"背面缓存")
        card.noteType = template.name; card.fields = ["问题","题干","解释内容",""]
        XCTAssertEqual(CardAnswerAppendComposer.sources(for:card,template:template).map(\.id),[.field(2)])
        XCTAssertEqual(CardAnswerAppendComposer.destinations(for:card,template:template).map(\.id),[.field(2),.field(3)])
        XCTAssertTrue(CardAnswerAppendComposer.sources(for:card,template:nil).isEmpty)
        XCTAssertThrowsError(try preview(card,card,sources:[.field(1)],target:.field(2),incomingTemplate:template,existingTemplate:template))
        XCTAssertThrowsError(try preview(card,card,sources:[.field(2)],target:.field(1),incomingTemplate:template,existingTemplate:template))
    }

    func testTemplateAppendUpdatesChosenAnswerFieldOnlyAndPreservesQuestion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name:"字段模板",fieldNames:["题目","解释","备注"],front:[0],back:[1,2],collapsed:[2])
        try db.save(template)
        var original = Card(front:"问题",back:"解释<hr>备注",state:.review,reps:8)
        original.noteType = template.name; original.fields = ["问题","原解释","原备注"]
        original = try saved(original,in:db)
        var incoming = Card(front:"问题",back:"不采用的缓存")
        incoming.noteType = template.name; incoming.fields = ["问题","新解释","新备注"]
        let plan = try preview(incoming,original,sources:[.field(2)],target:.field(1),incomingTemplate:template,existingTemplate:template)
        let result = try db.appendCardAnswer(plan)
        XCTAssertEqual(result.front,original.front); XCTAssertEqual(result.fields[0],original.fields[0])
        XCTAssertEqual(result.fields[2],original.fields[2]); XCTAssertEqual(result.reps,original.reps)
        XCTAssertTrue(result.fields[1].contains("新备注")); XCTAssertFalse(result.fields[1].contains("新解释"))
        XCTAssertEqual(result.faces(using:template).back,plan.result.faces(using:template).back)
    }

    func testEmptyAndInvalidSelectionsAreRejected() throws {
        let incoming = Card(front:"问题",back:"答案"), original = Card(front:"问题",back:"原答案")
        XCTAssertThrowsError(try preview(incoming,original,sources:[])) { XCTAssertEqual($0 as? CardAnswerAppendError,.noSelection) }
        XCTAssertThrowsError(try preview(incoming,original,sources:[.section("missing")]))
        XCTAssertThrowsError(try preview(incoming,original,target:.section("missing")))
        XCTAssertThrowsError(try preview(Card(front:"问题",back:"<p><br></p>"),original))
        var noAnswerField = original; noAnswerField.noteType = "只有题面"; noAnswerField.fields = ["问题"]
        let template = NoteTemplate(name:"只有题面",fieldNames:["问题"],front:[0],back:[0])
        XCTAssertThrowsError(try preview(incoming,noAnswerField,existingTemplate:template))
    }

    func testTemplateAnswerAtFieldZeroUpdatesSearchCacheWithoutChangingActualQuestion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name:"逆序字段",fieldNames:["答案","题目"],front:[1],back:[0])
        try db.save(template)
        var original = Card(front:"原答案",back:"问题")
        original.noteType = template.name; original.fields = ["原答案","问题"]
        original = try saved(original,in:db)
        let question = original.faces(using:template).front
        let plan = try preview(Card(front:"问题",back:"补充答案"),original,target:.field(0),existingTemplate:template)
        let result = try db.appendCardAnswer(plan)
        XCTAssertEqual(result.faces(using:template).front,question)
        XCTAssertEqual(result.fields[1],original.fields[1])
        XCTAssertEqual(result.front,result.fields[0]); XCTAssertTrue(result.front.contains("补充答案"))
        XCTAssertEqual(result.back,original.back)
    }

    func testAlreadyPresentWholeHTMLFragmentIsBlockedWithoutWrites() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        let incoming = Card(front:"问题",back:"新的完整答案")
        _ = try db.appendCardAnswer(preview(incoming,original))
        let result = try XCTUnwrap(db.card(id:original.id!))
        let history = try db.cardContentHistory(id:original.id!)
        XCTAssertThrowsError(try preview(incoming,result)) { error in
            guard case .duplicateContent = error as? CardAnswerAppendError else { return XCTFail("Expected duplicate warning") }
        }
        XCTAssertEqual(try db.card(id:original.id!),result)
        XCTAssertEqual(try db.cardContentHistory(id:original.id!).count,history.count)
        XCTAssertThrowsError(try preview(Card(front:"问题",back:"<p>新的完整答案</p>"),result))
    }

    func testEqualBlocksInTheSameSelectionRequireDeselectingOne() throws {
        var incoming = Card(front:"问题",back:"相同答案")
        incoming.sections = [.init(id:"duplicate",name:"备注",text:"相同答案")]
        let original = Card(front:"问题",back:"原答案")
        XCTAssertThrowsError(try preview(incoming,original,sources:[.back,.section("duplicate")]))
        XCTAssertNoThrow(try preview(incoming,original,sources:[.section("duplicate")]))
    }

    func testMediaAndLinkDifferencesArePreservedInDuplicateComparison() throws {
        let original = Card(front:"问题",back:"<p><img src=\"first.png\"></p><p><a href=\"https://a.example\">说明</a></p>")
        XCTAssertNoThrow(try preview(Card(front:"问题",back:"<p><img src=\"second.png\"></p>"),original))
        XCTAssertNoThrow(try preview(Card(front:"问题",back:"<p><a href=\"https://b.example\">说明</a></p>"),original))
        XCTAssertThrowsError(try preview(Card(front:"问题",back:"<p><img src=\"first.png\"></p>"),original))
        XCTAssertNoThrow(try preview(Card(front:"问题",back:"[sound:answer.mp3]"),original))
    }

    func testTargetChangeDeletionAndFrontMismatchRejectAtomically() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        let plan = try preview(Card(front:"问题",back:"补充答案"),original)
        var changed = original; changed.deck = "移动后"; _ = try db.save(changed)
        XCTAssertThrowsError(try db.appendCardAnswer(plan))
        let latest = try XCTUnwrap(db.card(id:original.id!))
        XCTAssertThrowsError(try db.appendCardAnswer(preview(Card(front:"另一个问题",back:"补充答案"),latest)))
        let latestPlan = try preview(Card(front:"问题",back:"补充答案"),latest)
        var trashed = latest; trashed.deletedAt = Date(); _ = try db.save(trashed)
        let deletedSnapshot = try XCTUnwrap(db.card(id:original.id!))
        XCTAssertThrowsError(try db.appendCardAnswer(latestPlan))
        XCTAssertEqual(try db.card(id:original.id!),deletedSnapshot)
        XCTAssertEqual(deletedSnapshot.back,"原答案")
        XCTAssertTrue(try db.cardContentHistory(id:original.id!).isEmpty)
        try db.deleteCards([original.id!])
        XCTAssertNil(try db.card(id:original.id!))
        XCTAssertThrowsError(try db.appendCardAnswer(latestPlan))
        XCTAssertNil(try db.card(id:original.id!))
        XCTAssertTrue(try db.cardContentHistory(id:original.id!).isEmpty)
    }

    func testTemplateChangesAfterPreviewRejectEvenWhenCardSnapshotMatches() throws {
        let db = try AppDatabase(DatabaseQueue())
        var template = NoteTemplate(name:"字段模板",fieldNames:["问题","解释","备注"],front:[0],back:[1,2])
        try db.save(template)
        var original = Card(front:"问题"); original.noteType = template.name; original.fields = ["问题","旧解释","旧备注"]
        original = try saved(original,in:db)
        let plan = try preview(Card(front:"问题",back:"补充"),original,target:.field(2),existingTemplate:template)
        template.collapsed = [2]; try db.save(template)
        XCTAssertThrowsError(try db.appendCardAnswer(plan))
        XCTAssertEqual(try db.card(id:original.id!),original)
        XCTAssertTrue(try db.cardContentHistory(id:original.id!).isEmpty)
    }

    func testChangedPreviewResultIsNeverPersisted() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        let plan = try preview(Card(front:"问题",back:"补充"),original)
        var incorrect = plan.result; incorrect.front = "不能写入的问题"
        let altered = CardAnswerAppendPreview(incoming:plan.incoming,existing:plan.existing,
            incomingTemplate:nil,existingTemplate:nil,selection:plan.selection,result:incorrect)
        XCTAssertThrowsError(try db.appendCardAnswer(altered))
        XCTAssertEqual(try db.card(id:original.id!),original)
    }

    func testAppendRecordsContentAndCareHistoryTogether() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        _ = try db.saveCare(cardID:original.id!,reason:.context,note:"需要更多背景")
        let result = try db.appendCardAnswer(preview(Card(front:"问题",back:"补充背景"),original))
        let versions = try db.cardContentHistory(id:original.id!)
        XCTAssertEqual(versions.count,2); XCTAssertEqual(versions.first?.card.back,result.back)
        let changes = try await db.careAdjustments(cardID:original.id!)
        XCTAssertEqual(changes.total,1); XCTAssertEqual(changes.items.first?.before.back,original.back)
        XCTAssertEqual(changes.items.first?.after.back,result.back)
    }
}
