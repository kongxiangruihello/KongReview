import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 5.2.1：日评分——掌握度、推进、自评与锁定、合成总分；在线更新的状态
final class V521DailyScoreTests: XCTestCase {
    private let t0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    private func d(_ n: Int, hour: Int = 0) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: n, to: t0)!)!
    }
    private var today: String { AppDatabase.revisitDay(t0) }

    func testTotalFormula() {
        var s = DailyScore(day: "x", completion: 0.5, mastery: MasteryTally(good: 4, mid: 2, bad: 0))
        XCTAssertNil(s.total, "没有自评不出总分")
        s.selfScore = .five
        // 掌握度 (4 + 1) / 6 = 0.8333…；0.5×40 + 0.8333×40 + 1×20 = 73.3
        XCTAssertEqual(s.total, 73)
        s.mastery = MasteryTally(good: 2, mid: 0, bad: 1)
        XCTAssertNil(s.mastery.ratio, "不足 5 条不算掌握度")
        XCTAssertEqual(s.total, 65, "完成 70 · 自评 30：0.5×70 + 1×30")
        s.completion = nil
        s.selfScore = .three
        XCTAssertEqual(s.total, 50, "只看自评：3 分折为 0.5")
        s.mastery = MasteryTally(good: 5, mid: 0, bad: 0)
        XCTAssertEqual(s.total, 85, "掌握 70 · 自评 30：1×70 + 0.5×30")
        XCTAssertEqual(SelfScore.one.fraction, 0)
        XCTAssertEqual(SelfScore.four.fraction, 0.75)
    }

    func testMasteryFromCardsSelfTestsAndBlocks() throws {
        let db = try AppDatabase(DatabaseQueue())
        // 记忆卡：每张取当天第一次评分
        let cards = try (0..<4).map { try db.save(Card(deck: "默认", front: "问\($0)", back: "答")) }
        func rate(_ c: Card, _ a: CardAnswer, _ hour: Int) { db.log(ReviewEvent(kind: .card, cardId: c.id, answer: a.rawValue, at: d(0, hour: hour))) }
        rate(cards[0], .again, 0); rate(cards[0], .good, 1)   // 第一次重来 → 差
        rate(cards[1], .hard, 0)                               // 中
        rate(cards[2], .easy, 0)                               // 好
        rate(cards[3], .good, 0)                               // 好
        db.log(ReviewEvent(kind: .card, cardId: cards[3].id, answer: CardAnswer.again.rawValue, at: d(-1)))  // 昨天的不算
        // 自测：记得、忘了
        let src = try db.save(Source(title: "国史大纲"))
        var h = Highlight(text: "对本国历史应略有所知"); h.sourceId = src.id; h.isFavorite = true
        h = try db.save(h)
        var h2 = Highlight(text: "温故而知新"); h2.sourceId = src.id; h2.isFavorite = true
        h2 = try db.save(h2)
        let week = GrowthPeriod.week.window(containing: t0, now: t0)
        try db.recordSelfTest(SelfTestItem(kind: .source, recordId: h.id!), result: .remembered, week: week, now: d(0, hour: 2))
        try db.recordSelfTest(SelfTestItem(kind: .gist, recordId: h2.id!), result: .forgot, week: week, now: d(0, hour: 2))
        // 笔记：已吸收、需重读、待整理（不计）
        let nb = try db.createNotebook(title: "笔记", now: d(-30))
        let text = String(repeating: "乾嘉考据重建义理", count: 4)
        let blocks = try db.insertBlocks((0..<3).map { NotebookBlock(notebookId: nb.id!, position: Double($0), kind: .text, text: text + "\($0)") },
                                         into: nb.id!, after: nil, now: d(-30))
        try db.recordBlockRevisit(blockId: blocks[0].id!, outcome: .absorbed, now: d(0, hour: 3))
        try db.recordBlockRevisit(blockId: blocks[1].id!, outcome: .reread, now: d(0, hour: 3))
        try db.recordBlockRevisit(blockId: blocks[2].id!, outcome: .organize, now: d(0, hour: 3))

        let s = try db.dailyScore(day: today, now: d(0, hour: 4))
        XCTAssertEqual(s.mastery, MasteryTally(good: 4, mid: 1, bad: 3))
        XCTAssertEqual(try XCTUnwrap(s.mastery.ratio), 4.5 / 8, accuracy: 1e-9)
        XCTAssertEqual(s.progress.blocksToOrganize, 1)
        XCTAssertFalse(s.locked)
        XCTAssertTrue(try db.dailyScore(day: today, now: d(1)).locked, "第二天看是只读")
    }

    func testProgressTally() throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Highlight(text: "甲")), b = try db.save(Highlight(text: "乙"))
        db.log(ReviewEvent(kind: .favorite, highlightId: a.id, at: d(0)))
        db.log(ReviewEvent(kind: .favorite, highlightId: a.id, at: d(0, hour: 1)))
        db.log(ReviewEvent(kind: .discard, highlightId: b.id, at: d(0)))
        let note = try db.createIdeaNote(title: "士由身份转为德行", body: "<p>甲</p>", now: d(-10))
        try db.recordNoteRevisit(noteId: note.id!, outcome: .revise, now: d(0))
        try db.saveIdeaNote(id: note.id!, title: note.title, body: "<p>甲乙</p>", now: d(0, hour: 1))   // 同一条只算一次
        let q = try db.createQuestion(title: "士志于道何解？", now: d(-10))
        try db.recordQuestionRevisit(questionId: q.id!, outcome: .lead, now: d(0))
        try db.recordQuestionRevisit(questionId: q.id!, outcome: .notyet, now: d(0, hour: 1))
        let p = try db.dailyScore(day: today, now: d(0, hour: 2)).progress
        XCTAssertEqual(p, ProgressTally(notesRevised: 1, questionsMoved: 1, favorited: 1, discarded: 1, blocksToOrganize: 0))
        XCTAssertEqual(p.total, 4)
        XCTAssertEqual(p.lines, ["修订札记 1", "问题有进展 1", "收藏摘录 1", "弃置摘录 1"])
    }

    func testSelfScoreSaveLockAndCompletion() throws {
        let db = try AppDatabase(DatabaseQueue())
        _ = try db.dailyCheck(current: [.review: DailyCheckCount(done: 3, left: 7)], now: t0)
        try db.saveSelfScore(.four, note: "  读通了戴震一段  ", now: d(0, hour: 2))
        var s = try db.dailyScore(day: today, now: d(0, hour: 3))
        XCTAssertEqual(s.selfScore, .four)
        XCTAssertEqual(s.note, "读通了戴震一段", "去掉首尾空白")
        XCTAssertEqual(try XCTUnwrap(s.completion), 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.total, 44, "缺掌握度：0.3×70 + 0.75×30 = 43.5，四舍五入")
        // 当天可改
        try db.saveSelfScore(.two, note: "", now: d(0, hour: 5))
        s = try db.dailyScore(day: today, now: d(0, hour: 6))
        XCTAssertEqual(s.selfScore, .two)
        // 次日锁定
        XCTAssertThrowsError(try db.saveSelfScore(.five, note: "补写", day: today, now: d(1)))
        XCTAssertEqual(try db.dailyScore(day: today, now: d(1)).selfScore, .two)
        // 近 7 天：旧的在前，最后一天是今天
        let recent = try db.recentDailyScores(days: 7, now: d(0, hour: 6))
        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.last?.day, today)
        XCTAssertEqual(recent.last?.selfScore, .two)
        XCTAssertNil(recent.first?.selfScore)
    }

    func testStoreSaveSelfScoreAndUpdaterState() throws {
        try MainActor.assumeIsolated {
            let store = LibraryStore(db: try AppDatabase(DatabaseQueue()))
            let before = store.dailyCheckRevision
            store.saveSelfScore(.three, note: "平常")
            XCTAssertGreaterThan(store.dailyCheckRevision, before)
            XCTAssertEqual(try store.db.dailyScore(day: AppDatabase.revisitDay(Date())).selfScore, .three)

            // 在线更新：测试进程不是正式安装的应用，不能就地安装，也不自动检查
            let u = AppUpdater.shared
            XCTAssertFalse(u.canInstall)
            u.checkIfDue()
            XCTAssertEqual(u.phase, .idle, "开发构建不自动检查")
        }
    }

    func testVerifyDownloadSizeAndDigest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("KongReview-9.9.9.dmg")
        try Data("abc".utf8).write(to: f)
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"   // “abc”的 SHA-256
        XCTAssertEqual(try AppUpdater.sha256(of: f), sha)
        func release(size: Int64, digest: String?) -> UpdateRelease {
            UpdateRelease(version: AppVersion("9.9.9")!, tag: "v9.9.9", notes: "", publishedAt: nil, pageURL: nil,
                          dmgName: "KongReview-9.9.9.dmg", dmgURL: URL(string: "https://example.com/a.dmg")!, dmgSize: size, sha256: digest)
        }
        XCTAssertNoThrow(try AppUpdater.verifyDownload(f, release: release(size: 3, digest: sha)))
        XCTAssertNoThrow(try AppUpdater.verifyDownload(f, release: release(size: 3, digest: nil)))
        XCTAssertThrowsError(try AppUpdater.verifyDownload(f, release: release(size: 4, digest: nil)), "大小不对")
        XCTAssertThrowsError(try AppUpdater.verifyDownload(f, release: release(size: 3, digest: String(repeating: "0", count: 64))), "校验码不对")
    }
}
