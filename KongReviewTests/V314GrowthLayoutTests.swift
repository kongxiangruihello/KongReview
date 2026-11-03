import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 3.14：界面预览示例库（6.0.5 起个人成长页并入成绩册，目录结构的测试随之拿掉）
final class V314GrowthLayoutTests: XCTestCase {
    func testPreviewLibraryIsInMemoryAndShowsBothDoneAndPending() throws {
        try MainActor.assumeIsolated {
            let keys = [ReviewSessionRecord.key(theme: nil), SettingsKeys.dailyCount, AnnotateSettings.perDayKey]
            let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, saved) {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            XCTAssertFalse(PreviewLibrary.isEnabled, "测试宿主不是预览应用")
            let store = PreviewLibrary.makeStore()
            XCTAssertEqual(store.db.fileSize(), 0, "示例库只在内存中")
            store.refreshDerivedLibrary()
            let home = store.homeLearningSummary
            XCTAssertEqual(home.reviewCompletedCount, 4)
            XCTAssertEqual(home.reviewPendingCount, 6)
            XCTAssertGreaterThan(home.cardsStudiedCount, 0)
            XCTAssertGreaterThan(home.cardsDueCount, 0)
            let week = GrowthPeriod.week.window(containing: Date())
            XCTAssertEqual(try store.db.progressValue(GrowthReflection.self, key: week.key)?.goalCards, 40)
            // 6.0.4：今日标注三篇；以前在别处划过的两篇不抽
            store.refreshAnnotate()
            XCTAssertEqual(store.annotate.items.count, 3)
            XCTAssertFalse(store.annotate.items.contains { $0.title.hasPrefix("已在别处划过") || $0.title.hasPrefix("论语学而章疏") })
        }
    }
}
