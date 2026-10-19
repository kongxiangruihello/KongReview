import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V312BulkOriginalEditingTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at:directory) }
        directories = []
    }
    private func fixture(persistence: Bool = true) throws -> (LibraryStore,Card,CardBulkEntryDraft,CardBulkEntryCandidate) {
        let db = try AppDatabase(DatabaseQueue())
        let card = try db.save(Card(deck:"原牌组",front:"Original Question",back:"原答案",tags:["保留标签"],state:.review,interval:20,reps:8))
        var draft = CardBulkEntryDraft()
        let candidate = CardBulkEntryCandidate(line:1,values:["<p> original QUESTION </p>","<p>候选答案</p>"])
        draft.source = "original QUESTION\t候选答案"
        draft.configuration = .init(deck:"目标牌组",mapping:[.front,.back])
        draft.candidates = [candidate];draft.selectedIDs = []
        try db.saveCardBulkEntryDraft(draft,expected:nil)
        let saved: EditorDraftPersistence?
        if persistence {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-V312-original-" + UUID().uuidString)
            directories.append(directory);saved = try EditorDraftPersistence(directory:directory)
        } else { saved = nil }
        return (LibraryStore(db:db,draftPersistence:saved,positionDefaults:nil),card,draft,candidate)
    }
    private func open(_ store: LibraryStore,_ card: Card,_ candidate: CardBulkEntryCandidate) {
        store.showsCardBulkEntry = true
        store.requestBulkOriginalEdit(candidateID:candidate.id,cardID:card.id!)
        XCTAssertFalse(store.showsCardBulkEntry)
        store.performPendingBulkOriginalEdit()
    }
    func testOriginalEditorReturnsToBatchAndPreservesUncommittedOriginalChanges() throws {
        let (store,card,bulk,candidate) = try fixture()
        open(store,card,candidate)
        XCTAssertTrue(store.canReturnToBulkEntry)
        XCTAssertEqual(store.cardEditor?.card.id,card.id)
        store.cardEditor?.card.back = "尚未保存的原卡修改"
        let editorID = try XCTUnwrap(store.cardEditor?.id)
        XCTAssertTrue(store.returnToBulkEntry())
        XCTAssertNil(store.cardEditor);XCTAssertTrue(store.showsCardBulkEntry)
        XCTAssertEqual(store.savedCardDrafts.first { $0.id == editorID }?.card.back,"尚未保存的原卡修改")
        XCTAssertEqual(try store.db.card(id:card.id!)?.back,"原答案")
        XCTAssertEqual(try store.db.cardBulkEntryDraft(),bulk)
    }
    func testBothParentInputAndOriginalInputRemainIndependent() throws {
        let (store,card,_,candidate) = try fixture()
        store.newCard(deck:"父牌组");store.cardEditor?.card.front = "另一张未完成的输入"
        store.cardEditor?.card.back = "父答案"
        let parent = try XCTUnwrap(store.cardEditor)
        open(store,card,candidate)
        store.cardEditor?.card.back = "独立的原卡草稿"
        XCTAssertTrue(store.returnToBulkEntry())
        XCTAssertEqual(store.cardEditor?.id,parent.id);XCTAssertEqual(store.cardEditor?.card,parent.card)
        XCTAssertTrue(store.savedCardDrafts.contains { $0.card.back == "独立的原卡草稿" })
        XCTAssertEqual(try store.db.card(id:card.id!)?.reps,8)
    }
    func testSaveOriginalThenReturnDoesNotCreateAnExtraCardOrLoseBatch() throws {
        let (store,card,bulk,candidate) = try fixture()
        open(store,card,candidate)
        store.cardEditor?.card.back = "已确认的新答案"
        XCTAssertNotNil(store.commitCardEditor());XCTAssertNil(store.cardEditor)
        XCTAssertTrue(store.returnToBulkEntry(allowClosedEditor:true))
        XCTAssertEqual(try store.db.card(id:card.id!)?.back,"已确认的新答案")
        XCTAssertEqual(try store.db.cardCount(),1)
        XCTAssertEqual(try store.db.cardBulkEntryDraft(),bulk)
        XCTAssertTrue(store.showsCardBulkEntry)
    }
    func testChangedParentDatabaseRecordRecoversAsNewInputWithoutOverwritingIt() throws {
        let (store,card,_,candidate) = try fixture()
        let parentCard = try store.db.save(Card(front:"父卡",back:"原父答案",state:.review,reps:5))
        store.editCard(parentCard);store.cardEditor?.card.back = "父卡未保存输入"
        open(store,card,candidate)
        var later = try XCTUnwrap(store.db.card(id:parentCard.id!));later.back = "后来正式更新";later.reps = 9
        _ = try store.db.save(later)
        XCTAssertTrue(store.returnToBulkEntry())
        XCTAssertNil(store.cardEditor?.card.id)
        XCTAssertEqual(store.cardEditor?.card.back,"父卡未保存输入")
        XCTAssertEqual(try store.db.card(id:parentCard.id!)?.back,"后来正式更新")
        XCTAssertEqual(try store.db.card(id:parentCard.id!)?.reps,9)
    }
    func testChangedDuplicateOrParentSessionDoesNotSwitchEditors() throws {
        let (store,card,_,candidate) = try fixture()
        store.newCard(deck:nil);store.cardEditor?.card.front = "父输入"
        let parentID = store.cardEditor?.id
        store.requestBulkOriginalEdit(candidateID:candidate.id,cardID:card.id!)
        var changed = card;changed.front = "已改为其他题面";_ = try store.db.save(changed)
        store.performPendingBulkOriginalEdit()
        XCTAssertEqual(store.cardEditor?.id,parentID);XCTAssertNil(store.bulkOriginalEditing.returning)
        XCTAssertTrue(store.showsCardBulkEntry)
        changed.front = card.front;_ = try store.db.save(changed)
        store.requestBulkOriginalEdit(candidateID:candidate.id,cardID:card.id!)
        store.cardEditor = CardDraft(card:Card(front:"新会话的输入"))
        let nextID = store.cardEditor?.id
        store.performPendingBulkOriginalEdit()
        XCTAssertEqual(store.cardEditor?.id,nextID);XCTAssertNil(store.bulkOriginalEditing.returning)
    }
    func testMissingDraftPersistenceRefusesToReplaceParentInput() throws {
        let (store,card,_,candidate) = try fixture(persistence:false)
        store.newCard(deck:nil);store.cardEditor?.card.front = "不可丢失"
        let parent = try XCTUnwrap(store.cardEditor)
        open(store,card,candidate)
        XCTAssertEqual(store.cardEditor?.id,parent.id);XCTAssertEqual(store.cardEditor?.card,parent.card)
        XCTAssertNil(store.bulkOriginalEditing.returning)
    }
    func testOpeningAnotherOriginalPreservesTheInitialParentReturnPath() throws {
        let (store,card,bulk,candidate) = try fixture()
        store.newCard(deck:"父牌组");store.cardEditor?.card.front = "最初的未完成输入"
        let parentID = store.cardEditor?.id
        open(store,card,candidate)
        store.cardEditor?.card.back = "第一张原卡的未保存修改"
        let firstEditorID = store.cardEditor?.id
        let other = try store.db.save(Card(front:"第二题",back:"第二答案"))
        var currentBulk = bulk
        let next = CardBulkEntryCandidate(line:2,values:["第二题","候选答案"])
        currentBulk.candidates.append(next)
        try store.db.saveCardBulkEntryDraft(currentBulk,expected:bulk)
        open(store,other,next)
        XCTAssertEqual(store.cardEditor?.card.id,other.id)
        XCTAssertTrue(store.returnToBulkEntry())
        XCTAssertEqual(store.cardEditor?.id,parentID)
        XCTAssertEqual(store.cardEditor?.card.front,"最初的未完成输入")
        XCTAssertEqual(store.savedCardDrafts.first { $0.id == firstEditorID }?.card.back,"第一张原卡的未保存修改")
    }
    func testUnmodifiedParentForSameCardRestoresLatestSavedOriginal() throws {
        let (store,card,_,candidate) = try fixture()
        store.editCard(try XCTUnwrap(store.db.card(id:card.id!)))
        let parentID = store.cardEditor?.id
        open(store,card,candidate)
        store.cardEditor?.card.back = "刚刚确认的新原卡答案"
        XCTAssertNotNil(store.commitCardEditor())
        XCTAssertTrue(store.returnToBulkEntry(allowClosedEditor:true))
        XCTAssertEqual(store.cardEditor?.id,parentID)
        XCTAssertEqual(store.cardEditor?.card.id,card.id)
        XCTAssertEqual(store.cardEditor?.card.back,"刚刚确认的新原卡答案")
        XCTAssertEqual(store.cardEditor?.card.reps,8)
        XCTAssertNotNil(store.commitCardEditor())
        XCTAssertEqual(try store.db.card(id:card.id!)?.back,"刚刚确认的新原卡答案")
    }
    func testClosedOriginalCanResumeBatchAndStaleGenerationCannotOpenIt() throws {
        let (store,card,_,candidate) = try fixture()
        open(store,card,candidate)
        store.cardEditor = nil
        store.resumeBulkAfterOriginalEditorDismissed()
        XCTAssertTrue(store.showsCardBulkEntry);XCTAssertNil(store.bulkOriginalEditing.returning)
        store.requestBulkOriginalEdit(candidateID:candidate.id,cardID:card.id!)
        store.bulkOriginalEditing.clear()
        store.performPendingBulkOriginalEdit()
        XCTAssertNil(store.cardEditor)
    }
    func testClosedBatchOrBackupBusyPreventsReturnFromOverwritingCurrentInput() throws {
        let (store,card,bulk,candidate) = try fixture()
        open(store,card,candidate)
        store.cardEditor?.card.back = "仍未保存的修改"
        let editorID = store.cardEditor?.id
        store.fullBackupBusy = true
        XCTAssertFalse(store.returnToBulkEntry())
        XCTAssertEqual(store.cardEditor?.id,editorID)
        store.fullBackupBusy = false
        try store.db.clearCardBulkEntryDraft(expectedID:bulk.id)
        XCTAssertFalse(store.returnToBulkEntry())
        XCTAssertEqual(store.cardEditor?.id,editorID)
        XCTAssertEqual(store.cardEditor?.card.back,"仍未保存的修改")
        XCTAssertEqual(try store.db.card(id:card.id!)?.back,"原答案")
    }
}
