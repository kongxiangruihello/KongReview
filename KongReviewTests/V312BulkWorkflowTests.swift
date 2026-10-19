import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V312BulkWorkflowTests: XCTestCase {
    private func database() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }
    private func draft(_ front: String = "录入问题") -> CardBulkEntryDraft {
        var value = CardBulkEntryDraft()
        value.source = "题目\t解释\n\(front)\t答案"
        value.firstRowIsHeader = true;value.headers = ["题目","解释"]
        value.configuration = .init(deck:"历史",tags:["史料"],mapping:[.front,.back])
        value.candidates = [.init(line:2,values:["<p>\(front)</p>","<p>候选修改后的答案</p>"])]
        value.selectedIDs = Set(value.candidates.map(\.id))
        return value
    }
    private func preview(_ db: AppDatabase,_ draft: CardBulkEntryDraft) throws -> CardBulkEntryPreview {
        try db.previewCardBulkEntry(candidates:draft.candidates,configuration:draft.configuration,selectedIDs:draft.selectedIDs)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-V312Bulk-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }

    func testDraftRoundTripRetainsSourceMappingPresetSelectionAndUnappliedCandidateEdits() throws {
        let db = try database()
        var value = draft()
        value.format = .questionAnswer;value.page = 3
        value.configuration.preset = CardEntryPreset(name:"冻结结构",sections:[.init(name:"分析",folded:true,rule:.init(hint:"背景与影响",required:true))])
        value.configuration.mapping = [.front,.section(0)]
        value.candidates.append(.init(line:6,values:["<p>不选择的问题</p>","<p>第二答案</p>"]))
        value.editingCandidate = value.candidates[0]
        value.editingCandidate?.values[1] = "<p>编辑器里尚未点击应用的答案</p>"
        try db.saveCardBulkEntryDraft(value,expected:nil)
        XCTAssertEqual(try db.cardBulkEntryDraft(),value)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(CardBulkEntryDraft.self,from:data),value)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("duplicateCardID"))
    }

    func testDatabaseReopenRestoresBatchWithoutCreatingCards() throws {
        let path = try directory().appendingPathComponent("fixture.sqlite").path
        let value = draft()
        do { let db = try AppDatabase(DatabaseQueue(path:path));try db.saveCardBulkEntryDraft(value,expected:nil) }
        let reopened = try AppDatabase(DatabaseQueue(path:path))
        XCTAssertEqual(try reopened.cardBulkEntryDraft(),value)
        XCTAssertEqual(try reopened.cardCount(),0)
    }

    func testOlderDraftWithoutOptionalReviewStateDecodesWithoutLosingSource() throws {
        let json = #"{"source":"问：旧草稿\n答：保留答案","format":"questionAnswer"}"#
        let value = try JSONDecoder().decode(CardBulkEntryDraft.self,from:Data(json.utf8))
        XCTAssertEqual(value.source,"问：旧草稿\n答：保留答案")
        XCTAssertEqual(value.format,.questionAnswer)
        XCTAssertEqual(value.page,1)
        XCTAssertNil(value.editingCandidate)
        XCTAssertTrue(value.candidates.isEmpty)
    }

    func testCompareAndSwapRejectsOldWindowAndDiscardedDraftCannotResurrect() throws {
        let db = try database(), first = draft()
        try db.saveCardBulkEntryDraft(first,expected:nil)
        var changed = first;changed.source += "\n新的输入"
        try db.saveCardBulkEntryDraft(changed,expected:first)
        var stale = first;stale.configuration.deck = "过时窗口"
        XCTAssertThrowsError(try db.saveCardBulkEntryDraft(stale,expected:first))
        XCTAssertEqual(try db.cardBulkEntryDraft(),changed)
        XCTAssertThrowsError(try db.clearCardBulkEntryDraft(expectedID:UUID()))
        try db.clearCardBulkEntryDraft(expectedID:first.id)
        XCTAssertNil(try db.cardBulkEntryDraft())
        XCTAssertThrowsError(try db.saveCardBulkEntryDraft(first,expected:nil))
        XCTAssertNil(try db.cardBulkEntryDraft())
    }

    func testSuccessfulSaveClearsDraftAtomicallyAndReceiptBlocksReplayAfterCardRenaming() throws {
        let db = try database(), value = draft()
        try db.saveCardBulkEntryDraft(value,expected:nil)
        let checked = try preview(db,value)
        var saved = try XCTUnwrap(try db.saveCardBulkEntry(checked,draft:value).first)
        XCTAssertNil(try db.cardBulkEntryDraft())
        saved.front = "重命名后的原卡"
        _ = try db.save(saved)
        XCTAssertThrowsError(try db.saveCardBulkEntry(checked,draft:value))
        XCTAssertThrowsError(try db.saveCardBulkEntryDraft(value,expected:nil))
        XCTAssertEqual(try db.cardCount(),1)
    }

    func testStaleConfigurationAndTransactionFailureRetainWholeDraftForRetry() throws {
        let db = try database(), value = draft()
        try db.saveCardBulkEntryDraft(value,expected:nil)
        let checked = try preview(db,value)
        var newer = value;newer.configuration.tags.append("新标签")
        try db.saveCardBulkEntryDraft(newer,expected:value)
        XCTAssertThrowsError(try db.saveCardBulkEntry(checked,draft:value))
        XCTAssertEqual(try db.cardCount(),0)
        XCTAssertEqual(try db.cardBulkEntryDraft(),newer)
        let fresh = try preview(db,newer)
        try db.writer.write { try $0.execute(sql:"CREATE TRIGGER fixture_bulk_abort BEFORE INSERT ON card BEGIN SELECT RAISE(ABORT,'fixture'); END") }
        XCTAssertThrowsError(try db.saveCardBulkEntry(fresh,draft:newer))
        XCTAssertEqual(try db.cardBulkEntryDraft(),newer)
        XCTAssertFalse(try db.writer.read { try AppDatabase.cardBulkEntryWasClosed(value.id,in:$0) })
        try db.writer.write { try $0.execute(sql:"DROP TRIGGER fixture_bulk_abort") }
        XCTAssertEqual(try db.saveCardBulkEntry(fresh,draft:newer).count,1)
    }

    func testRestorationRechecksNewDuplicateAndExposesExactOriginalCard() throws {
        let db = try database(), value = draft("  EXAMPLE   Question  ")
        try db.saveCardBulkEntryDraft(value,expected:nil)
        XCTAssertTrue(try preview(db,value).canSave)
        let original = try db.save(Card(deck:"不同牌组",front:"<b>example question</b>",back:"原答案"))
        let restored = try XCTUnwrap(db.cardBulkEntryDraft())
        let checked = try preview(db,restored)
        XCTAssertFalse(checked.canSave)
        XCTAssertEqual(checked.items.first?.duplicateCardID,original.id)
        XCTAssertFalse(checked.items[0].duplicateIsDeleted)
        XCTAssertThrowsError(try db.saveCardBulkEntry(checked,draft:restored))
        XCTAssertEqual(try db.cardBulkEntryDraft(),value)
    }

    func testTrashOriginalCanBeViewedButIsMarkedUnavailableForEditingAndAppend() throws {
        let db = try database(), value = draft("被删除的题")
        let deleted = try db.save(Card(front:"被删除的题",deletedAt:Date()))
        let checked = try preview(db,value)
        XCTAssertEqual(checked.items.first?.duplicateCardID,deleted.id)
        XCTAssertTrue(checked.items[0].duplicateIsDeleted)
        XCTAssertFalse(checked.canSave)
    }

    func testAppendUsesExistingSafeComposerUndoAndKeepsOtherCandidates() throws {
        let db = try database()
        let inserted = try db.save(Card(deck:"原牌组",front:"重复问题",back:"<p>原答案</p>",tags:["原标签"]))
        // The append UI reads the persisted row; use the same SQLite date-precision baseline.
        let original = try XCTUnwrap(db.card(id:inserted.id!))
        var value = draft("重复问题")
        value.candidates.append(.init(line:3,values:["<p>其余新题</p>","<p>其他答案</p>"]))
        value.selectedIDs = Set(value.candidates.map(\.id))
        try db.saveCardBulkEntryDraft(value,expected:nil)
        let checked = try preview(db,value)
        let incoming = try XCTUnwrap(checked.items.first?.card)
        let append = try CardAnswerAppendComposer.preview(from:incoming,to:original,incomingTemplate:nil,existingTemplate:nil,
            selection:.init(sourceIDs:[.back],target:.back))
        let token = try db.appendCardAnswerRecordingUndo(append)
        var continuing = value;continuing.selectedIDs.remove(value.candidates[0].id)
        try db.saveCardBulkEntryDraft(continuing,expected:value)
        let next = try preview(db,continuing)
        XCTAssertTrue(next.canSave)
        XCTAssertEqual(next.selectedIDs,[value.candidates[1].id])
        XCTAssertEqual(try db.card(id:original.id!)?.tags,["原标签"])
        _ = try db.undoCardAppend(token)
        XCTAssertEqual(try db.card(id:original.id!)?.back,"<p>原答案</p>")
        XCTAssertEqual(try db.cardBulkEntryDraft(),continuing)
        XCTAssertEqual(try db.saveCardBulkEntry(next,draft:continuing).count,1)
        XCTAssertEqual(try db.cardCount(),2)
    }

    func testFullBackupIncludesUnfinishedBatchAndClosedBatchReceipts() throws {
        let origin = try database(), target = try database(), value = draft()
        var closed = draft("已经丢弃")
        try origin.saveCardBulkEntryDraft(closed,expected:nil)
        try origin.clearCardBulkEntryDraft(expectedID:closed.id)
        try origin.saveCardBulkEntryDraft(value,expected:nil)
        let suite = "KongReview.V312Bulk.\(UUID().uuidString)"
        let settings = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { settings.removePersistentDomain(forName:suite) }
        let archive = try directory().appendingPathComponent("batch.kongreviewbackup")
        try FullBackupService.create(db:origin,draftURL:nil,defaults:settings,destination:archive)
        let prepared = try FullBackupService.prepare(url:archive)
        defer { prepared.cleanup() }
        _ = try FullBackupService.restore(prepared,db:target,draftURL:nil,defaults:settings,safetyDirectory:directory())
        XCTAssertEqual(try target.cardBulkEntryDraft(),value)
        try target.clearCardBulkEntryDraft(expectedID:value.id)
        closed.source += "attempted stale write"
        XCTAssertThrowsError(try target.saveCardBulkEntryDraft(closed,expected:nil))
    }
}
