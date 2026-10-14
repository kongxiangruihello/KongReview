import XCTest
@testable import KongReviewCore

final class V17CoreTests: XCTestCase {

    // MARK: 古籍篇章体例

    func testChapterName() {
        XCTAssertEqual(ClassicCitation.chapterName("学而第一"), "学而")
        XCTAssertEqual(ClassicCitation.chapterName("梁惠王上"), "梁惠王上")
        XCTAssertEqual(ClassicCitation.chapterName("逍遥游篇"), "逍遥游")
        XCTAssertEqual(ClassicCitation.chapterName("《项羽本纪》"), "项羽本纪")
        XCTAssertEqual(ClassicCitation.chapterName("第一章"), "第一章")
        XCTAssertEqual(ClassicCitation.chapterName("为政第二"), "为政")
    }

    func testGuessClassicTitle() {
        XCTAssertEqual(ClassicCitation.guessClassicTitle("论语译注"), "论语")
        XCTAssertEqual(ClassicCitation.guessClassicTitle("《庄子今注今译》"), "庄子")
        XCTAssertEqual(ClassicCitation.guessClassicTitle("论语译注解题"), "论语")
        XCTAssertEqual(ClassicCitation.guessClassicTitle("史记"), "史记")
        XCTAssertEqual(ClassicCitation.guessClassicTitle("十三经注疏"), "十三经")
    }

    func testSplitLocation() {
        XCTAssertEqual(ClassicCitation.split("学而第一 · 第3页").chapter, "学而")
        XCTAssertEqual(ClassicCitation.split("学而第一 · 第3页").page, "第3页")
        XCTAssertEqual(ClassicCitation.split("第12页").chapter, nil)
        XCTAssertEqual(ClassicCitation.split("p. 12").page, "p. 12")
        XCTAssertEqual(ClassicCitation.split("卷七 项羽本纪，第300页").chapter, "卷七·项羽本纪")
        XCTAssertEqual(ClassicCitation.split("里仁").chapter, "里仁")
        XCTAssertNil(ClassicCitation.split(nil).chapter)
    }

    func testClassicFootnoteCommentary() {
        var s = Source(title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980", place: "北京")
        s.classicTitle = "论语"
        let h = Highlight(sourceId: 1, text: "学而时习之", location: "学而第一 · 第3页")
        XCTAssertEqual(CitationFormatter.citation(for: h, source: s),
                       "《论语·学而》，杨伯峻：《论语译注》，北京：中华书局，1980年，第3页。")
        XCTAssertEqual(ClassicCitation.short(s, location: h.location), "《论语·学而》")
        // GB/T 不受影响
        XCTAssertTrue(CitationFormatter.citation(for: h, source: s, style: .gbt7714).hasPrefix("杨伯峻.论语译注[M]"))
    }

    func testClassicFootnoteOriginal() {
        var s = Source(title: "史记", author: "（汉）司马迁", publisher: "中华书局", year: "1959", place: "北京")
        s.classicTitle = "史记"
        let h = Highlight(sourceId: 1, text: "力拔山兮", location: "项羽本纪 第333页")
        XCTAssertEqual(CitationFormatter.citation(for: h, source: s),
                       "（汉）司马迁：《史记·项羽本纪》，北京：中华书局，1959年，第333页。")
        var bare = Source(title: "孟子")
        bare.classicTitle = "孟子"
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(sourceId: 1, text: "x", location: "梁惠王上"), source: bare),
                       "《孟子·梁惠王上》。")
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(sourceId: 1, text: "x"), source: bare), "《孟子》。")
    }

    func testNonClassicUnchanged() {
        let s = Source(title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980", place: "北京")
        let h = Highlight(sourceId: 1, text: "x", location: "第3页")
        XCTAssertEqual(CitationFormatter.citation(for: h, source: s), "杨伯峻：《论语译注》，北京：中华书局，1980年，第3页。")
        var blank = s
        blank.classicTitle = "  "
        XCTAssertFalse(blank.isClassic)
    }

    // MARK: 牌组概览

    func testMaturity() {
        var cards: [Card] = []
        cards.append(Card(front: "a"))
        cards.append(Card(front: "b", state: .learning))
        cards.append(Card(front: "c", state: .review, interval: 5))
        cards.append(Card(front: "d", state: .review, interval: 30))
        cards.append(Card(front: "e", state: .review, interval: 21))
        cards.append(Card(front: "f", state: .review, interval: 40, isSuspended: true))
        let m = DeckMaturity(cards)
        XCTAssertEqual(m, DeckMaturity(new: 1, learning: 1, young: 1, mature: 2, suspended: 1))
        XCTAssertEqual(m.active, 5)
        XCTAssertEqual(m.matureRatio!, 0.5, accuracy: 1e-9)
        let f = m.fractions
        XCTAssertEqual(f.new + f.learning + f.young + f.mature, 1, accuracy: 1e-9)
        XCTAssertNil(DeckMaturity([Card(front: "x")]).matureRatio)
        XCTAssertEqual((m + m).mature, 4)
    }

    func testDeckSplitAndMinutes() {
        XCTAssertEqual(DeckOverview.split("论语译注解题::学而第一").parent, "论语译注解题")
        XCTAssertEqual(DeckOverview.split("论语译注解题::学而第一").leaf, "学而第一")
        XCTAssertEqual(DeckOverview.split("A::B::C").parent, "A · B")
        XCTAssertNil(DeckOverview.split("My Flashcard").parent)
        XCTAssertEqual(DeckOverview.estimatedMinutes(.init()), 0)
        XCTAssertEqual(DeckOverview.estimatedMinutes(.init(new: 1)), 1)
        XCTAssertEqual(DeckOverview.estimatedMinutes(.init(new: 15, learning: 0, review: 200)), 32)
        let i = DeckOverview.colorIndex("论语::学而", count: 8)
        XCTAssertEqual(i, DeckOverview.colorIndex("论语::为政", count: 8))
        XCTAssertTrue((0..<8).contains(i))
    }

    func testChineseDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        XCTAssertEqual(DeckOverview.chineseDate(d, calendar: cal), "十月十四日 · 星期三")
        let d2 = cal.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 9))!
        XCTAssertEqual(DeckOverview.chineseDate(d2, calendar: cal), "十二月三十日 · 星期三")
    }
}
