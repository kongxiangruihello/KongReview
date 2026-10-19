import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V310CardAppendUndoTests: XCTestCase {
    private func saved(_ card: Card, in db: AppDatabase) throws -> Card {
        let result = try db.save(card)
        return try XCTUnwrap(db.card(id:try XCTUnwrap(result.id)))
    }

    private func preview(_ incoming: Card, _ existing: Card,
                         source: CardAppendLocation = .back, target: CardAppendLocation = .back,
                         template: NoteTemplate? = nil) throws -> CardAnswerAppendPreview {
        try CardAnswerAppendComposer.preview(from:incoming,to:existing,incomingTemplate:nil,existingTemplate:template,
            selection:.init(sourceIDs:[source],target:target))
    }

    func testAppendProducesPersistedSnapshotsAndUndoIsSingleUse() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充答案"),original))
        XCTAssertEqual(token.before,original)
        XCTAssertEqual(token.after,try db.card(id:original.id!))
        let restored = try db.undoCardAppend(token)
        XCTAssertTrue(CardContentVersion.sameContent(original,restored))
        XCTAssertEqual(restored,try db.card(id:original.id!))
        XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.expired) }
        XCTAssertEqual(try db.card(id:original.id!),restored)
        XCTAssertEqual(try db.cardContentHistory(id:original.id!).first?.card.back,"原答案")
    }

    func testUndoPreservesLaterRatingAndOrganizationMetadata() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(deck:"原牌组",front:"问题",back:"原答案",tags:["旧标签"],state:.review,interval:10,reps:8),in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充答案"),original))
        let rated = try db.answerRecordingUndo(token.after,.easy,now:Date(timeIntervalSince1970:1_800_000_000)).after
        var moved = rated
        moved.deck = "新牌组"; moved.tags = ["新标签"]; moved.isSuspended = true; moved.ankiGuid = "最新 GUID"
        let latest = try saved(moved,in:db)
        let restored = try db.undoCardAppend(token)
        var expected = latest
        expected.front = original.front; expected.back = original.back
        expected.fields = original.fields; expected.sections = original.sections; expected.noteType = original.noteType
        expected.updatedAt = restored.updatedAt
        XCTAssertEqual(restored,expected)
        let reviewCount = try db.writer.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM review_event WHERE cardId=?",arguments:[original.id!]) }
        XCTAssertEqual(reviewCount,1,"Undoing append must retain later learning events")
    }

    func testUndoRestoresCustomSectionsIncludingNamesOrderAndFolding() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = Card(front:"问题",back:"原背面")
        card.sections = [.init(id:"a",name:"释义",text:"旧释义",folded:true),.init(id:"b",name:"出处",text:"原出处")]
        let original = try saved(card,in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充释义"),original,target:.section("a")))
        XCTAssertTrue(token.after.sections![0].text.contains("补充释义"))
        let restored = try db.undoCardAppend(token)
        XCTAssertEqual(restored.sections,original.sections)
        XCTAssertEqual(restored.back,original.back)
    }

    func testUndoTemplateFieldZeroRestoresCachesWithoutChangingQuestion() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name:"逆序字段",fieldNames:["答案","题目"],front:[1],back:[0])
        try db.save(template)
        var card = Card(front:"旧答案",back:"问题")
        card.noteType = template.name; card.fields = ["旧答案","问题"]
        let original = try saved(card,in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充答案"),original,target:.field(0),template:template))
        XCTAssertNotEqual(token.after.front,original.front)
        let restored = try db.undoCardAppend(token)
        XCTAssertEqual(restored.fields,original.fields)
        XCTAssertEqual(restored.front,original.front)
        XCTAssertEqual(restored.back,original.back)
        XCTAssertEqual(restored.faces(using:template).front,original.faces(using:template).front)
    }

    func testChangedContentAndChangedThenRestoredContentAreBothRejected() throws {
        for returnToAppendContent in [false,true] {
            let db = try AppDatabase(DatabaseQueue())
            let original = try saved(Card(front:"问题",back:"原答案"),in:db)
            let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充答案"),original))
            var edited = token.after; edited.back += "另外的编辑"
            _ = try saved(edited,in:db)
            if returnToAppendContent { _ = try saved(token.after,in:db) }
            let latest = try db.card(id:original.id!)
            let versions = try db.cardContentHistory(id:original.id!)
            XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.contentChanged) }
            XCTAssertEqual(try db.card(id:original.id!),latest)
            XCTAssertEqual(try db.cardContentHistory(id:original.id!).map(\.id),versions.map(\.id))
        }
    }

    func testTemplateChangeIsRejectedWithoutOverwritingFields() throws {
        let db = try AppDatabase(DatabaseQueue())
        var template = NoteTemplate(name:"字段",fieldNames:["题目","答案"],front:[0],back:[1])
        try db.save(template)
        var card = Card(front:"问题",back:"答案"); card.noteType = template.name; card.fields = ["问题","答案"]
        let original = try saved(card,in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充"),original,target:.field(1),template:template))
        template.collapsed = [1]; try db.save(template)
        XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.templateChanged) }
        XCTAssertEqual(try db.card(id:original.id!),token.after)
    }

    func testDeletedOrMissingCardIsNeverRecreated() throws {
        for permanent in [false,true] {
            let db = try AppDatabase(DatabaseQueue())
            let original = try saved(Card(front:"问题",back:"答案"),in:db)
            let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充"),original))
            if permanent { try db.deleteCards([original.id!]) }
            else { var trashed = token.after; trashed.deletedAt = Date(); _ = try saved(trashed,in:db) }
            let latest = try db.card(id:original.id!)
            XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.cardUnavailable) }
            XCTAssertEqual(try db.card(id:original.id!),latest)
        }
    }

    func testLaterAppendReplacesReceiptEvenForAnotherCardAndCompatibilityAPI() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saved(Card(front:"问题一",back:"答案一"),in:db)
        let second = try saved(Card(front:"问题二",back:"答案二"),in:db)
        let firstToken = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题一",back:"补充一"),first))
        let secondToken = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题二",back:"补充二"),second))
        XCTAssertThrowsError(try db.undoCardAppend(firstToken)) { XCTAssertEqual($0 as? CardAppendUndoError,.expired) }
        XCTAssertTrue(CardContentVersion.sameContent(try db.undoCardAppend(secondToken),second))
        let latest = try XCTUnwrap(db.card(id:first.id!))
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题一",back:"补充三"),latest))
        _ = try db.appendCardAnswer(preview(Card(front:"问题二",back:"兼容入口追加"),try XCTUnwrap(db.card(id:second.id!))))
        XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.expired) }
    }

    func testUndoChecksVisibleFrontDuplicatesForTemplateAnswerAtFieldZero() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name:"逆序字段",fieldNames:["答案","题目"],front:[1],back:[0])
        try db.save(template)
        var card = Card(front:"旧答案",back:"问题"); card.noteType = template.name; card.fields = ["旧答案","问题"]
        let original = try saved(card,in:db)
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充答案"),original,target:.field(0),template:template))
        _ = try saved(Card(front:"问题",back:"后来导入的重复卡"),in:db)
        XCTAssertThrowsError(try db.undoCardAppend(token)) { XCTAssertEqual($0 as? CardAppendUndoError,.duplicateFront) }
        XCTAssertEqual(try db.card(id:original.id!),token.after)
    }

    func testUndoRecordsContentCareAndTopicHistoryTogether() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let notebook = try db.createNotebook(title:"专题")
        let highlight = try db.save(Highlight(text:"摘录"))
        _ = try db.insertBlocks([.init(notebookId:notebook.id!,position:1,kind:.highlight,highlightId:highlight.id)],into:notebook.id!,after:nil)
        let original = try saved(Card(front:"问题",back:"答案",highlightId:highlight.id),in:db)
        _ = try db.saveCare(cardID:original.id!,reason:.context,note:"需要背景")
        let token = try db.appendCardAnswerRecordingUndo(preview(Card(front:"问题",back:"补充"),original))
        _ = try db.undoCardAppend(token)
        let versions = try db.cardContentHistory(id:original.id!)
        XCTAssertEqual(versions.count,3)
        XCTAssertEqual(versions.first?.card.back,"答案")
        let care = try await db.careAdjustments(cardID:original.id!)
        XCTAssertEqual(care.total,2)
        let timeline = try await db.topicTimeline(notebookID:notebook.id!)
        XCTAssertEqual(timeline.items.filter { $0.kind == "修改记忆卡" }.count,2)
    }

    @MainActor func testStoreReplacesTokenPreservesOpenDraftAndBlocksDuringBackup() throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try saved(Card(front:"问题一",back:"答案一"),in:db)
        let second = try saved(Card(front:"问题二",back:"答案二"),in:db)
        let store = LibraryStore(db:db)
        store.newCard(deck:"正在输入")
        store.cardEditor?.card.front = "未保存的题目"; store.cardEditor?.card.back = "未保存的答案"
        let draft = try XCTUnwrap(store.cardEditor)
        let firstPlan = try preview(Card(front:"问题一",back:"补充一"),first)
        let secondPlan = try preview(Card(front:"问题二",back:"补充二"),second)
        _ = try store.appendCardAnswerWithUndo(firstPlan)
        let firstID = store.cardAppendUndo.token?.id
        store.fullBackupBusy = true
        XCTAssertThrowsError(try store.appendCardAnswerWithUndo(secondPlan)) { XCTAssertEqual($0 as? CardAppendUndoError,.backupBusy) }
        XCTAssertEqual(store.cardAppendUndo.token?.id,firstID)
        XCTAssertFalse(store.undoLastCardAppend())
        XCTAssertTrue(store.cardAppendUndo.message?.contains("备份") == true)
        store.fullBackupBusy = false
        _ = try store.appendCardAnswerWithUndo(secondPlan)
        XCTAssertNotEqual(store.cardAppendUndo.token?.id,firstID)
        XCTAssertTrue(store.undoLastCardAppend())
        XCTAssertFalse(store.undoLastCardAppend())
        XCTAssertEqual(store.cardEditor?.id,draft.id)
        XCTAssertEqual(store.cardEditor?.card,draft.card)
        XCTAssertTrue(CardContentVersion.sameContent(try XCTUnwrap(db.card(id:second.id!)),second))
        XCTAssertTrue(try XCTUnwrap(db.card(id:first.id!)).back.contains("补充一"))
        store.cardAppendUndo.clear()
        XCTAssertNil(store.cardAppendUndo.token); XCTAssertNil(store.cardAppendUndo.message)
    }

    @MainActor func testStoreRefusesUndoWhileOriginalCardEditorIsOpenWithoutLosingInputOrToken() throws {
        let db = try AppDatabase(DatabaseQueue())
        let original = try saved(Card(front:"问题",back:"原答案"),in:db)
        let store = LibraryStore(db:db)
        let appended = try store.appendCardAnswerWithUndo(preview(Card(front:"问题",back:"补充答案"),original))
        let tokenID = try XCTUnwrap(store.cardAppendUndo.token?.id)
        store.editCard(appended)
        store.cardEditor?.card.back += "尚未保存的修改"
        let input = try XCTUnwrap(store.cardEditor)
        XCTAssertFalse(store.undoLastCardAppend())
        XCTAssertEqual(store.cardAppendUndo.token?.id,tokenID)
        XCTAssertTrue(store.cardAppendUndo.message?.contains("正在编辑") == true)
        XCTAssertEqual(store.cardEditor?.id,input.id)
        XCTAssertEqual(store.cardEditor?.card,input.card)
        XCTAssertEqual(try db.card(id:original.id!),appended)
        store.cardEditor = nil
        XCTAssertTrue(store.undoLastCardAppend())
        XCTAssertEqual(try db.card(id:original.id!)?.back,"原答案")
    }
}
