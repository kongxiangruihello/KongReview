import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.1.1：用真实学习库的完整备份量几项较重的计算。
/// 只有设了环境变量 KONGREVIEW_REAL_BACKUP（指向一份 .kongreviewbackup）时才跑，否则跳过；
/// 测试脚本在“文稿”里有“KongReview预览用备份.kongreviewbackup”时设上。只读备份，在临时目录的副本上算。
final class V611RealLibraryTimingTests: XCTestCase {
    private func clock<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try body()
        print(String(format: "实库用时｜%@：%.2f 秒", name, Date().timeIntervalSince(start)))
        return value
    }

    func testRealLibraryTimings() throws {
        let path = ProcessInfo.processInfo.environment["KONGREVIEW_REAL_BACKUP"] ?? ""
        try XCTSkipIf(path.isEmpty || !FileManager.default.fileExists(atPath: path), "没有设 KONGREVIEW_REAL_BACKUP")
        try MainActor.assumeIsolated {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("kongreview-real-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let suite = "kongreview.realtiming.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = try clock("解开备份并打开副本") {
                try PreviewLibrary.makeStore(backup: URL(fileURLWithPath: path), workRoot: work, defaults: defaults)
            }
            let db = store.db
            let counts = try db.writer.read { d in
                (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM highlight WHERE deletedAt IS NULL") ?? 0,
                 try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM card") ?? 0,
                 try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM self_test_log") ?? 0)
            }
            print("实库规模｜摘录 \(counts.0) 条，记忆卡 \(counts.1) 张，卷面作答记录 \(counts.2) 条")
            let now = Date()
            let annotate = try clock("今日标注抽篇（6.0.4）") { try db.annotateToday(count: 5, now: now) }
            print("实库结果｜今日标注 \(annotate.items.count) 篇")
            _ = try clock("年报（6.0.5）") { try db.gradebookReport(GrowthPeriod.year.window(containing: now, now: now), now: now) }
            _ = try clock("月报") { try db.gradebookReport(GrowthPeriod.month.window(containing: now, now: now), now: now) }
            _ = try clock("每日成绩（本月）") { try db.gradebookMonth(containing: now, now: now) }
            _ = try clock("掌握度走势（12 周）") { try db.masteryTrend(weeks: 12, now: now) }
            let weak = try clock("常错的题") { try db.weakItems(now: now) }
            print("实库结果｜常错的题 \(weak.values.reduce(0) { $0 + $1.count }) 道")
            let queue = try clock("札记、笔记、问题到期") { try db.revisitQueue(now: now) }
            print("实库结果｜札记 \(queue.notes.count)、笔记 \(queue.blocks.count)、进展题 \(queue.questions.count)、解答题 \(queue.answers.count)")
            store.refreshRevisit()
            let paper = clock("组今日试卷") { store.examPaper(now: now) }
            print("实库结果｜今日试卷可出 \(paper.available.count) 类")
        }
    }
}
