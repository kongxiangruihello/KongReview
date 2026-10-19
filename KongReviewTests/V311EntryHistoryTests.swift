import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V311EntryHistoryTests: XCTestCase {
    private func all() -> CardEntryHistoryQuery { .init(date:nil) }
    private func recorded(_ db: AppDatabase, front: String, at date: Date, deck: String = "默认") throws -> Card {
        try db.writer.write { sql in
            var card = Card(deck:deck,front:front)
            try card.save(sql)
            try AppDatabase.recordCardEntry(card,at:date,in:sql)
            return card
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-V311-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    func testEntryWritesOnceAndEditingNeverChangesEntryDate() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try XCTUnwrap(db.saveInputCards([Card(front:"第一次录入")]).first)
        let initial = try XCTUnwrap(db.cardEntryHistoryPage(query:all(),page:1).items.first)
        card.back = "再次保存不会变成新卡"
        _ = try db.saveInputCards([card])
        let result = try db.cardEntryHistoryPage(query:all(),page:1)
        XCTAssertEqual(result.total,1);XCTAssertEqual(result.items.first?.recordedAt,initial.recordedAt)
        XCTAssertEqual(result.items.first?.card.back,card.back)
    }
    func testDuplicateBatchRollsBackBothCardsAndEntryRecords() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertThrowsError(try db.saveInputCards([Card(front:"相同"),Card(front:" 相同 ")]))
        XCTAssertEqual(try db.cardCount(),0)
        XCTAssertEqual(try db.cardEntryHistoryPage(query:all(),page:1).total,0)
    }
    func testEntryHistorySurvivesClosingAndReopeningDatabase() throws {
        let dir = try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let path = dir.appendingPathComponent("library.sqlite").path
        let queue = try DatabaseQueue(path:path),db = try AppDatabase(queue)
        let card = try recorded(db,front:"重启前录入",at:Date(timeIntervalSince1970:123456))
        try queue.close()
        let reopenedQueue = try DatabaseQueue(path:path);defer { try? reopenedQueue.close() }
        let reopened = try AppDatabase(reopenedQueue)
        XCTAssertEqual(try reopened.cardEntryHistoryPage(query:all(),page:1).items.map(\.id),[card.id!])
        XCTAssertEqual(try reopened.cardEntryHistoryPage(query:all(),page:1).items.first?.recordedAt,Date(timeIntervalSince1970:123456))
    }
    func testHistoryPagesAreStableAndClampWhenCardsDisappear() throws {
        let db = try AppDatabase(DatabaseQueue()),date = Date()
        var ids: [Int64] = []
        for i in 0..<151 { ids.append(try recorded(db,front:"记录\(i)",at:date).id!) }
        var seen = Set<Int64>()
        for page in 1...4 {
            let value = try db.cardEntryHistoryPage(query:all(),page:page)
            XCTAssertEqual(value.total,151);XCTAssertTrue(seen.isDisjoint(with:value.items.map(\.id)))
            seen.formUnion(value.items.map(\.id))
        }
        XCTAssertEqual(seen,Set(ids))
        try db.deleteCards(Array(ids.suffix(53)))
        let last = try db.cardEntryHistoryPage(query:all(),page:99)
        XCTAssertEqual(last.page,2);XCTAssertEqual(last.total,98);XCTAssertEqual(last.items.count,48)
    }
    func testLocalDayUsesCalendarBoundaryAcrossDaylightSaving() throws {
        let db = try AppDatabase(DatabaseQueue())
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:"America/New_York")!
        let start = calendar.date(from:DateComponents(year:2026,month:11,day:1))!
        let end = calendar.date(byAdding:.day,value:1,to:start)!
        XCTAssertEqual(end.timeIntervalSince(start),25 * 3600)
        _ = try recorded(db,front:"前一天",at:start.addingTimeInterval(-1))
        let a = try recorded(db,front:"当天开始",at:start)
        let b = try recorded(db,front:"当天最后",at:end.addingTimeInterval(-1))
        _ = try recorded(db,front:"下一天",at:end)
        let result = try db.cardEntryHistoryPage(query:.init(date:start,calendar:calendar),page:1)
        XCTAssertEqual(Set(result.items.map(\.id)),[a.id!,b.id!])
    }
    func testSearchIsLiteralAndFoldedAndCombinesDeckFilter() throws {
        let db = try AppDatabase(DatabaseQueue())
        let target = try recorded(db,front:"臺灣 ＡＢＣ 100%",at:Date(),deck:"近代史")
        _ = try recorded(db,front:"台湾 abc 1000",at:Date(),deck:"近代史")
        _ = try recorded(db,front:"台湾 abc 100%",at:Date(),deck:"其他")
        let result = try db.cardEntryHistoryPage(query:.init(date:nil,text:"台湾 abc 100%",deck:"近代史"),page:1)
        XCTAssertEqual(result.items.map(\.id),[target.id!])
    }
    func testSoftDeleteHidesRecordAndRestoreRetainsOriginalDate() throws {
        let db = try AppDatabase(DatabaseQueue()),date = Date(timeIntervalSince1970:111111)
        var card = try recorded(db,front:"删除后恢复",at:date)
        card.deletedAt = Date();_ = try db.save(card)
        XCTAssertEqual(try db.cardEntryHistoryPage(query:all(),page:1).total,0)
        try db.restoreInputDuplicate(id:card.id!)
        let restored = try db.cardEntryHistoryPage(query:all(),page:1)
        XCTAssertEqual(restored.total,1);XCTAssertEqual(restored.items.first?.recordedAt,date)
    }
    func testOldLibraryMigrationDoesNotMistakeImportsOrEditsForNewEntries() throws {
        let queue = try DatabaseQueue(),old = try AppDatabase(queue,upTo:"v14-growth-progress")
        let card = try old.save(Card(front:"旧版本卡片"))
        try old.migrateIfNeeded()
        XCTAssertEqual(try old.cardEntryHistoryPage(query:all(),page:1).total,0)
        _ = try old.saveInputCards([card])
        XCTAssertEqual(try old.cardEntryHistoryPage(query:all(),page:1).total,0)
        _ = try old.saveInputCards([Card(front:"升级后新录入")])
        XCTAssertEqual(try old.cardEntryHistoryPage(query:all(),page:1).total,1)
    }
    func testHistorySelectionRejectsOutsideDateDeckAndNonEntryCard() throws {
        let db = try AppDatabase(DatabaseQueue()),date = Date()
        let card = try recorded(db,front:"有效录入",at:date,deck:"甲")
        let outside = try db.save(Card(front:"导入卡"))
        XCTAssertThrowsError(try db.validateCardEntryHistorySelection([card.id!,outside.id!],query:all()))
        XCTAssertThrowsError(try db.validateCardEntryHistorySelection([card.id!],query:.init(date:nil,deck:"乙")))
        XCTAssertThrowsError(try db.validateCardEntryHistorySelection([card.id!],query:.init(date:date.addingTimeInterval(-172800))))
    }
    func testHistoryEditKeepsIncomingDraftAndStaleRequestsCannotOpenCards() throws {
        let db = try AppDatabase(DatabaseQueue()),dir = try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let card = try recorded(db,front:"历史卡片",at:Date())
        let store = LibraryStore(db:db,draftPersistence:try EditorDraftPersistence(directory:dir),positionDefaults:nil)
        store.newCard(deck:nil);store.cardEditor?.card.front = "正在输入的另一张"
        let incoming = try XCTUnwrap(store.cardEditor)
        store.scheduleCardEntryHistoryEdit(id:card.id!,query:all(),generation:store.cardEntryHistory.generation)
        store.performPendingCardEntryHistoryEdit()
        XCTAssertEqual(store.cardEditor?.card.id,card.id)
        XCTAssertTrue(store.returnToIncomingCardDraft());XCTAssertEqual(store.cardEditor?.id,incoming.id)
        let generation = store.cardEntryHistory.generation
        store.cardEntryHistory.clear()
        store.scheduleCardEntryHistoryEdit(id:card.id!,query:all(),generation:generation)
        XCTAssertNil(store.cardEntryHistory.pendingEdit)
        store.fullBackupBusy = true
        XCTAssertFalse(store.openRecordedCardPreservingDraft(id:card.id!))
        XCTAssertEqual(store.cardEditor?.id,incoming.id)
    }
    func testFullBackupIncludesEntryRecordsAndAcceptsPreviousVersionSchema() throws {
        let dir = try directory();defer { try? FileManager.default.removeItem(at:dir) }
        let suite = "KongReview.V311.History." + UUID().uuidString,defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let db = try AppDatabase(DatabaseQueue()),date = Date(timeIntervalSince1970:44444)
        let card = try recorded(db,front:"备份录入",at:date)
        let url = dir.appendingPathComponent("current.kongreviewbackup")
        try FullBackupService.create(db:db,draftURL:nil,defaults:defaults,destination:url)
        let backup = try FullBackupService.prepare(url:url);defer { backup.cleanup() }
        let target = try AppDatabase(DatabaseQueue())
        _ = try FullBackupService.restore(backup,db:target,draftURL:nil,defaults:defaults,safetyDirectory:dir.appendingPathComponent("safety"))
        XCTAssertEqual(try target.cardEntryHistoryPage(query:all(),page:1).items.first?.id,card.id)
        XCTAssertEqual(try target.cardEntryHistoryPage(query:all(),page:1).items.first?.recordedAt,date)
        let previous = try AppDatabase(DatabaseQueue(),upTo:"v14-growth-progress")
        _ = try previous.save(Card(front:"上一版本"))
        let previousURL = dir.appendingPathComponent("previous.kongreviewbackup")
        try FullBackupService.create(db:previous,draftURL:nil,defaults:defaults,destination:previousURL)
        let oldBackup = try FullBackupService.prepare(url:previousURL);defer { oldBackup.cleanup() }
        _ = try FullBackupService.restore(oldBackup,db:target,draftURL:nil,defaults:defaults,safetyDirectory:dir.appendingPathComponent("old-safety"))
        XCTAssertEqual(try target.cardCount(),1)
        XCTAssertEqual(try target.cardEntryHistoryPage(query:all(),page:1).total,0)
    }
}
