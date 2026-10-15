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

final class V18CoreTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))! }

    func testJuanCitation() {
        XCTAssertEqual(ClassicCitation.juanName("卷七"), "卷七")
        XCTAssertEqual(ClassicCitation.juanName("卷一百二十九"), "卷一百二十九")
        XCTAssertEqual(ClassicCitation.juanName("卷三上"), "卷三上")
        XCTAssertEqual(ClassicCitation.juanName("第七卷"), "卷七")
        XCTAssertNil(ClassicCitation.juanName("卷首语"))
        XCTAssertNil(ClassicCitation.juanName("学而"))
        var s = Source(title: "史记", author: "（汉）司马迁", publisher: "中华书局", year: "1959", place: "北京")
        s.classicTitle = "史记"
        XCTAssertEqual(CitationFormatter.citation(for: Highlight(sourceId: 1, text: "x", location: "卷七 项羽本纪 第333页"), source: s),
                       "（汉）司马迁：《史记》卷七《项羽本纪》，北京：中华书局，1959年，第333页。")
        XCTAssertEqual(ClassicCitation.short(s, location: "卷一三〇"), "《史记》卷一三〇")
        XCTAssertEqual(ClassicCitation.short(s, location: "项羽本纪"), "《史记·项羽本纪》")
        XCTAssertEqual(ClassicCitation.presetAuthor("《史记》"), "（汉）司马迁")
        XCTAssertNil(ClassicCitation.presetAuthor("论语"))
        XCTAssertNil(ClassicCitation.presetAuthor("红楼梦"))
    }

    func testHeatmapWeeks() {
        // 2026-10-14 是星期三
        let w = ReviewHeatmap.weeks(end: date(2026, 10, 14), count: 3, calendar: cal)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[2].compactMap { $0 }.count, 3, "本周只到星期三")
        XCTAssertEqual(ReviewHeatmap.dayKey(w[2][0]!, calendar: cal), "2026-10-12")
        XCTAssertEqual(ReviewHeatmap.dayKey(w[0][0]!, calendar: cal), "2026-09-28")
        let labels = ReviewHeatmap.monthLabels(w, calendar: cal)
        XCTAssertEqual(labels[0], "九月")
        XCTAssertEqual(labels[1], "十月")
        XCTAssertNil(labels[2])
    }

    func testHeatmapLevelAndStreak() {
        XCTAssertEqual(ReviewHeatmap.level(0, max: 10), 0)
        XCTAssertEqual(ReviewHeatmap.level(1, max: 10), 1)
        XCTAssertEqual(ReviewHeatmap.level(6, max: 10), 3)
        XCTAssertEqual(ReviewHeatmap.level(10, max: 10), 4)
        let days: Set<String> = ["2026-10-13", "2026-10-12", "2026-10-11", "2026-10-09"]
        XCTAssertEqual(ReviewHeatmap.streak(days, today: date(2026, 10, 14), calendar: cal), 3)
        XCTAssertEqual(ReviewHeatmap.streak(days.union(["2026-10-14"]), today: date(2026, 10, 14), calendar: cal), 4)
        XCTAssertEqual(ReviewHeatmap.streak(days, today: date(2026, 10, 16), calendar: cal), 0)
    }
}

final class V19CoreTests: XCTestCase {
    func testCitationCheck() {
        var shiji = Source(id: 1, title: "史记", author: "（汉）司马迁", publisher: "中华书局", year: "1959", place: "北京")
        shiji.classicTitle = "史记"
        let lunyuBook = Source(id: 2, title: "论语译注", author: "杨伯峻")       // 缺出版者、年份
        var lunyu = Source(id: 3, title: "论语")
        lunyu.classicTitle = "论语"                                           // 直接引原典，不要求页码
        let web = Source(id: 4, title: "某网页", kind: .web)
        func h(_ id: Int64, _ loc: String?) -> Highlight { Highlight(id: id, sourceId: 1, text: "x", location: loc) }
        let items: [CitationCheck.Item] = [
            .init(highlight: h(1, "卷七 项羽本纪 第300页"), source: shiji),
            .init(highlight: h(2, "卷八 高祖本纪 第341页"), source: shiji),
            .init(highlight: h(3, "第九卷 吕太后本纪 第395页"), source: shiji),   // 写法不统一
            .init(highlight: h(4, "第400页"), source: shiji),                    // 缺篇名
            .init(highlight: h(5, "学而第一"), source: lunyuBook),               // 缺页码
            .init(highlight: h(6, "第3页"), source: lunyuBook),
            .init(highlight: h(7, "学而"), source: lunyu),
            .init(highlight: h(8, nil), source: lunyu),                          // 缺篇名
            .init(highlight: h(9, nil), source: web),
            .init(highlight: h(10, nil), source: nil),                           // 没有出处
            .init(highlight: h(1, "重复"), source: shiji),                        // 重复的 id 跳过
        ]
        let issues = CitationCheck.check(items)
        func kinds(_ id: Int64) -> [CitationCheck.Kind] { issues.filter { $0.highlightId == id }.map(\.kind) }
        XCTAssertEqual(kinds(1), [])
        XCTAssertEqual(kinds(3), [.juanStyle])
        XCTAssertEqual(kinds(4), [.noChapter])
        XCTAssertEqual(kinds(5), [.noPage])
        XCTAssertEqual(kinds(6), [])
        XCTAssertEqual(kinds(7), [])
        XCTAssertEqual(kinds(8), [.noChapter])
        XCTAssertEqual(kinds(9), [])
        XCTAssertEqual(kinds(10), [.noSource])
        let src = issues.filter { $0.kind == .sourceInfo }
        XCTAssertEqual(src.count, 1)
        XCTAssertEqual(src.first?.sourceId, 2)
        XCTAssertTrue(src.first?.message.contains("出版者、年份") ?? false)
        XCTAssertTrue(issues.first { $0.kind == .juanStyle }?.message.contains("“卷七”") ?? false)
    }

