import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V34GrowthPracticeTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c }
    private func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from:.init(year:2026,month:10,day:day,hour:hour))! }
    func testQuestionSolveRequiresAnswerAndReopeningPreservesAnswer() async throws {
        let db = try AppDatabase(DatabaseQueue()), n = try db.createNotebook(title:"专题")
        let q = try db.createQuestion(title:"为什么？",scopes:[(.notebook,n.id!)],now:date(18))
        XCTAssertThrowsError(try db.setQuestionStatus(id:q.id!,.solved),"没有解答不能标为解决")
        let long = String(repeating:"充分解释",count:2000)
        try db.saveQuestion(id:q.id!,title:"为什么？",detail:"",answer:long,now:date(18,12))
        try db.setQuestionStatus(id:q.id!,.solved,now:date(18,12))
        XCTAssertThrowsError(try db.saveQuestion(id:q.id!,title:"为什么？",detail:"",answer:" "),"已解决的问题不能清空解答")
        try db.setQuestionStatus(id:q.id!,.lead)
        let pending = try await db.questionPage(QuestionFilter(state:.unsolved,notebookID:n.id!)); XCTAssertEqual(pending.total,1)
        let reopened = try XCTUnwrap(try db.question(id:q.id!)); XCTAssertEqual(reopened.answer,long); XCTAssertNil(reopened.solvedAt)
        XCTAssertThrowsError(try db.createQuestion(title:" \n "))
        XCTAssertThrowsError(try db.saveQuestion(id:q.id!,title:"",detail:"",answer:""))
    }
}
