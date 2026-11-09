import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.3.2：日课上的记忆卡、摘录用原来的编辑窗口；保存后按 id 重取，卷面换成改过的内容
final class V632OriginalEditTests: XCTestCase {
    func testRefreshAfterOriginalEditor() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            var card = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎"))
            var h = try db.save(Highlight(text: "温故而知新", location: "为政"))
            let qc = ExamQuestion.card(card), qh = ExamQuestion.highlight(h, .source)

            // 没改：重取的与原来相同
            XCTAssertEqual(store.examRefreshed(qc), qc)
            XCTAssertEqual(store.examRefreshed(qh), qh)

            // 在别处（原来的编辑窗口）改过并存下
            card.back = "<b>不亦说乎</b>"; card = try db.save(card)
            h.note = "朱注：温，寻绎也"; h = try db.save(h)
            guard case .card(let c)? = store.examRefreshed(qc) else { return XCTFail() }
            XCTAssertEqual(c.back, "<b>不亦说乎</b>")
            XCTAssertEqual(store.examRefreshed(qc)?.key, qc.key, "内容变了、排程没变：仍是同一道题，卷面不重置")
            guard case .highlight(let fresh, let mode)? = store.examRefreshed(qh) else { return XCTFail() }
            XCTAssertEqual(fresh.note, "朱注：温，寻绎也")
            XCTAssertEqual(mode, .source, "出题方式不变")

            // 删去了：不动卷面
            try db.moveToTrash(h)
            XCTAssertNil(store.examRefreshed(qh))
        }
    }
}
