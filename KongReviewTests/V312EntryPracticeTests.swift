import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V312EntryPracticeTests: XCTestCase {
    private let generation = UUID()
    private var all: CardEntryHistoryQuery { .init(date:nil) }

    private func recorded(_ db: AppDatabase,front: String,at: Date = Date(),deck: String = "测试") throws -> Card {
        try db.writer.write { sql in
            var card = Card(deck:deck,front:front,back:"参考答案：" + front)
            try card.save(sql);try AppDatabase.recordCardEntry(card,at:at,in:sql)
            return try Card.fetchOne(sql,key:card.id!)!
        }
    }
    private func session(_ db: AppDatabase,ids: [Int64],query: CardEntryHistoryQuery? = nil,page: Int = 1) throws -> CardEntryPracticeSession {
        try db.cardEntryPracticeSession(ids:ids,allowedIDs:ids,query:query ?? all,page:page,generation:generation)
    }
    private func databaseSnapshot(_ db: AppDatabase) throws -> [String:[Row]] {
        try db.writer.read { sql in
            let names = try String.fetchAll(sql,sql:"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            return try Dictionary(uniqueKeysWithValues:names.map { name in
                (name,try Row.fetchAll(sql,sql:"SELECT * FROM \"" + name.replacingOccurrences(of:"\"",with:"\"\"") + "\""))
            })
        }
    }

    func testLearningStatusIsExclusiveAndNewOrSuspendedHaveNoActionableDue() {
        for state in [Card.State.new,.learning,.review,.relearning] {
            var card = Card(front:"状态",state:state,reps:7)
            let status = CardEntryLearningStatus(card:card)
            XCTAssertEqual(status,state == .new ? .unseen : state == .review ? .reviewed : .learning)
            XCTAssertEqual(status.nextDue(for:card),state == .new ? nil : card.due)
            card.isSuspended = true
            XCTAssertEqual(CardEntryLearningStatus(card:card),.suspended)
            XCTAssertNil(CardEntryLearningStatus(card:card).nextDue(for:card))
            XCTAssertEqual(card.reps,7)
        }
    }

    func testInclusiveDateRangeUsesLocalCalendarAndEndOfLastDay() throws {
        let db = try AppDatabase(DatabaseQueue())
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:"America/New_York")!
        let start = calendar.date(from:DateComponents(year:2026,month:10,day:31))!
        let last = calendar.date(byAdding:.day,value:1,to:start)!
        let end = calendar.date(byAdding:.day,value:1,to:last)!
        _ = try recorded(db,front:"范围前",at:start.addingTimeInterval(-1))
        let first = try recorded(db,front:"首日",at:start)
        let second = try recorded(db,front:"末日",at:end.addingTimeInterval(-1))
        _ = try recorded(db,front:"范围后",at:end)
        let query = CardEntryHistoryQuery(date:start,endDate:last,calendar:calendar)
        XCTAssertEqual(Set(try db.cardEntryHistoryPage(query:query,page:1).items.map(\.id)),[first.id!,second.id!])
        XCTAssertEqual(try session(db,ids:[first.id!,second.id!],query:query).cards.count,2)
    }

    func testStartRereadsLatestCardAndActualRenderingTemplate() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try recorded(db,front:"旧题面")
        let template = NoteTemplate(name:"测试类型",fieldNames:["题","答"],front:[0],back:[1])
        try db.save(template)
        card.front = "新题面";card.noteType = template.name;card.fields = ["字段问题","字段答案"];card.reps = 3
        _ = try db.save(card)
        let value = try session(db,ids:[card.id!])
        XCTAssertEqual(value.current?.front,"新题面");XCTAssertEqual(value.current?.reps,3)
        XCTAssertEqual(value.templates[template.name],template)
        XCTAssertTrue(value.current!.faces(using:value.templates[template.name]).back.contains("字段答案"))
    }

    func testSelectionMustStillBelongToVisiblePageAndProvidedAllowedSet() throws {
        let db = try AppDatabase(DatabaseQueue())
        var ids: [Int64] = []
        for i in 0..<51 { ids.append(try recorded(db,front:"分页\(i)",at:Date(timeIntervalSince1970:Double(i))).id!) }
        XCTAssertThrowsError(try db.cardEntryPracticeSession(ids:[ids[0]],allowedIDs:ids,query:all,page:1,generation:generation))
        XCTAssertEqual(try session(db,ids:[ids[0]],page:2).cards.map(\.id),[ids[0]])
        XCTAssertThrowsError(try db.cardEntryPracticeSession(ids:[ids.last!],allowedIDs:[ids[0]],query:all,page:1,generation:generation))
        XCTAssertThrowsError(try session(db,ids:[ids.last!,ids.last!]))
        XCTAssertThrowsError(try session(db,ids:[]))
        XCTAssertThrowsError(try session(db,ids:[ids[0]],page:99))
    }

    func testQueryScopeRejectsOtherDateDeckSearchAndCardsWithoutEntryRecord() throws {
        let db = try AppDatabase(DatabaseQueue()),date = Date()
        let card = try recorded(db,front:"有效题目",at:date,deck:"甲")
        let imported = try db.save(Card(front:"只有卡片，没有录入记录"))
        XCTAssertThrowsError(try session(db,ids:[imported.id!]))
        XCTAssertThrowsError(try session(db,ids:[card.id!],query:.init(date:date.addingTimeInterval(-172800))))
        XCTAssertThrowsError(try session(db,ids:[card.id!],query:.init(date:nil,deck:"乙")))
        XCTAssertThrowsError(try session(db,ids:[card.id!],query:.init(date:nil,text:"不存在的搜索词")))
    }

    func testResponsesAndSelfAssessmentSurviveForwardBackAndRemainPerCard() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try recorded(db,front:"问题一"),b = try recorded(db,front:"问题二")
        var value = try session(db,ids:[a.id!,b.id!])
        let firstID = value.current!.id!
        value.setResponse(.init(text:"自己的第一份回答",assessment:.remembered))
        XCTAssertNil(value.currentResponse.assessment,"翻面前不允许自评")
        value.revealAnswer();value.setResponse(.init(text:"自己的第一份回答",assessment:.partlyRemembered))
        value.next();XCTAssertFalse(value.showingAnswer);XCTAssertEqual(value.currentResponse.text,"")
        XCTAssertNotEqual(value.current?.id,firstID)
        value.setResponse(.init(text:"自己的第二份回答"));value.revealAnswer()
        value.previous();XCTAssertTrue(value.showingAnswer)
        XCTAssertEqual(value.currentResponse.text,"自己的第一份回答");XCTAssertEqual(value.currentResponse.assessment,.partlyRemembered)
        value.next();XCTAssertEqual(value.currentResponse.text,"自己的第二份回答")
        value.next();XCTAssertTrue(value.isFinished);XCTAssertEqual(value.answeredCount,2);XCTAssertEqual(value.assessedCount,1)
        value.revisit();XCTAssertFalse(value.isFinished);XCTAssertEqual(value.currentResponse.text,"自己的第一份回答")
    }

    func testStartingAnsweringNavigatingAssessingAndFinishingNeverWriteAnyDatabaseTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try recorded(db,front:"只读练习一"),b = try recorded(db,front:"只读练习二")
        let before = try databaseSnapshot(db)
        var value = try session(db,ids:[a.id!,b.id!])
        for _ in 0..<2 {
            try db.validateCardEntryPractice(value)
            value.setResponse(.init(text:"本人的回答"));value.revealAnswer()
            value.setResponse(.init(text:"本人的回答",assessment:.remembered));value.next()
        }
        value.previous();value.revisit();try db.validateCardEntryPractice(value)
        XCTAssertEqual(try databaseSnapshot(db),before)
        XCTAssertEqual(try db.writer.read { try ReviewEvent.fetchCount($0) },0)
    }

    func testDeletionAndAnySelectedCardMutationInvalidatesEntireSnapshot() throws {
        for deleted in [false,true] {
            let db = try AppDatabase(DatabaseQueue())
            let a = try recorded(db,front:"当前题"),b = try recorded(db,front:"后续题")
            let value = try session(db,ids:[a.id!,b.id!])
            let futureID = value.cards.last!.id!
            if deleted { try db.deleteCards([futureID]) }
            else { var latest = try XCTUnwrap(db.card(id:futureID));latest.back = "刚改过的参考答案";_ = try db.save(latest) }
            XCTAssertThrowsError(try db.validateCardEntryPractice(value)) { XCTAssertEqual($0 as? CardEntryPracticeError,.materialsChanged) }
        }
    }

    func testReferencedTemplateChangeOrRemovalInvalidatesButUnrelatedTemplateDoesNot() throws {
        let db = try AppDatabase(DatabaseQueue())
        let template = NoteTemplate(name:"原类型",fieldNames:["题","答"],front:[0],back:[1])
        try db.save(template)
        var card = try recorded(db,front:"模板题");card.noteType = template.name;card.fields = ["题目","答案"];_ = try db.save(card)
        let value = try session(db,ids:[card.id!])
        try db.save(NoteTemplate(name:"其他类型",fieldNames:["其他"],front:[0],back:[]))
        XCTAssertNoThrow(try db.validateCardEntryPractice(value))
        var changed = template;changed.collapsed = [1];try db.save(changed)
        XCTAssertThrowsError(try db.validateCardEntryPractice(value))
        try db.save(template)
        let fresh = try session(db,ids:[card.id!])
        try db.writer.write { try NoteTemplate.deleteOne($0,key:template.name) }
        XCTAssertThrowsError(try db.validateCardEntryPractice(fresh))
    }

    func testSuspendedCardCanBePracticedWithoutUnsuspendingOrChangingDue() throws {
        let db = try AppDatabase(DatabaseQueue())
        var card = try recorded(db,front:"已暂停的卡")
        card.isSuspended = true;card.state = .review;card.reps = 10;card.due = Date(timeIntervalSince1970:123456)
        _ = try db.save(card)
        let before = try XCTUnwrap(db.card(id:card.id!))
        var value = try session(db,ids:[card.id!]);value.revealAnswer();value.setResponse(.init(text:"回答",assessment:.remembered));value.next()
        try db.validateCardEntryPractice(value)
        XCTAssertEqual(try db.card(id:card.id!),before)
    }

    func testLibraryGenerationAndBackupBusyStopExistingPractice() throws {
        let db = try AppDatabase(DatabaseQueue()),card = try recorded(db,front:"重新载入")
        let store = LibraryStore(db:db,positionDefaults:nil)
        let value = try db.cardEntryPracticeSession(ids:[card.id!],allowedIDs:[card.id!],query:all,page:1,generation:store.cardEntryHistory.generation)
        XCTAssertNoThrow(try store.validateCardEntryPractice(value))
        store.fullBackupBusy = true
        XCTAssertThrowsError(try store.validateCardEntryPractice(value)) { XCTAssertEqual($0 as? CardEntryPracticeError,.libraryChanged) }
        store.fullBackupBusy = false;store.cardEntryHistory.clear()
        XCTAssertThrowsError(try store.validateCardEntryPractice(value)) { XCTAssertEqual($0 as? CardEntryPracticeError,.libraryChanged) }
        XCTAssertEqual(try db.card(id:card.id!)?.reps,0)
    }
}
