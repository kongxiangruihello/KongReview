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

final class V02DatabaseTests: XCTestCase {
  func testSoftDeleteTrashAndPurge() throws {
    let db = try AppDatabase(DatabaseQueue())
    let s = try db.save(Source(title: "书"))
    let a = try db.save(Highlight(sourceId: s.id, text: "第一条摘录内容", tags: ["甲"]))
    _ = try db.save(Highlight(sourceId: s.id, text: "第二条摘录内容", tags: ["乙"]))

    let now = Date()
    try db.moveToTrash(a, now: now.addingTimeInterval(-40 * 86_400))
    XCTAssertEqual(try db.highlights().count, 1)
    XCTAssertEqual(try db.highlights(query: "第一条摘录").count, 0, "search excludes deleted")
    XCTAssertEqual(try db.highlights(deletedOnly: true).count, 1)
    XCTAssertEqual(try db.trashCount(), 1)
    XCTAssertEqual(try db.allTags(), ["乙"])
    XCTAssertEqual(try db.highlightCounts()[s.id!], 1)
    XCTAssertEqual(try db.highlights(ids: [a.id!]).count, 0)
    XCTAssertTrue(try db.reviewCandidates().highlights.allSatisfy { !$0.isDeleted })

    // restore
    let trashed = try db.highlights(deletedOnly: true)[0]
    try db.restore(trashed)
    XCTAssertEqual(try db.highlights().count, 2)

    // purge only expired
    let all = try db.highlights()
    try db.moveToTrash(all[0], now: now.addingTimeInterval(-40 * 86_400))
    try db.moveToTrash(all[1], now: now.addingTimeInterval(-1 * 86_400))
    XCTAssertEqual(try db.purgeTrash(olderThan: TrashPolicy.cutoff(now: now)), 1)
    XCTAssertEqual(try db.trashCount(), 1)
    XCTAssertEqual(try db.emptyTrash(), 1)
    XCTAssertEqual(try db.trashCount(), 0)
    XCTAssertEqual(try db.highlights(query: "摘录内容").count, 0, "FTS rows removed")
  }

  func testSourceMatchingByTitleWhenAuthorEmpty() throws {
    let db = try AppDatabase(DatabaseQueue())
    let s = try db.save(Source(title: "论语译注", author: "杨伯峻"))
    XCTAssertEqual(try db.findOrCreateSource(title: "论语译注", kind: .book).id, s.id)
    XCTAssertNotEqual(try db.findOrCreateSource(title: "论语译注", author: "钱穆", kind: .book).id, s.id)
  }

  func testBackupAndPrune() throws {
    let path = NSTemporaryDirectory() + "kg-\(UUID().uuidString).sqlite"
    var config = Configuration(); config.foreignKeysEnabled = true
    let db = try AppDatabase(DatabasePool(path: path, configuration: config))
    _ = try db.save(Highlight(text: "备份测试内容"))
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kgb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 40 份旧备份 + 无关文件
    for i in 0..<40 {
      let d = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
      FileManager.default.createFile(atPath: dir.appendingPathComponent(BackupPolicy.fileName(for: d)).path, contents: Data())
    }
    FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())

    let now = Date()
    let made = try BackupService.backupIfNeeded(db: db, now: now, directory: dir)
    XCTAssertNotNil(made)
    XCTAssertNil(try BackupService.backupIfNeeded(db: db, now: now, directory: dir), "once per day")
    _ = try BackupService.backupNow(db: db, now: now, directory: dir) // overwrite same day ok

    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(names.filter(BackupPolicy.isBackupFile).count, BackupService.keepCount)
    XCTAssertTrue(names.contains("notes.txt"))
    XCTAssertFalse(names.contains { $0.hasPrefix(".tmp-") })

    // backup is a valid DB with the data
    let copy = try DatabaseQueue(path: made!.path)
    XCTAssertEqual(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM highlight") }, 1)
  }
}

final class V02StoreTests: XCTestCase {
  @MainActor func testStoreTrashFlow() async throws {
    let store = LibraryStore(db: try AppDatabase(DatabaseQueue()))
    var d = HighlightDraft(highlight: Highlight(text: "条目一"))
    d.newSourceTitle = "某书"
    store.commit(d)
    let h = try store.db.highlights()[0]
    store.delete(h)
    XCTAssertEqual(store.trashCount, 1)
    store.restore(try store.db.highlights(deletedOnly: true)[0])
    XCTAssertEqual(store.trashCount, 0)
    store.delete(try store.db.highlights()[0])
    store.emptyTrash()
    XCTAssertEqual(store.trashCount, 0)
    XCTAssertNil(store.errorMessage)
  }
}

