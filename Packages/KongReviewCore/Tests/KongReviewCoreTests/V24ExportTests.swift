import XCTest
@testable import KongReviewCore

final class V24ExportTests: XCTestCase {
    func testExportKeepsEverySourceWhenNamesCollide() {
        var sources = [Source(title: "论语", author: "甲"), Source(title: "论语", author: "乙"),
                       Source(title: "A/B"), Source(title: "A:B"), Source(title: "未归类"),
                       Source(title: "Title"), Source(title: "title")]
        for i in sources.indices { sources[i].id = Int64(i + 1) }
        let names = MarkdownExporter.fileNames(for: sources, reservedNames: ["未归类.md"])
        XCTAssertEqual(names.count, sources.count)
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, sources.count)
        XCTAssertFalse(names.contains("未归类.md"))
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && !$0.contains(":") })
        let reversed = MarkdownExporter.fileNames(for: sources.reversed(), reservedNames: ["未归类.md"])
        XCTAssertEqual(names, reversed.reversed(), "出处 id 保证重排后文件名稳定")
    }

    func testDistinctTitlesKeepReadableNames() {
        XCTAssertEqual(MarkdownExporter.fileNames(for: [Source(title: "论语"), Source(title: "孟子")]),
                       ["论语.md", "孟子.md"])
    }
}
