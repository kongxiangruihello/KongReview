import XCTest
import GRDB
import KongGleanCore
@testable import KongGlean

final class DBTests: XCTestCase {
  func testEverything() throws {
    let db = try AppDatabase(DatabaseQueue())
    let s = try db.save(Source(title: "论语译注", author: "杨伯峻", publisher: "中华书局", year: "1980"))
    XCTAssertNotNil(s.id)
    var h1 = try db.save(Highlight(sourceId: s.id, text: "克己复礼为仁。一日克己复礼，天下归仁焉。", note: "颜渊篇", location: "第123页", tags: ["论语", "仁"]))
    _ = try db.save(Highlight(sourceId: s.id, text: "学而时习之，不亦说乎？", tags: ["论语"]))
    _ = try db.save(Highlight(text: "未归类的一条 50% 测试", tags: []))

    XCTAssertEqual(try db.highlights().count, 3)
    XCTAssertEqual(try db.highlights(query: "克己复礼").count, 1, "FTS trigram")
    XCTAssertEqual(try db.highlights(query: "颜渊篇").count, 1, "FTS on note")
    XCTAssertEqual(try db.highlights(query: "克己").count, 1, "LIKE fallback")
    XCTAssertEqual(try db.highlights(query: "仁").count, 1, "LIKE 1 char")
    XCTAssertEqual(try db.highlights(query: "50%").count, 1)
    XCTAssertEqual(try db.highlights(query: "say \"x").count, 0, "FTS quoting safe")
    XCTAssertEqual(try db.highlights(tag: "论语").count, 2)
    XCTAssertEqual(try db.highlights(tag: "仁").count, 1)
    XCTAssertEqual(try db.highlights(unsortedOnly: true).count, 1)
    XCTAssertEqual(try db.allTags(), ["仁", "论语"].sorted())
    XCTAssertEqual(try db.highlightCounts()[s.id!], 2)

    // update keeps FTS in sync
    h1.text = "修改后的文本内容"
    h1 = try db.save(h1)
    XCTAssertEqual(try db.highlights(query: "克己复礼").count, 0)
    XCTAssertEqual(try db.highlights(query: "修改后").count, 1)

    // discard, favorites, mastery
    let sch = ReviewScheduler()
    _ = try db.save(sch.apply(.discard, to: h1))
    XCTAssertEqual(try db.highlights().count, 2)
    XCTAssertEqual(try db.highlights(includeDiscarded: true).count, 3)
    let all = try db.highlights()
    _ = try db.save(sch.addToMastery(all[0]))
    XCTAssertEqual(try db.highlights(masteryOnly: true).count, 1)

    // ids order
    let ids = all.compactMap(\.id).reversed().map { $0 }
    XCTAssertEqual(try db.highlights(ids: ids).compactMap(\.id), ids)

    // capture ingest
    let cap = CaptureRequest(url: URL(string: "kongglean://add?text=hello%20world&title=Page&url=https://ex.com/a")!)!
    let h = try db.ingest(cap)
    let src = try db.source(id: h.sourceId)
    XCTAssertEqual(src?.kind, .web)
    let h2 = try db.ingest(cap)
    XCTAssertEqual(h2.sourceId, h.sourceId, "same URL -> same source")

    // review candidates & weights
    var muted = src!; muted.reviewWeight = 0; try db.save(muted)
    let (cands, weights) = try db.reviewCandidates()
    XCTAssertEqual(weights[muted.id!], 0)
    var rng = SeededGenerator(seed: 1)
    let session = sch.makeSession(highlights: cands, sourceWeights: weights, using: &rng)
    XCTAssertFalse(session.regular.contains { $0.sourceId == muted.id })

    // delete source keeps highlights (SET NULL)
    try db.delete(s)
    XCTAssertEqual(try db.highlights(unsortedOnly: true).count, 2)

    // roundtrip dates/bools/tags
    let back = try db.highlights(tag: "论语")
    XCTAssertFalse(back.isEmpty)
  }

  func testFileBackedPoolMigrates() throws {
    let path = NSTemporaryDirectory() + "kg-\(UUID().uuidString).sqlite"
    var config = Configuration(); config.foreignKeysEnabled = true
    _ = try AppDatabase(DatabasePool(path: path, configuration: config))
    let again = try AppDatabase(DatabasePool(path: path, configuration: config))
    XCTAssertEqual(try again.highlights().count, 0)
  }
}

final class StoreTests: XCTestCase {
  @MainActor func testStoreFlow() async throws {
    let store = LibraryStore(db: try AppDatabase(DatabaseQueue()))
    store.handle(url: URL(string: "kongglean://add?text=%E6%B5%8B%E8%AF%95&title=T&url=https://a.b/c&tags=x,y")!)
    var draft = try XCTUnwrap(store.editorDraft)
    XCTAssertEqual(draft.newSourceTitle, "T")
    draft.highlight.location = "  "
    store.commit(draft)
    XCTAssertNil(store.editorDraft)
    XCTAssertEqual(store.sources.count, 1)
    XCTAssertEqual(store.tags, ["x", "y"])
    let h = try store.db.highlights().first!
    XCTAssertNil(h.location)
    XCTAssertEqual(h.sourceId, store.sources.first?.id)
    // second capture of same URL -> reuses source
    store.handle(url: URL(string: "kongglean://add?text=again&url=https://a.b/c")!)
    XCTAssertEqual(store.editorDraft?.highlight.sourceId, store.sources.first?.id)
    store.delete(store.sources[0])
    XCTAssertEqual(store.sources.count, 0)
    XCTAssertNil(store.errorMessage)
  }
}
