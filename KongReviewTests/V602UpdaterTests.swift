import XCTest
import KongReviewCore
@testable import KongReview

/// 6.0.2：点一下就更新——测试进程里不动源码、不安装；失败原因的说法
final class V602UpdaterTests: XCTestCase {
    func testTestProcessNeverUpdates() {
        MainActor.assumeIsolated {
            let u = AppUpdater.shared
            XCTAssertFalse(u.canInstall, "测试进程不是正式安装的应用")
            u.check(manual: true)
            XCTAssertTrue(u.showsPanel)
            XCTAssertEqual(u.phase, .failed("这是预览版或开发构建，不能就地更新。"))
            u.update()
            XCTAssertNil(u.progress, "不开始更新")
            u.showsPanel = false
            u.phase = .idle
            XCTAssertFalse(u.hasUpdate)
            XCTAssertTrue(AppUpdater.sourceRoot.path.hasSuffix("/Developer/KongReview"))
            XCTAssertTrue(AppUpdater.runningBackupName.hasPrefix("KongReview-"))
        }
    }

    func testFailureMessages() {
        var b = BuildLogProgress()
        b.consume("== tests ==")
        b.consume("Test Suite 'All tests' started at 2026-11-03 11:31:00.000.")
        b.consume("/x/V601SlimTests.swift:48: error: -[KongReviewTests.V601SlimTests testExports] : XCTAssertTrue failed")
        let m = AppUpdater.buildFailure(b)
        XCTAssertTrue(m.hasPrefix("有 1 项测试未通过（V601SlimTests testExports）"))
        XCTAssertTrue(m.contains("当前安装的版本没有改动"))
        XCTAssertTrue(m.contains("V601SlimTests.swift 第 48 行"))

        var c = BuildLogProgress()
        c.consume("== compile ==")
        c.consume("/x/HomeView.swift:12:3: error: cannot find 'y' in scope")
        XCTAssertTrue(AppUpdater.buildFailure(c).contains("编译失败，已停止；当前安装的版本没有改动。\nHomeView.swift 第 12 行"))
        XCTAssertTrue(AppUpdater.buildFailure(BuildLogProgress()).contains("详情见构建日志"))

        XCTAssertTrue(AppUpdater.fetchFailure("Could not resolve host: github.com", first: false).contains("连不上 GitHub"))
        XCTAssertEqual(AppUpdater.fetchFailure("fatal: something else", first: true), "从 GitHub 下载源码失败（详情见更新日志）。")
    }

    func testEnsureSourceRefusesForeignFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v602-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("别的文件.txt"))
        XCTAssertThrowsError(try AppUpdater.ensureSource(dir)) { error in
            XCTAssertTrue(AppUpdater.describe(error).contains("不是 KongReview 的源码"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("别的文件.txt").path), "不动别的文件")
    }
}
