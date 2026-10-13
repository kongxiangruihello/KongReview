import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

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
    let cap = CaptureRequest(url: URL(string: "kongreview://add?text=hello%20world&title=Page&url=https://ex.com/a")!)!
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
    store.handle(url: URL(string: "kongreview://add?text=%E6%B5%8B%E8%AF%95&title=T&url=https://a.b/c&tags=x,y")!)
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
    store.handle(url: URL(string: "kongreview://add?text=again&url=https://a.b/c")!)
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

final class RenameMigrationTests: XCTestCase {
  func testLegacyDatabaseIsCopiedOnce() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = dir.appendingPathComponent("glean.sqlite")
    let target = dir.appendingPathComponent("kongreview.sqlite")
    var config = Configuration(); config.foreignKeysEnabled = true
    do {
      let old = try AppDatabase(DatabasePool(path: legacy.path, configuration: config))   // WAL 模式
      _ = try old.save(Highlight(text: "旧库里的摘录一"))
      _ = try old.save(Highlight(text: "旧库里的摘录二"))
    }
    try AppDatabase.migrateLegacyDatabase(from: legacy, to: target, configuration: config)
    let migrated = try AppDatabase(DatabasePool(path: target.path, configuration: config))
    XCTAssertEqual(try migrated.highlights().count, 2)
    XCTAssertEqual(try migrated.highlights(query: "旧库里的摘录").count, 2, "FTS index copied")
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "legacy kept")
    // second run is a no-op (target exists)
    _ = try migrated.save(Highlight(text: "新库新增"))
    try AppDatabase.migrateLegacyDatabase(from: legacy, to: target, configuration: config)
    XCTAssertEqual(try migrated.highlights().count, 3)
  }

  func testSettingsMigration() {
    let suite = "test.kongreview.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.setPersistentDomain(["review.dailyCount": 20, "hotkey.preset": "optCmdK", "NSWindow Frame main": "x"], forName: LegacyMigration.oldDomain)
    d.set(5, forKey: "review.masteryLimit")
    LegacyMigration.migrateSettings(into: d)
    XCTAssertEqual(d.integer(forKey: "review.dailyCount"), 20)
    XCTAssertEqual(d.string(forKey: "hotkey.preset"), "optCmdK")
    XCTAssertNil(d.object(forKey: "NSWindow Frame main"))
    XCTAssertTrue(d.bool(forKey: LegacyMigration.doneKey))
    d.removePersistentDomain(forName: LegacyMigration.oldDomain)
    d.removePersistentDomain(forName: suite)
  }
}

