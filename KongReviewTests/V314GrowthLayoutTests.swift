import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 3.14：个人成长目录结构与界面预览示例库
final class V314GrowthLayoutTests: XCTestCase {
    func testContentsCoverEveryGrowthTabOnceInNumberedParts() {
        let sections = GrowthPart.all.flatMap(\.sections)
        XCTAssertEqual(Set(sections.map(\.tab)), Set(0...8), "九个页面都在目录里")
        XCTAssertEqual(sections.count, 9, "每个页面只出现一次")
        XCTAssertEqual(GrowthPart.all.map(\.number), ["一", "二", "三"])
        for (index, part) in GrowthPart.all.enumerated() {
            XCTAssertEqual(part.sections.map(\.number), (1...part.sections.count).map { "\(index + 1).\($0)" }, "节号按部分连续编号")
        }
        XCTAssertEqual(GrowthPart.section(for: 0).section.title, "学习小结")
        XCTAssertEqual(GrowthPart.section(for: 8).part.title, "计划与执行")
        XCTAssertEqual(GrowthPart.section(for: 99).section.tab, 0, "未知页面回到学习小结")
    }

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