final class ReadwiseDatabaseImportTests: XCTestCase {
  func testImportIsIdempotentAndMergesSources() throws {
    let db = try AppDatabase(DatabaseQueue())
    _ = try db.save(Source(title: "论语译注", author: "杨伯峻"))
    let csv = "Highlight,Book Title,Book Author,Note,Tags,Location Type,Location,Highlighted at\n"
      + "学而时习之，不亦说乎？,论语译注,杨伯峻,开篇,\"论语,favorite\",page,1,2023-05-01 12:34:56+00:00\n"
      + "温故而知新，可以为师矣。,论语译注,杨伯峻,,,page,15,2023-05-02 12:00:00+00:00\n"
      + "Web text here,Some Article,,,,,,2024-01-01T00:00:00Z\n"
    let parsed = try ReadwiseCSVImporter.parse(csv)
    let r1 = try db.importReadwise(parsed, extraTag: "Readwise")
    XCTAssertEqual(r1, ImportReport(sourcesCreated: 1, sourcesReused: 1, highlightsImported: 3, duplicatesSkipped: 0))
    let r2 = try db.importReadwise(parsed, extraTag: "Readwise")
    XCTAssertEqual(r2.highlightsImported, 0)
    XCTAssertEqual(r2.duplicatesSkipped, 3)

    XCTAssertEqual(try db.highlights().count, 3)
    XCTAssertEqual(try db.highlights(tag: "Readwise").count, 3)
    XCTAssertEqual(try db.highlights(favoritesOnly: true).count, 1)
    XCTAssertEqual(try db.highlights(query: "温故而知新").first?.location, "第15页")
    XCTAssertEqual(try db.allSources().count, 2)
    // createdAt follows Readwise highlighted date → oldest last in list
    XCTAssertEqual(try db.highlights().last?.text, "学而时习之，不亦说乎？")
  }
}

final class ArticleDatabaseTests: XCTestCase {
  func testSaveArticleLinksSourceAndHighlights() throws {
    let db = try AppDatabase(DatabaseQueue())
    let a = Article(url: "https://blog.example.cn/1", title: "明清之际的思想转向", author: "张三", siteName: "某学术博客",
                    publishedAt: "2025-03-01T08:00:00+08:00", contentHTML: "<p>正文</p>", contentText: "正文内容", wordCount: 4)
    let saved = try db.saveArticle(a)
    XCTAssertNotNil(saved.id)
    let src = try db.source(id: saved.sourceId)
    XCTAssertEqual(src?.kind, .web)
    XCTAssertEqual(src?.publisher, "某学术博客")
    XCTAssertEqual(src?.year, "2025")
    XCTAssertEqual(src?.author, "张三")

    // re-save same URL updates, not duplicates
    var again = a; again.contentHTML = "<p>新正文</p>"
    let saved2 = try db.saveArticle(again)
    XCTAssertEqual(saved2.id, saved.id)
    XCTAssertEqual(try db.articles().count, 1)
    XCTAssertEqual(try db.article(id: saved.id!)?.contentHTML, "<p>新正文</p>")
    XCTAssertEqual(try db.allSources().count, 1)

    // highlights in the article's source
    _ = try db.save(Highlight(sourceId: saved.sourceId, text: "思想转向的一段"))
    XCTAssertEqual(try db.articleHighlightCounts()[saved.id!], 1)
    XCTAssertEqual(try db.articles(query: "学术").count, 1)
    XCTAssertEqual(try db.articles(query: "无关").count, 0)

    try db.markArticleOpened(id: saved.id!)
    XCTAssertEqual(try db.article(id: saved.id!)?.isRead, true)

    // deleting the article keeps source + highlights
    try db.deleteArticle(id: saved.id!)
    XCTAssertEqual(try db.articles().count, 0)
    XCTAssertEqual(try db.highlights(sourceId: saved.sourceId).count, 1)
  }
}