final class V07DatabaseTests: XCTestCase {
  func makeFakeApkgFolder(withNewFormat: Bool = false) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apkg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let q = try DatabaseQueue(path: dir.appendingPathComponent("collection.anki2").path)
    try q.write { db in
      try db.execute(sql: "CREATE TABLE col (id integer primary key, crt integer, models text, decks text)")
      try db.execute(sql: "CREATE TABLE notes (id integer primary key, guid text, mid integer, flds text, tags text)")
      try db.execute(sql: "CREATE TABLE cards (id integer primary key, nid integer, did integer, ord integer, type integer, queue integer, due integer, ivl integer, factor integer, reps integer, lapses integer)")
      let models = #"{"111": {"name": "Basic", "type": 0}, "222": {"name": "Cloze", "type": 1}}"#
      let decks = #"{"1": {"name": "Default"}, "5": {"name": "论语\u001f学而"}}"#
      try db.execute(sql: "INSERT INTO col VALUES (1, 1600000000, ?, ?)", arguments: [models, decks])
      if withNewFormat {
        try db.execute(sql: "INSERT INTO notes VALUES (1, 'x', 111, 'Please update to the latest Anki version\u{1f}', '')")
        try db.execute(sql: "INSERT INTO cards VALUES (1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0)")
      } else {
        try db.execute(sql: "INSERT INTO notes VALUES (1, 'g1', 111, ?, ' 论语 经部 ')", arguments: ["学而时习之<img src=\"a.jpg\">\u{1f}学了按时温习[sound:x.mp3]"])
        try db.execute(sql: "INSERT INTO notes VALUES (2, 'g2', 222, ?, '')", arguments: ["{{c1::克己复礼}}为仁\u{1f}颜渊"])
        try db.execute(sql: "INSERT INTO cards VALUES (10, 1, 5, 0, 2, 2, 100, 15, 2300, 6, 1)")
        try db.execute(sql: "INSERT INTO cards VALUES (11, 1, 5, 1, 0, 0, 1, 0, 0, 0, 0)")  // 反向卡，忽略
        try db.execute(sql: "INSERT INTO cards VALUES (20, 2, 1, 0, 0, 0, 2, 0, 0, 0, 0)")
      }
    }
    try q.close()
    if withNewFormat { FileManager.default.createFile(atPath: dir.appendingPathComponent("collection.anki21b").path, contents: Data([1, 2])) }
    try Data(#"{"0": "a.jpg"}"#.utf8).write(to: dir.appendingPathComponent("media"))
    try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("0"))
    return dir
  }

  func testApkgReadAndImport() throws {
    let folder = try makeFakeApkgFolder()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let (notes, media) = try AnkiCollectionReader.read(folder: folder, now: now)
    XCTAssertEqual(notes.count, 2)
    XCTAssertEqual(notes[0].front, #"学而时习之<img src="a.jpg">"#)
    XCTAssertEqual(notes[0].back, "学了按时温习")
    XCTAssertEqual(notes[0].deck, "论语::学而")
    XCTAssertEqual(notes[0].tags, ["论语", "经部"])
    XCTAssertEqual(notes[0].schedule?.state, .review)
    XCTAssertEqual(notes[0].schedule?.interval, 15)
    XCTAssertEqual(notes[1].front, #"<span class="cloze">[…]</span>为仁"#)
    XCTAssertNil(notes[1].schedule)
    XCTAssertEqual(media["a.jpg"], Data([0xFF, 0xD8, 0xFF]))

    let db = try AppDatabase(DatabaseQueue())
    let r1 = try db.importAnki(notes, media: media, now: now)
    XCTAssertEqual(r1.imported, 2); XCTAssertEqual(r1.media, 1); XCTAssertEqual(r1.decks, ["Default", "论语::学而"])
    XCTAssertEqual(try db.importAnki(notes, media: media, now: now).duplicates, 2)
    XCTAssertEqual(try db.media(named: "a.jpg"), Data([0xFF, 0xD8, 0xFF]))
    let review = try db.cards(deck: "论语::学而")[0]
    XCTAssertEqual(review.ease, 2.3); XCTAssertEqual(review.reps, 6)
    XCTAssertThrowsError(try AnkiCollectionReader.read(folder: makeFakeApkgFolder(withNewFormat: true)))
  }

  func testCardsStudyLogAndStats() throws {
    let db = try AppDatabase(DatabaseQueue())
    let s = try db.save(Source(title: "论语译注", author: "杨伯峻"))
    let h1 = try db.save(Highlight(sourceId: s.id, text: "学而时习之", note: "开篇"))
    let h2 = try db.save(Highlight(sourceId: s.id, text: "温故而知新"))
    XCTAssertEqual(try db.makeCards(fromHighlights: [h1.id!, h2.id!]), 2)
    XCTAssertEqual(try db.makeCards(fromHighlights: [h1.id!]), 0, "no duplicate cards per highlight")
    XCTAssertEqual(try db.cardHighlightIDs(), [h1.id!, h2.id!])
    let now = Date()
    var decks = try db.deckSummaries(now: now, newPerDay: 20, reviewsPerDay: 200)
    XCTAssertEqual(decks.map(\.name), ["摘录"]); XCTAssertEqual(decks[0].counts.new, 2)
    let c = try db.cards(deck: "摘录").first { $0.highlightId == h1.id }!
    XCTAssertTrue(c.back.contains("按：开篇"))
    _ = try db.answer(c, .good, now: now)
    XCTAssertEqual(try db.studiedToday(now: now).new, 1)
    decks = try db.deckSummaries(now: now, newPerDay: 1, reviewsPerDay: 200)
    XCTAssertEqual(decks[0].counts.new, 0, "daily new limit reached")
    XCTAssertTrue(try db.reviewedToday(now: now))
    db.log(ReviewEvent(kind: .keep, highlightId: h2.id, at: now))
    let sum = ReviewStats.summarize(try db.events(), now: now)
    XCTAssertEqual(sum.today.cards, 1); XCTAssertEqual(sum.today.highlights, 1)
    try db.renameDeck("摘录", to: "论语")
    XCTAssertEqual(try db.deckNames(), ["论语"])
    try db.deleteCards([c.id!])
    XCTAssertEqual(try db.cards().count, 1)
  }

  func testImageCacheAndArticleEdit() throws {
    let db = try AppDatabase(DatabaseQueue())
    XCTAssertNil(try db.cachedImage("https://a.cn/x.png"))
    db.cacheImage("https://a.cn/x.png", data: Data([1, 2, 3]), mime: "image/png")
    XCTAssertEqual(try db.cachedImage("https://a.cn/x.png")?.mime, "image/png")
    let a = try db.saveArticle(Article(url: "https://a.cn/1", title: "t", contentHTML: "<p>旧</p>", contentText: "旧", wordCount: 1))
    try db.updateArticleContent(id: a.id!, html: "<p>新的正文</p><p>第二段</p>")
    let b = try db.article(id: a.id!)!
    XCTAssertEqual(b.contentText, "新的正文\n第二段"); XCTAssertEqual(b.wordCount, 7)
  }
}

final class V08DatabaseTests: XCTestCase {
  /// 多字段笔记 + 牌组选项 + 复习记录：导入、再次导入补全、导出 .apkg 再读回
  func testTemplatesOptionsRevlogAndApkgRoundTrip() throws {
    let db = try AppDatabase(DatabaseQueue())
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var n = AnkiNote(front: "子曰", back: "注<hr>译", tags: ["论语"], deck: "论语::学而", guid: "g1",
                     schedule: .init(state: .review, interval: 10, ease: 2.5, due: now, reps: 3, lapses: 0, suspended: false))
    n.noteType = "论语译注"; n.fieldNames = ["正文", "注释", "译文"]; n.fields = ["子曰", "①子：孔子", "孔子说"]
    n.memory = .init(stability: 12, difficulty: 5)
    n.revlog = [.init(id: 1_799_000_000_000, ease: 3), .init(id: 1_799_500_000_000, ease: 3)]
    n.deckOptions = DeckOptions(deck: "x", newPerDay: 25, reviewsPerDay: 2000, algorithm: .fsrs, desiredRetention: 0.88)

    // 先按 0.7 的方式导入一条（没有字段与记忆状态），再用完整数据重导：应补全而不新建
    var old = n; old.fields = []; old.noteType = nil; old.memory = nil; old.revlog = []; old.deckOptions = nil
    XCTAssertEqual(try db.importAnki([old], now: now).imported, 1)
    let r = try db.importAnki([n], now: now)
    XCTAssertEqual(r.imported, 0); XCTAssertEqual(r.upgraded, 1); XCTAssertEqual(r.revlog, 2); XCTAssertEqual(r.templates, 1)
    XCTAssertEqual(try db.importAnki([n], now: now).revlog, 0, "revlog de-duplicated")

    let card = try XCTUnwrap(db.cards().first)
    XCTAssertEqual(card.fields.count, 3); XCTAssertEqual(card.stability, 12)
    let tpl = try XCTUnwrap(db.noteTemplates()["论语译注"])
    XCTAssertEqual(tpl.collapsed, [1])
    XCTAssertTrue(card.faces(using: tpl).back.contains("<summary>注释</summary>"))
    let o = try XCTUnwrap(db.deckOptions()["论语::学而"])
    XCTAssertEqual(o.algorithm, .fsrs); XCTAssertEqual(o.newPerDay, 25); XCTAssertEqual(o.desiredRetention, 0.88, accuracy: 1e-9)

    // 每牌组上限：牌组选项覆盖全局
    let s = try db.deckSummaries(now: now.addingTimeInterval(86_400 * 30), newPerDay: 0, reviewsPerDay: 0)
    XCTAssertEqual(s.first?.counts.review, 1)

    // FSRS 历史与重算
    XCTAssertEqual(try db.fsrsHistories()[card.id!]?.count, 2)
    XCTAssertEqual(try db.recomputeMemory(parameters: FSRS.defaultParameters, decks: ["论语::学而"]), 1)

    // 导出 .apkg 再用自己的读取器读回
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exp-\(UUID().uuidString)")
    let rep = try db.exportApkg(decks: ["论语::学而"], includeScheduling: true, fsrsParameters: FSRS.defaultParameters,
                                defaults: (20, 200), to: dir)
    XCTAssertEqual(rep.cards, 1); XCTAssertEqual(rep.revlog, 2); XCTAssertEqual(rep.decks, ["论语", "论语::学而"])
    let back = try AnkiCollectionReader.read(folder: dir, now: now)
    XCTAssertEqual(back.notes.count, 1)
    XCTAssertEqual(back.notes[0].deck, "论语::学而")
    XCTAssertEqual(back.notes[0].guid, "g1")
    XCTAssertEqual(back.notes[0].fieldNames, ["正面", "背面"])
    XCTAssertTrue(back.notes[0].fields[1].contains("孔子说"))
    XCTAssertEqual(back.notes[0].schedule?.state, .review)
    XCTAssertNotNil(back.notes[0].memory)
    XCTAssertEqual(back.notes[0].revlog.count, 2)
  }

  func testHighlightCardSyncAndCompact() throws {
    let db = try AppDatabase(DatabaseQueue())
    var h = try db.save(Highlight(text: "学而时习之"))
    XCTAssertEqual(try db.makeCards(fromHighlights: [h.id!]), 1)
    h.text = "学而时习之，不亦说乎"
    h.note = "开篇"
    h = try db.save(h)
    XCTAssertEqual(try db.syncCards(fromHighlight: h.id!, style: .footnote), 1)
    let c = try XCTUnwrap(db.cards(forHighlight: h.id!).first)
    XCTAssertEqual(c.front, "学而时习之，不亦说乎"); XCTAssertTrue(c.back.contains("按：开篇"))
    XCTAssertEqual(try db.syncCards(fromHighlight: h.id!, style: .footnote), 0, "nothing changed")
    _ = try db.importAnki([], media: ["unused.png": Data([1, 2, 3])])
    XCTAssertEqual(try db.compact().mediaRemoved, 1)
  }
}

final class V09DatabaseTests: XCTestCase {
  func testInboxCoversFrequencyAndFilters() throws {
    let db = try AppDatabase(DatabaseQueue())
    let json = #"{"version":1,"app":"KongPDF","source":{"title":"严复集","author":"严复","kind":"pdf","url":"file:///a.pdf","isbn":"9787101000000"},"highlights":[{"id":"h1","text":"物竞天择","page":12,"tags":["严复","进化"],"createdAt":"2026-01-05T08:00:00Z"},{"id":"h2","text":"适者生存","tags":["严复"]}]}"#
    let file = try InboxPayload.parse(Data(json.utf8))
    let r1 = try db.importInbox(file, now: Date(timeIntervalSince1970: 1_790_000_000))
    XCTAssertEqual(r1.added, 2)
    let r2 = try db.importInbox(file)
    XCTAssertEqual(r2.added, 0); XCTAssertEqual(r2.duplicates, 2)
    let src = try XCTUnwrap(db.allSources().first)
    XCTAssertEqual(src.kind, .pdf); XCTAssertEqual(src.isbn, "9787101000000")

    // 封面
    try db.setCover(sourceId: src.id!, data: Data([1, 2, 3]))
    XCTAssertEqual(try db.cover(sourceId: src.id!), Data([1, 2, 3]))
    XCTAssertEqual(try db.coverSourceIDs(), [src.id!])
    try db.setCover(sourceId: src.id!, data: nil)
    XCTAssertNil(try db.cover(sourceId: src.id!))

    // 频率
    let h = try XCTUnwrap(db.highlights(HighlightQuery(text: "物竞")).first)
    XCTAssertEqual(h.location, "第 12 页")
    try db.setFrequency(1, highlightId: h.id!)
    XCTAssertEqual(try db.highlights(ids: [h.id!]).first?.frequency, 1)

    // 组合筛选：多个标签 + 日期范围
    XCTAssertEqual(try db.count(HighlightQuery(tags: ["严复", "进化"])), 1)
    XCTAssertEqual(try db.count(HighlightQuery(tags: ["严复"])), 2)
    let jan = Date(timeIntervalSince1970: 1_767_571_200)   // 2026-01-05
    XCTAssertEqual(try db.count(HighlightQuery(dateFrom: jan, dateTo: jan)), 1)
  }
}

final class V09SyncTests: XCTestCase {
  func testObsidianSyncAndInboxFolder() throws {
    let db = try AppDatabase(DatabaseQueue())
    let s = try db.save(Source(title: "论语译注", author: "杨伯峻"))
    _ = try db.save(Highlight(sourceId: s.id, text: "学而时习之", tags: ["论语"]))
    _ = try db.save(Highlight(text: "未归类的一条"))
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("obs-\(UUID().uuidString)")
    let r1 = try ObsidianSync.run(db: db, to: dir, style: .footnote)
    XCTAssertEqual(r1.written, 2)
    let md = try String(contentsOf: dir.appendingPathComponent("论语译注.md"), encoding: .utf8)
    XCTAssertTrue(md.contains("> 学而时习之") && md.contains("#论语"))
    let r2 = try ObsidianSync.run(db: db, to: dir, style: .footnote)
    XCTAssertEqual(r2.written, 0); XCTAssertEqual(r2.unchanged, 2)

    let inbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try Data(#"{"app":"X","source":{"title":"书"},"highlights":[{"id":"1","text":"甲"}]}"#.utf8).write(to: inbox.appendingPathComponent("a.json"))
    try Data("not json".utf8).write(to: inbox.appendingPathComponent("b.json"))
    let res = InboxService.process(db: db, folder: inbox)
    XCTAssertEqual(res.files, 2); XCTAssertEqual(res.added, 1); XCTAssertEqual(res.failed.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("已导入/a.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("出错/b.json").path))
  }
}

final class V10DatabaseTests: XCTestCase {
  func testSummaryRelatedRestoreAndUndoSnapshots() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v10-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try AppDatabase(DatabasePool(path: dir.appendingPathComponent("a.sqlite").path))
    let s = try db.save(Source(title: "论语"))
    let h1 = try db.save(Highlight(sourceId: s.id, text: "学而时习之，不亦说乎", tags: ["论语"]))
    _ = try db.save(Highlight(sourceId: s.id, text: "学而时习之者，君子之学也"))
    for i in 0..<3 { _ = try db.save(Highlight(text: "其他内容\(i)")) }
    db.log(ReviewEvent(kind: .keep, highlightId: h1.id))
    db.log(ReviewEvent(kind: .card, cardId: 1, answer: 1))
    db.log(ReviewEvent(kind: .card, cardId: 1, answer: 3))

    // SQL 汇总与内存汇总一致
    let a = try db.reviewSummary()
    let b = ReviewStats.summarize(try db.events(), now: Date(), days: 30)
    XCTAssertEqual(a, b)
    XCTAssertEqual(a.today.highlights, 1); XCTAssertEqual(a.today.cards, 2)
    XCTAssertEqual(try db.cardAnswersToday().total, 2); XCTAssertEqual(try db.cardAnswersToday().correct, 1)

    // 相关摘录
    let idx = RelatedIndex(try db.relatedDocs())
    XCTAssertEqual(idx.count, 5)

    // 备份 → 改动 → 恢复
    let backup = dir.appendingPathComponent("b.sqlite")
    try db.backup(to: backup)
    _ = try db.save(Highlight(text: "备份之后新加的"))
    XCTAssertEqual(try db.count(HighlightQuery()), 6)
    let info = try XCTUnwrap(BackupInfo.read(backup))
    XCTAssertEqual(info.highlights, 5)
    try db.restore(from: backup)
    XCTAssertEqual(try db.count(HighlightQuery()), 5)
    let diag = Diagnostics.report(db: db, settings: [("快捷键", "⌃⌥K")])
    XCTAssertTrue(diag.contains("摘录：5"), diag)
    XCTAssertFalse(diag.contains("学而时习之"), "诊断信息不应包含摘录正文")
  }
}

final class V10UndoTests: XCTestCase {
  func testUndoRedo() throws {
    // XCTest 在主线程上跑测试；LibraryStore 是主线程对象
    try MainActor.assumeIsolated { try runUndoScenario() }
  }

  @MainActor
  private func runUndoScenario() throws {
    let db = try AppDatabase(DatabaseQueue())
    let store = LibraryStore(db: db)
    let um = UndoManager()
    store.undoManager = um
    let a = try db.save(Source(title: "甲"))
    let b = try db.save(Source(title: "乙"))
    let h1 = try db.save(Highlight(sourceId: a.id, text: "一"))
    let h2 = try db.save(Highlight(sourceId: b.id, text: "二"))
    store.reload()

    // 删除摘录 → 撤销 → 重做
    store.delete(h1)
    XCTAssertEqual(try db.count(HighlightQuery()), 1)
    um.undo()
    XCTAssertEqual(try db.count(HighlightQuery()), 2)
    um.redo()
    XCTAssertEqual(try db.count(HighlightQuery()), 1)
    um.undo()

    // 合并出处 → 撤销：出处与摘录归属都回来
    store.mergeRequest = MergeRequest(sources: [.init(source: a, count: 1), .init(source: b, count: 1)], target: a.id!)
    store.commitMerge()
    XCTAssertEqual(try db.allSources().count, 1)
    um.undo()
    XCTAssertEqual(try db.allSources().count, 2)
    XCTAssertEqual(try db.highlights(ids: [h2.id!]).first?.sourceId, b.id)

    // 删除记忆卡 → 撤销
    XCTAssertEqual(try db.makeCards(fromHighlights: [h1.id!]), 1)
    let cid = try XCTUnwrap(db.cards().first?.id)
    store.deleteCards([cid])
    XCTAssertEqual(try db.cardCount(), 0)
    um.undo()
    XCTAssertEqual(try db.cardCount(), 1)

    // 批量弃置 → 撤销
    store.batch(.discard(true), ids: [h1.id!, h2.id!])
    XCTAssertEqual(try db.count(HighlightQuery()), 0)
    um.undo()
    XCTAssertEqual(try db.count(HighlightQuery()), 2)
  }
}

final class V11DatabaseTests: XCTestCase {
  func makeDB() throws -> AppDatabase {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v11-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try AppDatabase(DatabasePool(path: dir.appendingPathComponent("a.sqlite").path))
  }

  func testLiquidTextImportKeepsSameTextOnDifferentPagesAndImages() throws {
    let db = try makeDB()
    let parsed = LiquidTextImporter.parse([
      .init(text: "Notes in ‘革命造反年代 (李逊) ’", indent: 0),
      .init(text: "Excerpt:\t朱維錚\n(革命造反年代 (李逊) , p.461)"),
      .init(text: "Excerpt:\t朱維錚\n(革命造反年代 (李逊) , p.471)"),
      .init(text: "Excerpt:\t[Image]\n(革命造反年代 (李逊) , p.17)", images: ["rId10"]),
    ])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    var media: [String: Data] = [:]
    let result = LiquidTextImporter.result(parsed, fallbackTitle: "x") { _, loc in
      media["liquidtext-1.png"] = png
      return "![\(loc ?? "")](kr-media://media/liquidtext-1.png)"
    }
    XCTAssertEqual(result.highlightCount, 3)
    try db.saveMedia(media)
    let r1 = try db.importReadwise(result, extraTag: "LiquidText")
    XCTAssertEqual(r1.highlightsImported, 3, "同一人名在不同页码各算一条")
    let r2 = try db.importReadwise(result, extraTag: "LiquidText")
    XCTAssertEqual(r2.highlightsImported, 0)
    XCTAssertEqual(r2.duplicatesSkipped, 3, "重复导入同一文件不产生重复")
    let src = try XCTUnwrap(try db.allSources().first)
    XCTAssertEqual(src.title, "革命造反年代"); XCTAssertEqual(src.author, "李逊")

    // 整理数据库时，摘录正文引用的图片要保留
    XCTAssertEqual(try db.media(named: "liquidtext-1.png"), png)
    let report = try db.compact()
    XCTAssertEqual(report.mediaRemoved, 0)
    XCTAssertEqual(try db.media(named: "liquidtext-1.png"), png)
    try db.saveMedia(["orphan.png": png])
    XCTAssertEqual(try db.compact().mediaRemoved, 1)
  }

  func testTagRenameMergeDeleteAndHierarchy() throws {
    let db = try makeDB()
    let a = try db.save(Highlight(text: "孟子曰", tags: ["孟子", "儒家"]))
    let b = try db.save(Highlight(text: "荀子曰", tags: ["儒家/荀子"]))
    _ = try db.save(Highlight(text: "论语", tags: ["論語"]))
    _ = try db.save(Highlight(text: "论语二", tags: ["论语"]))
    _ = try db.save(Highlight(text: "学派", tags: ["儒家学派"]))

    // 父标签包含子标签，但不包含“儒家学派”
    XCTAssertEqual(try db.count(HighlightQuery(tag: "儒家")), 2)
    XCTAssertEqual(Set(try db.highlightIDs(withTag: "儒家")), Set([a.id!, b.id!]))

    // 改名为子标签
    XCTAssertEqual(try db.renameTag("孟子", to: "儒家/孟子"), 1)
    XCTAssertEqual(try db.count(HighlightQuery(tag: "儒家")), 2)
    XCTAssertEqual(try db.count(HighlightQuery(tag: "儒家/孟子")), 1)

    // 合并
    XCTAssertEqual(try db.renameTag("論語", to: "论语"), 1)
    XCTAssertEqual(try db.tagCounts()["论语"], 2)
    XCTAssertNil(try db.tagCounts()["論語"])

    // 父标签改名，子标签跟着改
    try db.renameTag("儒家", to: "先秦儒家")
    let counts = try db.tagCounts()
    XCTAssertEqual(counts["先秦儒家/荀子"], 1)
    XCTAssertEqual(counts["先秦儒家/孟子"], 1)
    XCTAssertEqual(counts["儒家学派"], 1)
    let tree = TagNode.tree(counts)
    XCTAssertEqual(tree.first { $0.name == "先秦儒家" }?.count, 3)

    // 删除（连同子标签），摘录保留
    XCTAssertEqual(try db.deleteTag("先秦儒家"), 2)
    XCTAssertEqual(try db.count(HighlightQuery()), 5)
    XCTAssertTrue(try db.tagCounts().keys.allSatisfy { !$0.hasPrefix("先秦儒家") })
  }

  func testCardInsightsQueries() throws {
    let db = try makeDB()
    let now = Date()
    var c1 = Card(deck: "论语", front: "a", back: "b", due: now.addingTimeInterval(-86400), createdAt: now, updatedAt: now)
    c1.state = .review
    var c2 = Card(deck: "论语", front: "c", back: "d", due: now.addingTimeInterval(3 * 86400), createdAt: now, updatedAt: now)
    c2.state = .review; c2.isSuspended = true
    let c3 = Card(deck: "论语", front: "e", back: "f", due: now, createdAt: now, updatedAt: now)
    let saved = try [c1, c2, c3].map { try db.save($0) }
    let counts = try db.cardStateCounts()
    XCTAssertEqual(counts, CardStateCounts(total: 3, new: 1, learning: 0, review: 2, suspended: 1))
    XCTAssertEqual(try db.studiedCardDues().count, 1, "新卡、暂停的卡不计入负荷")
    db.log(ReviewEvent(kind: .card, cardId: saved[0].id, answer: 3, at: now.addingTimeInterval(-3 * 86400)))
    db.log(ReviewEvent(kind: .card, cardId: saved[0].id, answer: 1, at: now.addingTimeInterval(-86400)))
    let answers = try db.cardAnswers(since: now.addingTimeInterval(-30 * 86400))
    XCTAssertEqual(answers.count, 2)
    let r = CardForecast.retention(answers, now: now, weeks: 4)
    XCTAssertEqual(r.last30Reviews, 1); XCTAssertEqual(r.last30Passed, 0)
    XCTAssertEqual(try db.targetRetention(), 0.9)
    try db.save(DeckOptions(deck: "论语", algorithm: .fsrs, desiredRetention: 0.85))
    XCTAssertEqual(try db.targetRetention(), 0.85, accuracy: 1e-9)
  }
}