    func testDailyCard() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8))!
        XCTAssertEqual(DailyCard.title(d, calendar: cal), "日课 · 十月十五日 · 星期四")
        let body = DailyCard.body(highlights: 10, cards: .init(new: 5, learning: 0, review: 30),
                                  yesterday: (12, 34), streak: 6)
        XCTAssertEqual(body, "今天：摘录 10 条，记忆卡 35 张（新 5 · 复习 30），约 9 分钟\n昨天看了 12 条摘录、复习 34 次记忆卡，已连续 6 天。")
        XCTAssertEqual(DailyCard.body(highlights: 0, cards: .init(), yesterday: (0, 0), streak: 0),
                       "今天没有到期的功课，翻几条旧摘录吧。\n昨天没有回顾。")
        XCTAssertEqual(DailyCard.body(highlights: 3, cards: .init(review: 2), yesterday: nil, streak: 0),
                       "今天：摘录 3 条，记忆卡 2 张，约 1 分钟")
    }
}

final class V19TieTests: XCTestCase {
    func testJuanTiePrefersHanzi() {
        var s = Source(id: 1, title: "史记", publisher: "中华书局", year: "1959")
        s.classicTitle = "史记"
        let items: [CitationCheck.Item] = [
            .init(highlight: Highlight(id: 1, sourceId: 1, text: "a", location: "卷7 项羽本纪 第1页"), source: s),
            .init(highlight: Highlight(id: 2, sourceId: 1, text: "b", location: "卷八 高祖本纪 第2页"), source: s),
        ]
        let issues = CitationCheck.check(items)
        XCTAssertEqual(issues.map(\.highlightId), [1])
        XCTAssertTrue(issues[0].message.contains("多数写作“卷七”"))
    }
}

final class V20CoreTests: XCTestCase {
    func testChapterGrouping() {
        let hs = [
            Highlight(id: 1, sourceId: 1, text: "a", location: "学而第一 · 第1页"),
            Highlight(id: 2, sourceId: 1, text: "b", location: "为政第二 · 第12页"),
            Highlight(id: 3, sourceId: 1, text: "c", location: "学而篇 第3页"),
            Highlight(id: 4, sourceId: 1, text: "d", location: "第40页"),
            Highlight(id: 5, sourceId: 1, text: "e", location: "卷七 项羽本纪"),
            Highlight(id: 6, sourceId: 1, text: "f", location: "卷八"),
        ]
        let g = ClassicCitation.groupByChapter(hs)
        XCTAssertEqual(g.map(\.name), ["学而", "为政", "项羽本纪", "卷八"])
        XCTAssertEqual(g[0].highlights.compactMap(\.id), [1, 3])
        XCTAssertNil(ClassicCitation.chapterKey("第40页"))
    }

    func testAddingPage() {
        XCTAssertEqual(CitationCheck.pageText("12"), "第12页")
        XCTAssertEqual(CitationCheck.pageText("12-15"), "第12—15页")
        XCTAssertEqual(CitationCheck.pageText("第3页"), "第3页")
        XCTAssertEqual(CitationCheck.pageText("p. 7"), "p. 7")
        XCTAssertNil(CitationCheck.pageText("  "))
        XCTAssertEqual(CitationCheck.addingPage("3", to: "学而第一"), "学而第一 · 第3页")
        XCTAssertEqual(CitationCheck.addingPage("3", to: nil), "第3页")
        XCTAssertNil(CitationCheck.addingPage("", to: "x"))
        // 补上之后核对通过
        let s = Source(id: 1, title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980")
        let h = Highlight(id: 1, sourceId: 1, text: "x", location: CitationCheck.addingPage("3", to: "学而第一"))
        XCTAssertTrue(CitationCheck.check([.init(highlight: h, source: s)]).isEmpty)
    }
}


final class V20PageTests: XCTestCase {
    func testRomanPage() {
        XCTAssertEqual(CitationCheck.pageText("xii"), "第xii页")
        XCTAssertEqual(ClassicCitation.components(CitationCheck.addingPage("xii", to: "学而第一")).chapters, ["学而"])
    }
}

final class V21CoreTests: XCTestCase {
    func testEditionLocation() {
        XCTAssertEqual(ClassicCitation.withoutPage("学而第一 · 第3页"), "学而第一")
        XCTAssertEqual(ClassicCitation.withoutPage("卷七 项羽本纪 第300页"), "卷七 项羽本纪")
        XCTAssertNil(ClassicCitation.withoutPage("第3页"))
        XCTAssertEqual(ClassicCitation.location("学而第一 · 第3页", withPage: "5"), "学而第一 · 第5页")
        XCTAssertEqual(ClassicCitation.location("第3页", withPage: "8"), "第8页")
        XCTAssertNil(ClassicCitation.location("学而", withPage: " "))
    }

