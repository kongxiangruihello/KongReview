import XCTest
import Foundation
import CryptoKit
import GRDB
import KongReviewCore
@testable import KongReview

final class FullBackupTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        roots = []; suites = []
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-FullBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func defaults() -> UserDefaults {
        let suite = "KongReview.FullBackupTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func database() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }

    private func archive(db: AppDatabase, drafts: EditorDraftPersistence? = nil, settings: UserDefaults? = nil) throws -> URL {
        let url = try directory().appendingPathComponent("test.kongreviewbackup")
        try FullBackupService.create(db: db, draftURL: drafts?.fileURL, defaults: settings ?? defaults(), destination: url)
        return url
    }

    private func readDatabase(_ prepared: PreparedFullBackup, _ body: (Database) throws -> Void) throws {
        var config = Configuration(); config.readonly = true
        let queue = try DatabaseQueue(path: prepared.directory.appendingPathComponent("library.sqlite").path, configuration: config)
        defer { try? queue.close() }
        try queue.read(body)
    }

    func testFullRoundTripIncludesDatabaseMediaAudioDraftsAndSafePreferences() throws {
        let origin = try database()
        let source = try origin.save(Source(title: "备份的书"))
        let highlight = try origin.save(Highlight(sourceId: source.id, text: "备份原文"))
        let card = try origin.save(Card(front: "问题", back: "答案", state: .review, interval: 9, reps: 4))
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        let audio = Data("synthetic audio".utf8)
        try origin.saveMedia(["图片.png": image, "声音.mp3": audio])
        try origin.writer.write { db in
            try db.execute(sql: "INSERT INTO source_cover(sourceId, data, updatedAt) VALUES (?, ?, ?)", arguments: [source.id, image, Date()])
            try db.execute(sql: "INSERT INTO review_event(kind, highlightId, cardId, answer, at) VALUES ('card', ?, ?, 3, ?)", arguments: [highlight.id, card.id, Date()])
        }
        let drafts = try EditorDraftPersistence(directory: directory())
        try drafts.recordHighlight(HighlightDraft(highlight: Highlight(text: "未保存摘录")))
        try drafts.recordCard(CardDraft(card: Card(front: "未保存问题", back: "未保存答案")))
        let preferences = defaults()
        preferences.set(12, forKey: "review.dailyCount")
        preferences.set(true, forKey: "reminder.enabled")
        preferences.set(FSRS.defaultParameters, forKey: "cards.fsrsParams")
        preferences.set("/private/external/path", forKey: "obsidian.folder")
        preferences.set("secret", forKey: "unrelated.secret")
        let url = try archive(db: origin, drafts: drafts, settings: preferences)
        let prepared = try FullBackupService.prepare(url: url)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.counts.highlights, 1)
        XCTAssertEqual(prepared.counts.cards, 1)
        XCTAssertEqual(prepared.counts.sources, 1)
        XCTAssertEqual(prepared.counts.reviewEvents, 1)
        XCTAssertEqual(prepared.counts.media, 3)
        XCTAssertEqual(prepared.counts.highlightDrafts, 1)
        XCTAssertEqual(prepared.counts.cardDrafts, 1)
        let target = try database()
        _ = try target.save(Highlight(text: "恢复前的摘录"))
        let targetDrafts = try EditorDraftPersistence(directory: directory())
        try targetDrafts.recordHighlight(HighlightDraft(highlight: Highlight(text: "恢复前草稿")))
        let targetPreferences = defaults()
        targetPreferences.set(3, forKey: "review.dailyCount")
        targetPreferences.set("/local/keep/path", forKey: "obsidian.folder")
        targetPreferences.set("local secret", forKey: "unrelated.secret")
        let backups = try directory()
        let safety = try FullBackupService.restore(prepared, db: target, draftURL: targetDrafts.fileURL,
                                                 defaults: targetPreferences, safetyDirectory: backups)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.path))
        XCTAssertEqual(try target.highlights(HighlightQuery()).map(\.text), ["备份原文"])
        XCTAssertEqual(try target.card(id: card.id!)?.interval, 9)
        XCTAssertEqual(try target.card(id: card.id!)?.reps, 4)
        XCTAssertEqual(try target.media(named: "图片.png"), image)
        XCTAssertEqual(try target.media(named: "声音.mp3"), audio)
        try targetDrafts.reloadFromDisk()
        XCTAssertEqual(targetDrafts.highlightDrafts.first?.highlight.text, "未保存摘录")
        XCTAssertEqual(targetDrafts.cardDrafts.first?.card.front, "未保存问题")
        XCTAssertEqual(targetPreferences.integer(forKey: "review.dailyCount"), 12)
        XCTAssertTrue(targetPreferences.bool(forKey: "reminder.enabled"))
        XCTAssertEqual(targetPreferences.array(forKey: "cards.fsrsParams") as? [Double], FSRS.defaultParameters)
        XCTAssertEqual(targetPreferences.string(forKey: "obsidian.folder"), "/local/keep/path")
        XCTAssertEqual(targetPreferences.string(forKey: "unrelated.secret"), "local secret")
        let safetyPrepared = try FullBackupService.prepare(url: safety)
        defer { safetyPrepared.cleanup() }
        XCTAssertEqual(safetyPrepared.counts.highlightDrafts, 1)
        try readDatabase(safetyPrepared) { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT text FROM highlight"), "恢复前的摘录")
        }
    }

    func testPreviewDoesNotChangeCurrentDataAndCleanupRemovesOnlyTemporaryCopies() throws {
        let db = try database()
        _ = try db.save(Highlight(text: "原资料"))
        let url = try archive(db: db)
        let before = try Data(contentsOf: url)
        let prepared = try FullBackupService.prepare(url: url)
        let scratch = prepared.directory
        XCTAssertEqual(try db.highlights(HighlightQuery()).map(\.text), ["原资料"])
        prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testRestoringWithoutDraftsRemovesOldDraftsAndKeepsThemInSafetyBackup() throws {
        let url = try archive(db: database())
        let prepared = try FullBackupService.prepare(url: url)
        defer { prepared.cleanup() }
        let drafts = try EditorDraftPersistence(directory: directory())
        try drafts.recordCard(CardDraft(card: Card(front: "旧草稿", back: "答案")))
        let safety = try FullBackupService.restore(prepared, db: database(), draftURL: drafts.fileURL,
                                                  defaults: defaults(), safetyDirectory: directory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.fileURL.path))
        try drafts.reloadFromDisk()
        XCTAssertTrue(drafts.cardDrafts.isEmpty)
        let old = try FullBackupService.prepare(url: safety)
        defer { old.cleanup() }
        XCTAssertEqual(old.counts.cardDrafts, 1)
    }

    func testFailureAtEveryRestorePhaseRollsBackDatabaseDraftsAndPreferences() throws {
        enum Injected: Error { case failure }
        for phase in [FullBackupService.RestorePhase.database, .drafts, .settings] {
            let origin = try database()
            _ = try origin.save(Highlight(text: "准备恢复的库"))
            let originDrafts = try EditorDraftPersistence(directory: directory())
            try originDrafts.recordCard(CardDraft(card: Card(front: "准备恢复的草稿", back: "答案")))
            let originPreferences = defaults(); originPreferences.set(20, forKey: "review.dailyCount")
            let prepared = try FullBackupService.prepare(url: archive(db: origin, drafts: originDrafts, settings: originPreferences))
            defer { prepared.cleanup() }
            let target = try database()
            _ = try target.save(Highlight(text: "原库"))
            try target.saveMedia(["original.mp3": Data("original".utf8)])
            let drafts = try EditorDraftPersistence(directory: directory())
            try drafts.recordHighlight(HighlightDraft(highlight: Highlight(text: "原草稿")))
            let draftBytes = try Data(contentsOf: drafts.fileURL)
            let preferences = defaults(); preferences.set(7, forKey: "review.dailyCount")
            preferences.set("/preserve", forKey: "obsidian.folder")
            let backups = try directory()
            XCTAssertThrowsError(try FullBackupService.restore(prepared, db: target, draftURL: drafts.fileURL,
                defaults: preferences, safetyDirectory: backups, phaseObserver: { current in
                    if current == phase { throw Injected.failure }
                }))
            XCTAssertEqual(try target.highlights(HighlightQuery()).map(\.text), ["原库"])
            XCTAssertEqual(try target.media(named: "original.mp3"), Data("original".utf8))
            XCTAssertEqual(try Data(contentsOf: drafts.fileURL), draftBytes)
            XCTAssertEqual(preferences.integer(forKey: "review.dailyCount"), 7)
            XCTAssertEqual(preferences.string(forKey: "obsidian.folder"), "/preserve")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".kongreviewbackup") }.count, 1)
        }
    }

    func testChecksumTruncationAndTrailingDataAreRejected() throws {
        let original = try Data(contentsOf: archive(db: database()))
        var corrupt = original; corrupt[corrupt.count - 1] ^= 1
        let candidates = [corrupt, original.dropLast(), original + Data([1])]
        for data in candidates {
            let url = try directory().appendingPathComponent("bad.kongreviewbackup")
            try data.write(to: url)
            XCTAssertThrowsError(try FullBackupService.prepare(url: url))
        }
    }

    func testDuplicatePathTraversalUnknownNameAndUnsupportedVersionAreRejected() throws {
        let valid = try FullBackupService.prepare(url: archive(db: database()))
        defer { valid.cleanup() }
        let base = valid.manifest
        var duplicate = base; duplicate.entries.append(duplicate.entries[0])
        var traversal = base; traversal.entries[0].name = "../../escape.sqlite"
        var absolute = base; absolute.entries[0].name = "/tmp/escape.sqlite"
        var unknown = base; unknown.entries[0].name = "another.sqlite"
        var newer = base; newer.formatVersion = 999
        for manifest in [duplicate, traversal, absolute, unknown, newer] {
            let url = try writeContainer(manifest: manifest, payloads: [:])
            XCTAssertThrowsError(try FullBackupService.prepare(url: url))
        }
    }

    func testOversizedManifestAndPayloadAreRejectedWithoutAllocatingClaimedData() throws {
        let url = try directory().appendingPathComponent("huge.kongreviewbackup")
        var header = FullBackupService.magic
        var length = UInt64(FullBackupService.maximumManifestBytes + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        try header.write(to: url)
        XCTAssertThrowsError(try FullBackupService.prepare(url: url))
        let prepared = try FullBackupService.prepare(url: archive(db: database()))
        defer { prepared.cleanup() }
        var manifest = prepared.manifest
        manifest.entries[0].bytes = UInt64.max
        XCTAssertThrowsError(try FullBackupService.prepare(url: writeContainer(manifest: manifest, payloads: [:])))
    }

    func testArchiveSymlinkAndStageSymlinkAreRejected() throws {
        let url = try archive(db: database())
        let link = try directory().appendingPathComponent("link.kongreviewbackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try FullBackupService.prepare(url: link))
        let prepared = try FullBackupService.prepare(url: url)
        defer { prepared.cleanup() }
        let database = prepared.directory.appendingPathComponent("library.sqlite")
        let copy = try directory().appendingPathComponent("copied.sqlite")
        try FileManager.default.moveItem(at: database, to: copy)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: copy)
        XCTAssertThrowsError(try prepared.validateStagedFiles())
    }

    func testUnknownDatabaseSchemaAndCorruptDatabaseAreRejectedEvenWithValidHashes() throws {
        let changed = try database()
        try changed.writer.write { try $0.execute(sql: "CREATE TABLE surprise(secret TEXT)") }
        XCTAssertThrowsError(try FullBackupService.prepare(url: archive(db: changed)))
        let good = try FullBackupService.prepare(url: archive(db: database()))
        defer { good.cleanup() }
        XCTAssertThrowsError(try FullBackupService.prepare(url: repack(good, replacing: ["library.sqlite": Data("not sqlite".utf8)])))
    }

    func testUnknownMigrationAndBrokenForeignKeyAreRejected() throws {
        let unknown = try database()
        try unknown.writer.write { db in
            try db.execute(sql: "UPDATE grdb_migrations SET identifier = 'unknown-new-migration' WHERE identifier = (SELECT identifier FROM grdb_migrations LIMIT 1)")
        }
        XCTAssertThrowsError(try FullBackupService.prepare(url: archive(db: unknown)))
        let orphan = try database()
        try orphan.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO source_cover(sourceId, data, updatedAt) VALUES (9999, ?, ?)", arguments: [Data([1]), Date()])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        XCTAssertThrowsError(try FullBackupService.prepare(url: archive(db: orphan)))
    }

    func testUnavailableDraftDestinationRejectsBeforeReplacingCurrentData() throws {
        let drafts = try EditorDraftPersistence(directory: directory())
        try drafts.recordCard(CardDraft(card: Card(front: "备份草稿", back: "答案")))
        let prepared = try FullBackupService.prepare(url: archive(db: database(), drafts: drafts))
        defer { prepared.cleanup() }
        let target = try database(); _ = try target.save(Highlight(text: "保留当前"))
        let backups = try directory()
        XCTAssertThrowsError(try FullBackupService.restore(prepared, db: target, draftURL: nil,
                                                          defaults: defaults(), safetyDirectory: backups))
        XCTAssertEqual(try target.highlights(HighlightQuery()).map(\.text), ["保留当前"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testMalformedDraftAndUnapprovedPreferencesAreRejectedEvenWithValidHashes() throws {
        let drafts = try EditorDraftPersistence(directory: directory())
        try drafts.recordHighlight(HighlightDraft(highlight: Highlight(text: "草稿")))
        let good = try FullBackupService.prepare(url: archive(db: database(), drafts: drafts))
        defer { good.cleanup() }
        XCTAssertThrowsError(try FullBackupService.prepare(url: repack(good, replacing: ["editor-drafts.json": Data("{}".utf8)])))
        let unsafe = try PropertyListSerialization.data(fromPropertyList: ["obsidian.folder": "/do/not/restore"], format: .binary, options: 0)
        XCTAssertThrowsError(try FullBackupService.prepare(url: repack(good, replacing: ["settings.plist": unsafe])))
        let wrongType = try PropertyListSerialization.data(fromPropertyList: ["review.dailyCount": true], format: .binary, options: 0)
        XCTAssertThrowsError(try FullBackupService.prepare(url: repack(good, replacing: ["settings.plist": wrongType])))
        let wrongValue = try PropertyListSerialization.data(fromPropertyList: ["reminder.hour": 999], format: .binary, options: 0)
        XCTAssertThrowsError(try FullBackupService.prepare(url: repack(good, replacing: ["settings.plist": wrongValue])))
    }

    func testStageTamperIsRejectedBeforeCurrentDataOrSafetyDirectoryChanges() throws {
        let prepared = try FullBackupService.prepare(url: archive(db: database()))
        defer { prepared.cleanup() }
        try Data("tamper".utf8).write(to: prepared.directory.appendingPathComponent("settings.plist"))
        let target = try database(); _ = try target.save(Highlight(text: "保留"))
        let backups = try directory()
        XCTAssertThrowsError(try FullBackupService.restore(prepared, db: target, draftURL: nil, defaults: defaults(), safetyDirectory: backups))
        XCTAssertEqual(try target.highlights(HighlightQuery()).map(\.text), ["保留"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testGlobalAndScopedReviewQueuesReplaceStaleQueuesAndRollbackProtectsThem() throws {
        let origin = defaults()
        let global = Data(#"{"day":"2026-10-17","regularIds":[1,2],"masteryIds":[],"position":1}"#.utf8)
        let scoped = Data(#"{"day":"2026-10-17","regularIds":[3],"masteryIds":[],"position":0}"#.utf8)
        origin.set(global, forKey: "review.session._all")
        origin.set(scoped, forKey: "review.session.主题")
        let prepared = try FullBackupService.prepare(url: archive(db: database(), settings: origin))
        defer { prepared.cleanup() }
        let target = defaults()
        target.set(scoped, forKey: "review.session.旧主题")
        target.set(scoped, forKey: "review.session._all")
        let safety = try FullBackupService.restore(prepared, db: database(), draftURL: nil, defaults: target, safetyDirectory: directory())
        XCTAssertEqual(target.data(forKey: "review.session._all"), global)
        XCTAssertEqual(target.data(forKey: "review.session.主题"), scoped)
        XCTAssertNil(target.object(forKey: "review.session.旧主题"))
        let previous = try FullBackupService.prepare(url: safety)
        defer { previous.cleanup() }
        _ = try FullBackupService.restore(previous, db: database(), draftURL: nil, defaults: target, safetyDirectory: directory())
        XCTAssertEqual(target.data(forKey: "review.session.旧主题"), scoped)
        XCTAssertEqual(target.data(forKey: "review.session._all"), scoped)
        XCTAssertNil(target.object(forKey: "review.session.主题"))
    }

    func testFailedExportDoesNotReplaceExistingArchiveOrLeavePartialFiles() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("keep.kongreviewbackup")
        let sentinel = Data("original backup".utf8)
        try sentinel.write(to: url)
        let preferences = defaults(); preferences.set(-1, forKey: "review.dailyCount")
        XCTAssertThrowsError(try FullBackupService.create(db: database(), draftURL: nil, defaults: preferences, destination: url))
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [url.lastPathComponent])
    }

    func testConsistentSnapshotIncludesUncheckpointedWALAndOldAutomaticBackupsRemain() throws {
        let dir = try directory()
        var config = Configuration()
        config.prepareDatabase { AppDatabase.registerFunctions($0) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("wal.sqlite").path, configuration: config)
        let db = try AppDatabase(pool)
        _ = try db.save(Highlight(text: "WAL 中的新摘录"))
        let url = try archive(db: db)
        let prepared = try FullBackupService.prepare(url: url)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.counts.highlights, 1)
        let backups = try directory()
        let old = backups.appendingPathComponent("review-2026-10-01.sqlite")
        try Data("old automatic backup".utf8).write(to: old)
        _ = try FullBackupService.restore(prepared, db: database(), draftURL: nil, defaults: defaults(), safetyDirectory: backups)
        XCTAssertEqual(try String(contentsOf: old), "old automatic backup")
        try pool.close()
    }

    func testReloadDraftFileClearsOldSessionBaselines() throws {
        let drafts = try EditorDraftPersistence(directory: directory())
        var draft = CardDraft(card: Card(id: 8, front: "旧值", back: "答案"))
        let oldCard = draft.card
        draft.card.front = "旧库未保存"
        try drafts.recordCard(draft, original: oldCard)
        try FileManager.default.removeItem(at: drafts.fileURL)
        try drafts.reloadFromDisk()
        XCTAssertTrue(drafts.cardDrafts.isEmpty)
        var newCard = oldCard; newCard.front = "恢复后的值"
        draft.card = newCard
        try drafts.recordCard(draft, original: newCard)
        XCTAssertTrue(drafts.cardDrafts.isEmpty)
    }

    private func repack(_ prepared: PreparedFullBackup, replacing: [String: Data]) throws -> URL {
        var payloads: [String: Data] = [:]
        for entry in prepared.manifest.entries {
            payloads[entry.name] = try replacing[entry.name] ?? Data(contentsOf: prepared.directory.appendingPathComponent(entry.name))
        }
        var manifest = prepared.manifest
        manifest.entries = manifest.entries.map { entry in
            let data = payloads[entry.name]!
            return .init(name: entry.name, bytes: UInt64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return try writeContainer(manifest: manifest, payloads: payloads)
    }

    private func writeContainer(manifest: FullBackupService.Manifest, payloads: [String: Data]) throws -> URL {
        let body = try JSONEncoder().encode(manifest)
        var output = FullBackupService.magic
        var length = UInt64(body.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(body)
        for entry in manifest.entries { output.append(payloads[entry.name] ?? Data()) }
        let url = try directory().appendingPathComponent("crafted.kongreviewbackup")
        try output.write(to: url)
        return url
    }
}
