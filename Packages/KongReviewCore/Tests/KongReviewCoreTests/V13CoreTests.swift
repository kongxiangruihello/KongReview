import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import KongReviewCore

final class V13CoreTests: XCTestCase {
    var pieces: [NotebookPiece] {
        [
            .init(.heading("一、學而")),
            .init(.text("孔子論學，**重在時習**。下面兩條可以對讀：\n\n- 其一\n- 其二")),
            .init(.quote("子曰：學而時習之，不亦說乎？", cite: "楊伯峻：《論語譯注》，北京：中華書局，1980年，第1頁。")),
            .init(.comment("“習”是溫習，也有實習之意。")),
            .init(.text("過渡文字。")),
            .init(.quote("溫故而知新，可以為師矣。", cite: "")),
            .init(.quote("見賢思齊焉", cite: "《論語·里仁》。")),
        ]
    }

    func testSpans() {
        let s = NotebookExporter.spans("普通**粗體***斜*與~~刪~~，[鏈接](https://a.b)、snake_case_name")
        XCTAssertEqual(s.map(\.text).joined(), "普通粗體斜與刪，鏈接、snake_case_name")
        XCTAssertTrue(s.contains(.init("粗體", bold: true)))
        XCTAssertTrue(s.contains(.init("斜", italic: true)))
        XCTAssertTrue(s.contains(.init("刪", strike: true)))
    }

    func testParagraphs() {
        let p = NotebookExporter.paragraphs(fromMarkdown: "## 小標題\n\n第一段\n第一段續\n\n> 引一\n> 引二\n\n1. 甲\n- 乙")
        XCTAssertEqual(p.count, 5)
        XCTAssertEqual(p[0].headingLevel, 2)
        XCTAssertEqual(p[1].spans.map(\.text).joined(), "第一段第一段續")
        XCTAssertTrue(p[2].isQuote)
        XCTAssertEqual(p[3].listMarker, "1.")
        XCTAssertEqual(p[4].listMarker, "•")
    }

    func testMarkdownExport() {
        let md = NotebookExporter.markdown(title: "論語專題", pieces: pieces, options: .init(bibliography: ["[1] 楊伯峻.論語譯注[M].北京:中華書局,1980."]))
        XCTAssertTrue(md.hasPrefix("# 論語專題\n\n## 一、學而"))
        XCTAssertTrue(md.contains("> 子曰：學而時習之，不亦說乎？[^1]"))
        XCTAssertTrue(md.contains("> 見賢思齊焉[^2]"))
        XCTAssertTrue(md.contains("> 溫故而知新，可以為師矣。\n"))
        XCTAssertTrue(md.contains("[^1]: 楊伯峻：《論語譯注》"))
        XCTAssertTrue(md.contains("## 参考文献"))
        XCTAssertTrue(md.contains("**按：**“習”是溫習"))
        let inline = NotebookExporter.markdown(title: "x", pieces: pieces, options: .init(footnotes: false))
        XCTAssertTrue(inline.contains("不亦說乎？（楊伯峻："))
        XCTAssertFalse(inline.contains("[^"))
    }

    func testRTFHasFootnotes() {
        let rtf = NotebookExporter.rtf(title: "論語專題", pieces: pieces)
        XCTAssertEqual(rtf.components(separatedBy: "\\footnote").count - 1, 2)
        XCTAssertTrue(rtf.allSatisfy { $0.isASCII })
    }

