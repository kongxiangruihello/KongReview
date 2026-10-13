import XCTest
@testable import KongReviewCore

final class LiquidTextTests: XCTestCase {
    /// 按 LiquidText 实际导出的 document.xml 结构缩写的样本
    static func para(_ inner: String, indent: Int = 1200) -> String {
        "<w:p><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"\(indent)\"/></w:pPr>\(inner)</w:p>"
    }
    static func run(_ t: String) -> String { "<w:r><w:t xml:space=\"preserve\">\(t)</w:t></w:r>" }
    static let cite = "<w:r><w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\"></w:t><w:br/><w:t xml:space=\"preserve\">(革命造反年代：上海文革运动史稿 全二册(李逊) , p.%@)</w:t></w:r>"

    static var sampleXML: String {
        let label = "<w:r><w:t>Excerpt</w:t></w:r><w:r><w:t>:</w:t><w:tab/></w:r>"
        func excerpt(_ body: String, _ page: String) -> String {
            para(label + run(body) + String(format: cite, page))
        }
        let image = para("<w:r><w:t>Excerpt</w:t></w:r><w:r><w:t>:</w:t><w:tab/><w:t>[Image]</w:t><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed=\"rId10\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>" + String(format: cite, "17"))
        let comment = para("<w:r><w:t>Comment</w:t></w:r><w:r><w:t>:</w:t><w:tab/></w:r>" + run("寫作組是關鍵") + String(format: cite, "14"), indent: 2400)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="r" xmlns:wp="wp" xmlns:a="a" xmlns:pic="pic"><w:body>
        \(para(run("Notes in ‘革命造反年代：上海文革运动史稿 全二册(李逊) ’"), indent: 0))
        \(para("", indent: 0))
        \(para(run("Notes in Workspace:"), indent: 0))
        \(excerpt("除了紅衛兵和工 人造反派，上海還有一支 以張春橋和姚文元為首的上海市委寫作組", "14"))
        \(comment)
        \(para(""))
        \(excerpt("除了紅衛兵和工 人造反派，上海還有一支 以張春橋和姚文元為首的上海市委寫作組", "14"))
        \(image)
        \(excerpt("6月24 日上午，毛澤東召集會議。 4月16日， 《北京日報》 with English words", "93"))
        </w:body></w:document>
        """
    }

    func testParsesDocxStructure() throws {
        let blocks = try LiquidTextImporter.blocks(documentXML: Data(Self.sampleXML.utf8))
        let parsed = LiquidTextImporter.parse(blocks)
        XCTAssertEqual(parsed.workspace, "革命造反年代：上海文革运动史稿 全二册(李逊)")
        XCTAssertEqual(parsed.items.count, 4)
        let first = parsed.items[0]
        XCTAssertEqual(first.kind, .excerpt)
        XCTAssertEqual(first.page, "14")
        XCTAssertEqual(first.document, "革命造反年代：上海文革运动史稿 全二册(李逊)")
        XCTAssertEqual(first.text, "除了紅衛兵和工人造反派，上海還有一支以張春橋和姚文元為首的上海市委寫作組")
        XCTAssertEqual(first.comments, ["寫作組是關鍵"])
        XCTAssertEqual(parsed.items[2].images, ["rId10"])
        XCTAssertEqual(parsed.items[2].text, "")
        XCTAssertEqual(parsed.items[3].text, "6月24日上午，毛澤東召集會議。4月16日，《北京日報》 with English words")
    }

    func testConvertsToImportResult() throws {
        let parsed = LiquidTextImporter.parse(try LiquidTextImporter.blocks(documentXML: Data(Self.sampleXML.utf8)))
        let r = LiquidTextImporter.result(parsed, fallbackTitle: "x") { rid, loc in
            "![\(loc ?? "")](kr-media://media/\(rid).jpeg)"
        }
        XCTAssertEqual(r.sources.count, 1)
        XCTAssertEqual(r.sources[0].title, "革命造反年代：上海文革运动史稿 全二册")
        XCTAssertEqual(r.sources[0].author, "李逊")
        XCTAssertEqual(r.sources[0].kind, .book)
        XCTAssertEqual(r.highlightCount, 3, "文件内重复的摘录只留一条")
        XCTAssertEqual(r.skippedRows, 1)
        XCTAssertEqual(r.sources[0].highlights[0].location, "第 14 页")
        XCTAssertEqual(r.sources[0].highlights[0].note, "寫作組是關鍵")
        XCTAssertEqual(r.sources[0].highlights[1].text, "![第 17 页](kr-media://media/rId10.jpeg)")
    }

    func testRelationships() {
        let xml = #"<?xml version="1.0"?><Relationships xmlns="x"><Relationship Id="rId10" Type="t" Target="media/image10.jpeg"/></Relationships>"#
        XCTAssertEqual(LiquidTextImporter.relationships(Data(xml.utf8)), ["rId10": "media/image10.jpeg"])
    }

    func testPlainText() {
        let text = """
        Notes in ‘论语集释 (程树德) ’

        Excerpt:\t學而時習之，不亦說 乎
        (论语集释 (程树德) , p.1)
        Comment:\t时习：按时温习
        (论语集释 (程树德) , p.1)

        Excerpt:\t有朋自遠方來
        (另一本书.pdf , p.3-4)
        """
        let parsed = LiquidTextImporter.parse(LiquidTextImporter.blocks(plainText: text))
        XCTAssertEqual(parsed.workspace, "论语集释 (程树德)")
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertEqual(parsed.items[0].text, "學而時習之，不亦說乎")
        XCTAssertEqual(parsed.items[0].comments, ["时习：按时温习"])
        let r = LiquidTextImporter.result(parsed, fallbackTitle: "x")
        XCTAssertEqual(r.sources.map(\.title), ["论语集释", "另一本书"])
        XCTAssertEqual(r.sources[0].author, "程树德")
        XCTAssertEqual(r.sources[1].highlights[0].location, "第 3-4 页")
    }

    func testSplitAuthorKeepsVolumeInfo() {
        XCTAssertEqual(LiquidTextImporter.splitAuthor("严复集 (第一册)").1, "")
        XCTAssertEqual(LiquidTextImporter.splitAuthor("Analects (2003)").1, "")
        XCTAssertEqual(LiquidTextImporter.splitAuthor("中国思想史（葛兆光）").0, "中国思想史")
    }

    func testStandaloneCommentBecomesTaggedItem() {
        let parsed = LiquidTextImporter.parse([LiquidTextImporter.Block(text: "Comment:\t整体思路：名份\n(书 , p.9)")])
        let r = LiquidTextImporter.result(parsed, fallbackTitle: "x")
        XCTAssertEqual(r.sources.first?.highlights.first?.tags, ["批注"])
    }
}

final class KrMediaReferenceTests: XCTestCase {
    func testFindsMarkdownImages() {
        let t = "文字\n\n![第 17 页](kr-media://media/liquidtext-ab12.jpeg) 和 <img src=\"kr-media://media/x%20y.png\">"
        XCTAssertEqual(AnkiPackage.krMediaReferences(in: t), ["liquidtext-ab12.jpeg", "x%20y.png", "x y.png"])
    }
}
