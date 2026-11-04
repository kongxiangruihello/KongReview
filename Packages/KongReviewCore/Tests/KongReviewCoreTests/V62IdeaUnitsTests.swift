import XCTest
@testable import KongReviewCore

/// 6.2：对照要点——切分、加粗优先、繁简归一、写出与否、自评偏高偏低
final class V62IdeaUnitsTests: XCTestCase {
    func testUnitsSplitByPunctuationAndMergeShort() {
        XCTAssertEqual(IdeaUnits.units(from: "学而时习之，不亦说乎？有朋自远方来，不亦乐乎？"),
                       ["学而时习之", "不亦说乎", "有朋自远方来", "不亦乐乎"])
        // “子曰：”这样冒号前的短标签并到后一句（6.2.2）
        XCTAssertEqual(IdeaUnits.units(from: "子曰：学而不思则罔，思而不学则殆。"), ["子曰：学而不思则罔", "思而不学则殆"])
        let units = IdeaUnits.units(from: "子曰：学而不思则罔，思而不学则殆。")
        XCTAssertEqual(units.last, "思而不学则殆")
        XCTAssertTrue(units.first?.contains("学而不思则罔") == true)
        XCTAssertFalse(units.contains("子曰"), "两个字的片段不单算一处")
    }

    /// 6.2.2：冒号前的短标签不单算一处，也不计入比较；文言短分句（不足 4 字）并到相邻一段
    func testLabelsAndShortClauses() {
        let units = IdeaUnits.units(from: "新录示例：士不可以不弘毅，任重而道远。")
        XCTAssertEqual(units, ["新录示例：士不可以不弘毅", "任重而道远"])
        let m = IdeaUnits.match(answer: "士不可以不弘毅", units: units)
        XCTAssertEqual(m.units.map(\.hit), [true, false], "标签“新录示例”不计入比较")
        XCTAssertEqual(IdeaUnits.body(of: "按：旨在重建义理"), "旨在重建义理")
        XCTAssertEqual(IdeaUnits.body(of: "孟子字义疏证：一书"), "孟子字义疏证：一书", "五个字以上不算标签")
        XCTAssertEqual(IdeaUnits.units(from: "戴震以考据为手段。按：旨在重建义理"), ["戴震以考据为手段", "按：旨在重建义理"])
        XCTAssertEqual(IdeaUnits.units(from: "孟子字义疏证：一书即是明证"), ["孟子字义疏证", "一书即是明证"])
        XCTAssertEqual(IdeaUnits.units(from: "三人行，必有我师焉"), ["三人行，必有我师焉"])
        XCTAssertEqual(IdeaUnits.units(from: "然则，何以为士？士尚志"), ["然则，何以为士，士尚志"])
    }

    func testLongTextFallsBackToSentences() {
        let clause = "经世致用之学起于明末清初诸大儒"
        let text = Array(repeating: clause + "，顾炎武黄宗羲王夫之皆以天下为己任。", count: 3).enumerated()
            .map { "\($0.offset)" + $0.element }.joined() + (1...15).map { "第\($0)条细目" }.joined(separator: "，")
        let units = IdeaUnits.units(from: text)
        XCTAssertLessThanOrEqual(units.count, IdeaUnits.maximumUnits)
        XCTAssertTrue(units[0].contains("顾炎武"), "超过上限时按句合并")
    }

    func testMarkedSpansWin() {
        let html = "<p>戴震以<b>考据为手段</b>，旨在<strong>重建义理</strong>，其书即是明证。</p>"
        let marked = IdeaUnits.markedSpans(in: html)
        XCTAssertEqual(marked, ["考据为手段", "重建义理"])
        XCTAssertEqual(IdeaUnits.units(from: "戴震以考据为手段，旨在重建义理，其书即是明证。", marked: marked), ["考据为手段", "重建义理"])
    }

    func testMarkdownMarksAndHeadingsIgnored() {
        XCTAssertEqual(IdeaUnits.markedSpans(in: "## 清代学术\n\n顾炎武主张**经学即理学**，又说==行己有耻=="), ["经学即理学", "行己有耻"])
        XCTAssertEqual(IdeaUnits.markedSpans(in: "<h2>标题</h2><p>没有标出的</p>"), [])
    }

    func testMatchTraditionalAndPartial() {
        let m = IdeaUnits.match(answer: "學而時習之，好像還有朋友從遠方來", standard: "学而时习之，不亦说乎？有朋自远方来，不亦乐乎？")
        XCTAssertEqual(m.total, 4)
        XCTAssertEqual(m.units.map(\.hit), [true, false, true, false], "繁体也算；“朋自远方来”写成“朋友从远方来”过半")
        XCTAssertEqual(m.hits, 2)
        XCTAssertEqual(m.coverage, 0.5)
        XCTAssertEqual(IdeaUnits.match(answer: "", standard: "学而时习之").hits, 0)
        XCTAssertNil(IdeaUnits.match(answer: "随便", units: []).coverage)
    }

    func testLatinWords() {
        let m = IdeaUnits.match(answer: "overconfidence leads to underachievement", standard: "Overconfidence produces underachievement; accurate judgments help retention.")
        XCTAssertEqual(m.units.map(\.hit), [true, false])
    }

    func testVerdict() {
        XCTAssertEqual(IdeaUnits.verdict(.remembered, coverage: 0.25), .over)
        XCTAssertEqual(IdeaUnits.verdict(.remembered, coverage: 0.5), .fair)
        XCTAssertEqual(IdeaUnits.verdict(.forgot, coverage: 0.9), .under)
        XCTAssertEqual(IdeaUnits.verdict(.partly, coverage: 0.0), .fair)
    }
}