    func testDocxFiles() throws {
        let files = NotebookDocx.files(title: "論語專題 <&>", pieces: pieces, options: .init(bibliography: ["[1] 楊伯峻.論語譯注[M]."]))
        let doc = try XCTUnwrap(files["word/document.xml"])
        XCTAssertEqual(doc.components(separatedBy: "<w:footnoteReference").count - 1, 2)
        XCTAssertTrue(doc.contains("論語專題 &lt;&amp;&gt;"))
        XCTAssertTrue(doc.contains(" TOC \\o "))
        XCTAssertTrue(doc.contains("w:pStyle w:val=\"Comment\""))
        XCTAssertTrue(doc.contains("headerReference"))
        XCTAssertNotNil(files["word/header1.xml"]); XCTAssertNotNil(files["word/footer1.xml"])
        let plain = NotebookDocx.files(title: "x", pieces: [.init(.text("無標題"))], options: .init(toc: true, headerFooter: false))
        XCTAssertFalse(plain["word/document.xml"]!.contains("TOC"), "没有小标题时不加目录")
        XCTAssertFalse(plain["word/document.xml"]!.contains("headerReference"))
        let fn = try XCTUnwrap(files["word/footnotes.xml"])
        XCTAssertTrue(fn.contains("w:id=\"2\""))
        for (_, xml) in files { XCTAssertNoThrow(try XMLDocumentCheck.parse(xml)) }
        if let dir = ProcessInfo.processInfo.environment["KR_DOCX_DIR"] {
            for (path, xml) in files {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try xml.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func testWeeklyDigestWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-10-14 是星期三
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        let w = WeeklyDigest.previousWeek(of: now, calendar: cal)
        XCTAssertEqual(WeeklyDigest.dayKey(w.start, calendar: cal), "2026-10-05")
        XCTAssertEqual(WeeklyDigest.dayKey(w.end, calendar: cal), "2026-10-12")
        // 周日仍算本周
        let sunday = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23))!
        XCTAssertEqual(WeeklyDigest.dayKey(WeeklyDigest.previousWeek(of: sunday, calendar: cal).start, calendar: cal), "2026-10-05")
        var d = WeeklyDigest(start: w.start, end: w.end)
        XCTAssertEqual(d.rangeLabel(calendar: cal), "10月5日—11日")
        d.highlightsReviewed = 40; d.cardsReviewed = 100; d.cardsCorrect = 87; d.activeDays = 6
        XCTAssertEqual(d.notificationBody, "回顾摘录 40 条，记忆卡 100 次（答对 87%），6 天有回顾。")
        XCTAssertEqual(WeeklyDigest.pick([5, 3, 9], weekKey: d.key), WeeklyDigest.pick([9, 5, 3], weekKey: d.key))
        XCTAssertNil(WeeklyDigest.pick([], weekKey: "x"))
    }

    func testBlockPosition() {
        XCTAssertEqual(NotebookBlock.position(between: 1, and: 2), 1.5)
        XCTAssertEqual(NotebookBlock.position(between: 3, and: nil), 4)
        XCTAssertEqual(NotebookBlock.position(between: nil, and: 1), 0)
        XCTAssertEqual(NotebookBlock.position(between: nil, and: nil), 1)
    }
}

/// 只检查 XML 是否良构
enum XMLDocumentCheck {
    final class D: NSObject, XMLParserDelegate {}
    static func parse(_ s: String) throws {
        let p = XMLParser(data: Data(s.utf8))
        let d = D(); p.delegate = d
        if !p.parse() { throw p.parserError ?? NSError(domain: "xml", code: 1) }
    }
}

