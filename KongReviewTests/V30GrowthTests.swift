import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V30GrowthTests: XCTestCase {
    private var calendar: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(secondsFromGMT:0)!; c.firstWeekday=2; return c }
    private func date(_ y:Int,_ m:Int,_ d:Int,_ hour:Int=0)->Date { calendar.date(from:.init(year:y,month:m,day:d,hour:hour))! }
    func testAllPeriodWindowsAndPartialComparison() {
        let now=date(2026,10,17,12)
        for period in GrowthPeriod.allCases {
            let w=period.window(containing:now,now:now,calendar:calendar)
            XCTAssertLessThan(w.start,w.end); XCTAssertEqual(w.end,now)
            XCTAssertLessThan(w.previousStart,w.previousEnd); XCTAssertLessThanOrEqual(w.previousEnd,w.start)
        }
        let month=GrowthPeriod.month.window(containing:now,now:now,calendar:calendar)
        XCTAssertEqual(month.start,date(2026,10,1)); XCTAssertEqual(month.previousEnd,date(2026,9,17,12))
        let year=GrowthPeriod.year.window(containing:date(2024,12,1),now:now,calendar:calendar)
        XCTAssertEqual(year.end,date(2025,1,1)); XCTAssertEqual(year.previousEnd,date(2024,1,1))
    }
    func testLeapMonthAndDSTBounds() {
        let now=date(2024,3,31,12)
        let window=GrowthPeriod.month.window(containing:now,now:now,calendar:calendar)
        XCTAssertEqual(window.previousEnd,date(2024,3,1))
        var c=calendar; c.timeZone=TimeZone(identifier:"America/Los_Angeles")!
        let day=c.date(from:.init(year:2026,month:3,day:8,hour:12))!
        let w=GrowthPeriod.day.window(containing:day,now:day.addingTimeInterval(86400),calendar:c)
        XCTAssertEqual(w.fullEnd.timeIntervalSince(w.start),23*3600)
    }
    func testReflectionPersistsAcrossDatabaseReopenAndPeriodsRemainIndependent() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("test.sqlite").path
        let db=try AppDatabase(DatabaseQueue(path:path))
        let reflection=GrowthReflection(goalHighlights:12,goalCards:20,gains:"理解了新概念",challenges:"材料待核对",nextSteps:"再读原文")
        try db.saveProgress(reflection,key:"growth.month.2026-10-1")
        let reopened=try AppDatabase(DatabaseQueue(path:path))
        XCTAssertEqual(try reopened.progressValue(GrowthReflection.self,key:"growth.month.2026-10-1"),reflection)
        XCTAssertNil(try reopened.progressValue(GrowthReflection.self,key:"growth.day.2026-10-1"))
    }
    @MainActor func testCardCreationPreviewsAndRejectsDeletedOriginal() throws {
        let db=try AppDatabase(DatabaseQueue())
        var h=try db.save(Highlight(text:"应先预览的原文"))
        let store=LibraryStore(db:db,positionDefaults:nil)
        store.makeCard(from:h)
        XCTAssertNotNil(store.cardEditor); XCTAssertEqual(try db.cards(highlightIds:[h.id!]).count,0)
        store.cardEditor?.card.front="我修改的问题"
        h.deletedAt=Date(); _=try db.save(h)
        store.commitCardEditor()
        XCTAssertNotNil(store.cardEditor?.error); XCTAssertEqual(try db.cards(highlightIds:[h.id!]).count,0)
    }
    @MainActor func testCardPreviewSavesEditedQuestionDeckAndTags() throws {
        let db=try AppDatabase(DatabaseQueue())
        let h=try db.save(Highlight(text:"历史原文"))
        let store=LibraryStore(db:db,positionDefaults:nil)
        store.makeCard(from:h)
        store.cardEditor?.card.front="如何理解？"; store.cardEditor?.card.back="解释"
        store.cardEditor?.card.deck="自选牌组"; store.cardEditor?.tagsText="专题 阅读"
        store.commitCardEditor()
        let card=try XCTUnwrap(db.cards(highlightIds:[h.id!]).first)
        XCTAssertEqual(card.front,"如何理解？"); XCTAssertEqual(card.deck,"自选牌组"); XCTAssertTrue(card.tags.contains("专题"))
    }
    func testMaterialsRespectOptionsAndExcludeDeletedCards() async throws {
        let db=try AppDatabase(DatabaseQueue())
        let source=try db.save(Source(title:"测试出处",author:"作者"))
        let h=try db.save(Highlight(sourceId:source.id,text:"唯一原文",note:"唯一按语"))
        _=try db.save(Card(front:"唯一问题",back:"唯一答案",highlightId:h.id))
        _=try db.save(Card(front:"删除卡",highlightId:h.id,deletedAt:Date()))
        let material=try await db.learningMaterial(scope:.source(source.id!))
        XCTAssertEqual(material.cards.count,1)
        let all=material.markdown(options:.init())
        XCTAssertTrue(all.contains("唯一原文")); XCTAssertTrue(all.contains("唯一答案")); XCTAssertTrue(all.contains("唯一按语")); XCTAssertTrue(all.contains("测试出处"))
        let qa=material.markdown(options:.init(text:false,notes:false,cards:true,citations:false))
        XCTAssertFalse(qa.contains("唯一原文")); XCTAssertFalse(qa.contains("唯一按语")); XCTAssertTrue(qa.contains("唯一答案"))
        let snap=try await db.topicSnapshot(scope:.source(source.id!),section:.cards,offset:0)
        XCTAssertEqual(snap.cards,1); XCTAssertEqual(snap.highlights,1); XCTAssertEqual(snap.sources,1)
    }
    func testNotebookTopicDeduplicatesMembershipAndKeepsNotebookNotes() async throws {
        let db=try AppDatabase(DatabaseQueue())
        let notebook=try db.createNotebook(title:"近现代史专题")
        let source=try db.save(Source(title:"测试书"))
        let h=try db.save(Highlight(sourceId:source.id,text:"专题原文"))
        _=try db.insertBlocks([
            NotebookBlock(notebookId:notebook.id!,position:1,kind:.highlight,highlightId:h.id,note:"专题批注"),
            NotebookBlock(notebookId:notebook.id!,position:2,kind:.highlight,highlightId:h.id),
            NotebookBlock(notebookId:notebook.id!,position:3,kind:.text,text:"自己的综述")
        ],into:notebook.id!,after:nil)
        _=try db.save(Card(front:"题目",back:"答案",highlightId:h.id,reps:2))
        for section in TopicSection.allCases {
            let snapshot=try await db.topicSnapshot(scope:.notebook(notebook.id!),section:section,offset:0)
            XCTAssertEqual(snapshot.highlights,1); XCTAssertEqual(snapshot.cards,1); XCTAssertEqual(snapshot.sources,1)
            XCTAssertEqual(snapshot.studied,1); XCTAssertEqual(snapshot.page.total,1)
        }
        let material=try await db.learningMaterial(scope:.notebook(notebook.id!))
        let text=material.markdown(options:.init())
        XCTAssertTrue(text.contains("专题批注")); XCTAssertTrue(text.contains("自己的综述"))
    }

    func testScanCheckpointRestoresCursorAndInvalidatesChangedInventory() async throws {
        let db=try AppDatabase(DatabaseQueue())
        for i in 0..<40 { _=try db.save(Card(front:"问题\(i)",back:"答案\(i)")) }
        let session=try await FullSimilaritySession.create(db:db,deck:nil)
        let batch=try await session.nextBatch()
        try await session.saveCheckpoint(groups:batch.groups)
        let resumed=try await FullSimilaritySession.create(db:db,deck:nil,resume:true)
        let next=try await resumed.nextBatch()
        XCTAssertGreaterThan(next.compared,batch.compared)
        XCTAssertEqual(next.compared,39)
        _=try db.save(Card(front:"新加入的问题",back:"答案"))
        let changed=try await FullSimilaritySession.create(db:db,deck:nil,resume:true)
        let restored=await changed.restoredResult(); XCTAssertNotNil(restored.notice)
        let restart=try await changed.nextBatch(); XCTAssertEqual(restart.compared,32); XCTAssertEqual(restart.total,41)
    }
    func testCheckpointSurvivesDatabaseReopen() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("test.sqlite").path
        let first=try AppDatabase(DatabaseQueue(path:path))
        for i in 0..<12 { _=try first.save(Card(front:"问题\(i)",back:"答案\(i)")) }
        let session=try await FullSimilaritySession.create(db:first,deck:nil)
        let progress=try await session.nextBatch()
        try await session.saveCheckpoint(groups:progress.groups)
        let reopened=try AppDatabase(DatabaseQueue(path:path))
        let resumed=try await FullSimilaritySession.create(db:reopened,deck:nil,resume:true)
        let next=try await resumed.nextBatch()
        XCTAssertEqual(progress.compared,11); XCTAssertEqual(next.compared,21)
        XCTAssertEqual(next.completed,2)
    }
    func testPrintLayoutEscapesMarkupAndCreatesHeadings() {
        let material=LearningMaterial(title:"<script>alert(1)</script>",highlights:[Highlight(text:"正文",note:"按语")],sources:[],cards:[],notebookNotes:[])
        let html=material.printHTML(options:.init())
        XCTAssertTrue(html.contains("<h1>")); XCTAssertTrue(html.contains("<h2>"))
        XCTAssertFalse(html.contains("<script>")); XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<img"))
    }

    func testOldCompleteBackupMigratesAndNewBackupPreservesReflection() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let prefs=UserDefaults(suiteName:UUID().uuidString)!
        let old=try AppDatabase(DatabaseQueue(),upTo:"v13-event-card-state")
        _=try old.save(Highlight(text:"2.9的原文"))
        let url=directory.appendingPathComponent("old.kongreviewbackup")
        try FullBackupService.create(db:old,draftURL:nil,defaults:prefs,destination:url)
        let prepared=try FullBackupService.prepare(url:url); defer { prepared.cleanup() }
        let target=try AppDatabase(DatabaseQueue())
        _=try FullBackupService.restore(prepared,db:target,draftURL:nil,defaults:prefs,safetyDirectory:directory)
        let value=GrowthReflection(goalHighlights:3,gains:"备份中的成长记录")
        try target.saveProgress(value,key:"growth.test")
        let next=directory.appendingPathComponent("new.kongreviewbackup")
        try FullBackupService.create(db:target,draftURL:nil,defaults:prefs,destination:next)
        let newer=try FullBackupService.prepare(url:next); defer { newer.cleanup() }
        let restored=try AppDatabase(DatabaseQueue())
        _=try FullBackupService.restore(newer,db:restored,draftURL:nil,defaults:prefs,safetyDirectory:directory)
        XCTAssertEqual(try restored.progressValue(GrowthReflection.self,key:"growth.test"),value)
    }
}