final class ArticleListTests: XCTestCase {
  func testListOmitsContentAndSearches() throws {
    let db = try AppDatabase(DatabaseQueue())
    _ = try db.saveArticle(Article(url: "https://a.cn/1", title: "百分之50%的标题", siteName: "站点", contentHTML: "<p>很长的正文</p>", contentText: "很长的正文", wordCount: 5))
    let list = try db.articles()
    XCTAssertEqual(list.count, 1)
    XCTAssertEqual(list[0].contentHTML, "")
    XCTAssertEqual(try db.article(id: list[0].id!)?.contentHTML, "<p>很长的正文</p>")
    XCTAssertEqual(try db.articles(query: "50%").count, 1)
    XCTAssertEqual(try db.articles(query: "站点").count, 1)
    XCTAssertEqual(try db.articleCount(), 1)
  }
}

final class V05DatabaseTests: XCTestCase {
  func testPaginationAndCount() throws {
    let db = try AppDatabase(DatabaseQueue())
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<450 { _ = try db.save(Highlight(text: "第\(i)条摘录内容", createdAt: t0.addingTimeInterval(Double(i)))) }
    let q = HighlightQuery()
    XCTAssertEqual(try db.count(q), 450)
    let p1 = try db.highlights(q, limit: 200, offset: 0)
    let p3 = try db.highlights(q, limit: 200, offset: 400)
    XCTAssertEqual(p1.count, 200); XCTAssertEqual(p3.count, 50)
    XCTAssertEqual(p1.first?.text, "第449条摘录内容")
    XCTAssertEqual(p3.last?.text, "第0条摘录内容")
    XCTAssertEqual(try db.count(HighlightQuery(text: "第44")), 11) // 44, 440-449 (LIKE: <3 chars? "第44" is 3 chars → FTS)
  }

  func testBatchModifyMergeAndKind() throws {
    let db = try AppDatabase(DatabaseQueue())
    let a = try db.save(Source(title: "论语译注", author: "杨伯峻", publisher: "中华书局"))
    let b = try db.save(Source(title: "论语译注（修订本）", author: "", year: "1980", place: "北京"))
    let c = try db.save(Source(title: "孟子"))
    var ids: [Int64] = []
    for (i, s) in [a, a, b, c].enumerated() { ids.append(try db.save(Highlight(sourceId: s.id, text: "条目\(i)", tags: ["旧"])).id!) }
    _ = try db.saveArticle(Article(url: "https://x.cn/1", title: "文", contentHTML: "", contentText: "", wordCount: 0))

    // batch tags / favorite
    XCTAssertEqual(try db.modifyHighlights(ids: Array(ids.prefix(2))) { h in
      h.tags = TagParser.parse((h.tags + ["新"]).joined(separator: ",")); h.isFavorite = true }, 2)
    XCTAssertEqual(try db.highlights(tag: "新").count, 2)
    XCTAssertEqual(try db.highlights(favoritesOnly: true).count, 2)
    XCTAssertEqual(try db.modifyHighlights(ids: ids) { h in h.tags.removeAll { $0 == "旧" } }, 4)
    XCTAssertEqual(try db.highlights(tag: "旧").count, 0)

    // move
    _ = try db.modifyHighlights(ids: [ids[3]]) { $0.sourceId = a.id }
    XCTAssertEqual(try db.highlights(sourceId: a.id).count, 3)

    // dedup + merge b into a
    XCTAssertEqual(SourceDedup.duplicateGroups(try db.allSources()), [[a.id!, b.id!]])
    XCTAssertEqual(try db.mergeSources([a.id!, b.id!], into: a.id!), 1)
    let merged = try db.source(id: a.id)!
    XCTAssertEqual(merged.year, "1980"); XCTAssertEqual(merged.place, "北京"); XCTAssertEqual(merged.publisher, "中华书局")
    XCTAssertNil(try db.source(id: b.id))
    XCTAssertEqual(try db.highlights(sourceId: a.id).count, 4)
    let counts = Dictionary(uniqueKeysWithValues: try db.sourcesWithCounts().map { ($0.source.id!, $0.count) })
    XCTAssertEqual(counts[a.id!], 4); XCTAssertEqual(counts[c.id!], 0)

    try db.setKind(.article, forSources: [c.id!])
    XCTAssertEqual(try db.source(id: c.id)?.kind, .article)
    try db.deleteSources([c.id!])
    XCTAssertNil(try db.source(id: c.id))
  }
}