final class V14CoreTests: XCTestCase {
    func testPptx() throws {
        let long = String(repeating: "子曰：學而時習之，不亦說乎？有朋自遠方來，不亦樂乎？人不知而不慍，不亦君子乎？", count: 16)
        let pieces: [NotebookPiece] = [
            .init(.heading("一、學而")),
            .init(.quote("子曰：**學而時習之**，不亦說乎？", cite: "楊伯峻：《論語譯注》，北京：中華書局，1980年，第1頁。")),
            .init(.comment("“習”是溫習，也有實習之意。")),
            .init(.text("過渡：下面看一段較長的原文。\n\n- 其一\n- 其二")),
            .init(.quote(long, cite: "《論語·學而》。")),
            .init(.text("## 二、為政")),
            .init(.quote("溫故而知新，可以為師矣。", cite: "")),
        ]
        let files = NotebookPptx.files(title: "論語專題 & 講稿", pieces: pieces,
                                       options: .init(bibliography: ["[1] 楊伯峻.論語譯注[M].北京:中華書局,1980."]))
        let slides = files.keys.filter { $0.hasPrefix("ppt/slides/slide") }
        // 封面 + 章節 + 引文 + 正文 + 長引文（拆 2 頁以上）+ 章節 + 引文 + 參考文獻
        XCTAssertGreaterThanOrEqual(slides.count, 9)
        for (_, xml) in files { XCTAssertNoThrow(try XMLDocumentCheck.parse(xml)) }
        // 1.5：按语进演讲者备注，不印在幻灯片上
        XCTAssertFalse(files["ppt/slides/slide3.xml"]!.contains("按："))
        XCTAssertTrue(files["ppt/slides/_rels/slide3.xml.rels"]!.contains("notesSlide1.xml"))
        XCTAssertTrue(files["ppt/notesSlides/notesSlide1.xml"]!.contains("“習”是溫習"))
        XCTAssertTrue(files["ppt/presentation.xml"]!.contains("<p:notesMasterIdLst>"))
        XCTAssertNotNil(files["ppt/notesMasters/notesMaster1.xml"])
        XCTAssertTrue(files["ppt/presentation.xml"]!.contains("<p:sldId id=\"256\" r:id=\"rId2\"/>"))
        if let dir = ProcessInfo.processInfo.environment["KR_PPTX_DIR"] {
            for (path, xml) in files {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try xml.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

final class V15CoreTests: XCTestCase {
    func testDuplicateKeyAndGroups() {
        XCTAssertEqual(DuplicateFinder.key("除了紅衛兵和工 人造反派，**上海**還有"), DuplicateFinder.key("除了红卫兵和工人造反派上海还有"))
        let items: [DuplicateFinder.Item] = [
            .init(id: 1, text: "除了紅衛兵和工人造反派，上海還有一支文革力量", sourceId: 1),
            .init(id: 2, text: "除了紅衛兵和工 人造反派，上海還有一支文革力量", sourceId: 1),
            .init(id: 3, text: "除了紅衛兵和工人造反派，上海還有一支文革力量：寫作組", sourceId: 1),
            .init(id: 4, text: "完全不同的一句話，講的是別的事情", sourceId: 1),
            .init(id: 5, text: "除了红卫兵和工人造反派，上海还有一支文革力量", sourceId: 2),
            .init(id: 6, text: "朱維錚", sourceId: 1),
            .init(id: 7, text: "朱維錚", sourceId: 1),
            .init(id: 8, text: "完全不同的一句話，講的是別的事", sourceId: 3),
        ]
        let g = DuplicateFinder.groups(items)
        // 1、2、5 完全相同（跨出处也算）；3 与之相似（同出处、多几个字）→ 并成一组；6、7 短但完全相同也算
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.first { $0.ids.contains(1) }?.ids, [1, 2, 3, 5])
        XCTAssertEqual(g.first { $0.ids.contains(1) }?.exact, false)
        XCTAssertEqual(g.first { $0.ids.contains(6) }?.exact, true)
        // 4 与 8 不同出处、只是相似：不算
        XCTAssertNil(g.first { $0.ids.contains(4) })
        // 忽略过的组不再出现
        XCTAssertEqual(DuplicateFinder.groups(items, ignored: ["6-7"]).count, 1)
    }

    func testMergedFields() {
        let now = Date()
        var a = Highlight(sourceId: 1, text: "甲", note: "按一", location: nil, tags: ["儒"], createdAt: now)
        a.surfacedCount = 2
        var b = Highlight(sourceId: 1, text: "甲", translation: "譯", note: "按二", location: "第 3 页", tags: ["孔", "儒"], isFavorite: true,
                          createdAt: now.addingTimeInterval(-100))
        b.surfacedCount = 3; b.frequency = 1
        let m = DuplicateFinder.merged(keeper: a, others: [b])
        XCTAssertEqual(m.note, "按一\n\n按二")
        XCTAssertEqual(m.translation, "譯")
        XCTAssertEqual(m.location, "第 3 页")
        XCTAssertEqual(m.tags, ["儒", "孔"])
        XCTAssertTrue(m.isFavorite)
        XCTAssertEqual(m.surfacedCount, 5)
        XCTAssertEqual(m.frequency, 1)
        XCTAssertEqual(m.createdAt, b.createdAt)
    }
}
