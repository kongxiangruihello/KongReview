import XCTest
@testable import KongReviewCore

/// 4.1.2：札记块导出、链接转文字、札记写成 Obsidian Markdown
final class V412NotesCoreTests: XCTestCase {
    func testEssayPieceFootnotesInMarkdownAndHTML() {
        let pieces = [NotebookPiece(.quote("士不可以不弘毅", cite: "《论语·泰伯》")),
                      NotebookPiece(.essay("<p>第一段</p><p>弘言其量，毅言其守</p>", cites: ["参见《论语·泰伯》", "参见《孟子·滕文公下》"]))]
        let md = NotebookExporter.markdown(title: "何以为士", pieces: pieces)
        XCTAssertTrue(md.contains("弘言其量，毅言其守[^2][^3]"), "脚注接在札记最后一段末尾，编号与摘录连续")
        XCTAssertTrue(md.contains("[^3]: 参见《孟子·滕文公下》"))
        XCTAssertFalse(md.contains("<p>"))
        let inline = NotebookExporter.markdown(title: "t", pieces: [pieces[1]], options: .init(footnotes: false))
        XCTAssertTrue(inline.contains("毅言其守（参见《论语·泰伯》；参见《孟子·滕文公下》）"))
        let html = NotebookHTML.page(title: "t", pieces: pieces)
        XCTAssertTrue(html.contains("<p>弘言其量，毅言其守<sup class=\"ref\">②</sup><sup class=\"ref\">③</sup></p>"))
        let rtf = NotebookExporter.rtf(title: "t", pieces: [pieces[1]])
        XCTAssertEqual(rtf.components(separatedBy: "\\footnote").count - 1, 2)
        let docx = NotebookDocx.files(title: "t", pieces: [pieces[1]])
        XCTAssertEqual((docx["word/footnotes.xml"]?.components(separatedBy: "<w:footnote w:id=").count ?? 0) - 1, 2, "两条脚注")
    }

    func testWikiLinksPlain() {
        XCTAssertEqual(WikiLinks.plain("参见 [[汉学与宋学之争]] 与 [[乾嘉考据|考据]]。"), "参见 汉学与宋学之争 与 考据。")
        XCTAssertEqual(WikiLinks.plain("<p>[[A &amp; B]]</p>"), "<p>A &amp; B</p>", "HTML 正文里保留转义")
    }

    func testIdeaNoteMarkdownFilesAndLinks() {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        let a = IdeaNoteMarkdown.Note(id: 1, title: "士由身份转为德行", body: "<p>见 [[士之可贵：不待外物而自立|自立]] 与 [[未建的题目]]。</p>",
                                      createdAt: d, updatedAt: d, quotes: [.init(text: "<p>士志于道</p>", cite: "《论语·里仁》")])
        let b = IdeaNoteMarkdown.Note(id: 2, title: "士之可贵：不待外物而自立", body: "", createdAt: d.addingTimeInterval(60), updatedAt: d, quotes: [])
        let c = IdeaNoteMarkdown.Note(id: 3, title: "士由身份转为德行", body: "", createdAt: d.addingTimeInterval(120), updatedAt: d, quotes: [])
        let stems = IdeaNoteMarkdown.fileStems(for: [c, b, a])
        XCTAssertEqual(stems[1], "士由身份转为德行")
        XCTAssertEqual(stems[3], "士由身份转为德行 (2)", "同名的按先后加序号")
        XCTAssertEqual(stems[2], "士之可贵-不待外物而自立", "去掉冒号")
        let byKey = [WikiLinks.key(b.title): stems[2]!]
        let md = IdeaNoteMarkdown.markdown(a) { byKey[WikiLinks.key($0)] }
        XCTAssertTrue(md.contains("[[士之可贵-不待外物而自立|自立]]"), "链接改写成对方的文件名，显示文字不变")
        XCTAssertTrue(md.contains("[[未建的题目]]"))
        XCTAssertTrue(md.contains("> 士志于道\n>\n> — 《论语·里仁》"))
        XCTAssertTrue(IdeaNoteMarkdown.isGenerated(md))
        XCTAssertFalse(IdeaNoteMarkdown.isGenerated("---\ntitle: 我自己的笔记\n---\n\n正文"))
    }
}
