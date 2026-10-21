import XCTest
@testable import KongReviewCore

/// 4.1：札记 [[题目]] 链接的解析、渲染、改名，以及按一段文字找相关摘录
final class V41WikiLinksTests: XCTestCase {
    func testLinksAreParsedNormalizedAndDeduplicated() {
        let text = "<p>见 [[汉学与宋学之争]]，又见 [[ 漢學與宋學之爭 ]] 与 [[经世|经世一义]]。[[]] 与 [x] 不算。</p>"
        let links = WikiLinks.links(in: text)
        XCTAssertEqual(links.map(\.title), ["汉学与宋学之争", "经世"], "繁简与空白归一后去重")
        XCTAssertEqual(links.last?.display, "经世一义")
        XCTAssertEqual(WikiLinks.key("漢學"), WikiLinks.key("汉学"))
        XCTAssertEqual(WikiLinks.titles(in: "[[A &amp; B]]"), ["A & B"], "HTML 实体先还原")
    }

    func testRenderPointsToNotesOrOffersToCreate() {
        let html = "<p>参见 [[汉学与宋学之争]] 与 [[未写的题目|另一说]]。</p>"
        let out = WikiLinks.render(html) { $0 == "汉学与宋学之争" ? 12 : nil }
        XCTAssertTrue(out.contains(#"href="kongreview://note/12">汉学与宋学之争</a>"#))
        XCTAssertTrue(out.contains("kongreview://note-new?title="))
        XCTAssertTrue(out.contains("另一说（未建）</a>"))
        XCTAssertFalse(out.contains("[["))
        XCTAssertEqual(WikiLinks.render("无链接", resolve: { _ in 1 }), "无链接")
    }

    func testRenameRewritesOnlyTheMatchingTitle() {
        let body = "<p>[[旧题]]、[[舊題|别名]]、[[旧题目]]</p>"
        XCTAssertEqual(WikiLinks.rename(body, from: "旧题", to: "新题"), "<p>[[新题]]、[[新题|别名]]、[[旧题目]]</p>")
    }

    func testRelatedToArbitraryText() {
        let docs = [
            RelatedIndex.Doc(id: 1, text: "戴震以考据求义理，作孟子字义疏证", tags: [], sourceId: nil),
            RelatedIndex.Doc(id: 2, text: "孟子字义疏证论理欲之辨", tags: [], sourceId: nil),
            RelatedIndex.Doc(id: 3, text: "钱穆论清代学术与宋学", tags: [], sourceId: nil),
            RelatedIndex.Doc(id: 4, text: "国史大纲引论", tags: [], sourceId: nil),
            RelatedIndex.Doc(id: 5, text: "史记太史公自序", tags: [], sourceId: nil),
        ] + (6...60).map { RelatedIndex.Doc(id: Int64($0), text: "无关文字第\($0)条", tags: [], sourceId: nil) }
        let index = RelatedIndex(docs)
        let hits = index.related(toText: "戴震《孟子字义疏证》的理欲之辨", minScore: 0.05)
        XCTAssertEqual(Set(hits.prefix(2).map(\.id)), [1, 2])
        XCTAssertFalse(index.related(toText: "戴震《孟子字义疏证》", excluding: [1, 2], minScore: 0.05).contains { $0.id == 1 || $0.id == 2 }, "已引用的排除")
        XCTAssertTrue(index.related(toText: "！？").isEmpty)
    }
}
