import XCTest
@testable import KongReviewCore

/// 4.0：写作字数口径——中文逐字、西文按词、标点与标记不计
final class V40WritingCountTests: XCTestCase {
    func testChineseCountsEachCharacterAndIgnoresPunctuation() {
        XCTAssertEqual(WritingCount.count(text: "学而时习之，不亦说乎？"), 9)
        XCTAssertEqual(WritingCount.count(text: "“士”不可以不弘毅。"), 7)
        XCTAssertEqual(WritingCount.count(text: "   \n\t"), 0)
    }

    func testLatinCountsWordsAndKeepsApostrophesAndHyphens() {
        XCTAssertEqual(WritingCount.count(text: "The well-known scholar didn't write every day."), 7)
        XCTAssertEqual(WritingCount.count(text: "a - b"), 2)
        XCTAssertEqual(WritingCount.count(text: "1644 年"), 2, "数字算一个词，汉字逐字")
    }

    func testMixedTextAndHTML() {
        XCTAssertEqual(WritingCount.count(text: "梁启超《清代学术概论》（1920）论 Qing scholarship"), 13)
        XCTAssertEqual(WritingCount.count(html: "<p>按：<strong>经世</strong>致用</p><p>see <em>Elman</em></p>"), 7)
        XCTAssertEqual(WritingCount.count(html: "1 < 2 且 3 > 2"), 5, "不是 HTML 时按纯文字计")
        XCTAssertEqual(WritingCount.count(text: "𠀀𪚥"), 2, "扩展区汉字")
    }

    func testDelta() {
        XCTAssertTrue(WritingCount.delta(from: 10, to: 25) == (15, 0))
        XCTAssertTrue(WritingCount.delta(from: 25, to: 10) == (0, 15))
        XCTAssertTrue(WritingCount.delta(from: 5, to: 5) == (0, 0))
    }
}