    func testChapterProgress() {
        var a = Highlight(id: 1, text: "a", location: "学而 第1页"); a.surfacedCount = 2
        let b = Highlight(id: 2, text: "b", location: "学而 第2页")
        let c = Highlight(id: 3, text: "c", location: "为政 第9页")
        let p = ChapterProgress.compute(ClassicCitation.groupByChapter([a, b, c]), carded: [2, 3])
        XCTAssertEqual(p, [ChapterProgress(name: "学而", total: 2, reviewed: 1, withCards: 1),
                           ChapterProgress(name: "为政", total: 1, reviewed: 0, withCards: 1)])
        XCTAssertEqual(p[0].summary, "2 条 · 回顾 1 · 卡 1")
        XCTAssertEqual(p[0].reviewedRatio, 0.5)
    }
}

final class V22CoreTests: XCTestCase {
    func testCellsAndRows() {
        let csv = "篇名,杨本页码,集释页码\n学而第一,1,3\n学而,\"3-5\",第12页\n为政,11,60\n,,\n"
        let rows = EditionPageImport.rows(EditionPageImport.cells(fromText: csv))
        XCTAssertEqual(rows, [
            .init(chapter: "学而", original: 1...1, edition: "3"),
            .init(chapter: "学而", original: 3...5, edition: "第12页"),
            .init(chapter: "为政", original: 11...11, edition: "60"),
        ])
        let tsv = "1\t3\n2\t4"
        XCTAssertEqual(EditionPageImport.rows(EditionPageImport.cells(fromText: tsv)).map(\.edition), ["3", "4"])
    }

    func testMatch() {
        let rows: [EditionPageImport.Row] = [
            .init(chapter: "学而", original: 3...3, edition: "12"),
            .init(chapter: "为政", original: 3...3, edition: "50"),
            .init(chapter: nil, original: 7...9, edition: "70"),
        ]
        let hs = [
            Highlight(id: 1, text: "a", location: "学而第一 · 第3页"),
            Highlight(id: 2, text: "b", location: "为政第二 第3页"),
            Highlight(id: 3, text: "c", location: "第8页"),
            Highlight(id: 4, text: "d", location: "第99页"),
            Highlight(id: 5, text: "e", location: "学而"),
        ]
        let r = EditionPageImport.match(hs, rows: rows)
        XCTAssertEqual(r.matches, [.init(highlightId: 1, page: "12"), .init(highlightId: 2, page: "50"), .init(highlightId: 3, page: "70")])
        XCTAssertEqual(r.unmatched, [4])
        XCTAssertEqual(r.noPage, [5])
    }

    func testXLSX() {
        let shared = """
        <?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>篇名</t></si><si><t>原页</t></si><si><t>学而</t></si><si><r><t>新</t></r><r><t>页</t></r></si></sst>
        """.data(using: .utf8)!
        let sheet = """
        <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>3</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3</v></c><c r="C2"><v>12.0</v></c></row>
        <row r="3"><c r="B3"><v>4</v></c><c r="C3" t="inlineStr"><is><t>13</t></is></c></row>
        </sheetData></worksheet>
        """.data(using: .utf8)!
        let cells = EditionPageImport.cells(sheetXML: sheet, sharedStringsXML: shared)
        XCTAssertEqual(cells, [["篇名", "原页", "新页"], ["学而", "3", "12"], ["", "4", "13"]])
        XCTAssertEqual(EditionPageImport.rows(cells).count, 2)
    }
}

final class V22ExtraColumnTests: XCTestCase {
    func testExtraNoteColumn() {
        let rows = EditionPageImport.rows(EditionPageImport.cells(fromText: "原页码,该版页码,备注\n3,15,\n4,16,见注\n"))
        XCTAssertEqual(rows.map(\.edition), ["15", "16"])
        XCTAssertEqual(rows.map(\.chapter), [nil, nil])
    }
}
