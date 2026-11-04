import XCTest
@testable import KongReviewCore

/// 6.0.2：点一下就更新——编译输出的进度、README 里的版本说明、project.yml 的版本号、代理、本地改动
final class V602SourceUpdateTests: XCTestCase {
    func testFollowsATwoPartTestRunAndBuild() {
        var p = BuildLogProgress(expectedTests: 4)
        XCTAssertEqual(p.stage, .starting)
        p.consume("== KongReview build 2026-11-03 11:30:00 ==")
        p.consume("== tests ==")
        XCTAssertEqual(p.stage, .buildingTests)
        p.consume("[5 / 20] Compiling KongReview AppUpdater.swift")
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(p.detail, "正在编译测试（5 / 20）")
        p.consume("[2/40] Compiling KongReviewCore Update.swift")
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.001, "编译核心包测试时进度不后退")
        // 核心包
        p.consume("Test Suite 'All tests' started at 2026-11-03 11:31:00.000.")
        XCTAssertEqual(p.stage, .runningTests)
        p.consume("Test Case '-[KongReviewCoreTests.A testOne]' passed (0.005 seconds).")
        // 应用
        p.consume("Test Suite 'All tests' started at 2026-11-03 11:31:05.000.")
        p.consume("Test Case '-[KongReviewTests.B testTwo]' passed (0.005 seconds).")
        p.consume("Test Case '-[KongReviewTests.B testThree]' failed (0.005 seconds).")
        XCTAssertEqual(p.testsRun, 3, "两段测试累计")
        XCTAssertEqual(p.failedTests, ["B testThree"])
        XCTAssertEqual(p.detail, "测试：已通过 2 / 4 项，1 项未通过")
        XCTAssertEqual(p.fraction, 0.75, accuracy: 0.001)
        let before = p.overall
        p.consume("== compile ==")
        XCTAssertEqual(p.stage, .compiling)
        XCTAssertGreaterThanOrEqual(p.overall, before)
        p.consume("[10/40] Compiling KongReview HomeView.swift")
        XCTAssertEqual(p.detail, "正在编译新版本（10 / 40）")
        p.consume("== tests ==")
        XCTAssertEqual(p.stage, .compiling, "阶段不后退")
        p.consume("== icon ==")
        XCTAssertEqual(p.stage, .packaging)
        p.consume("== sign ==")
        XCTAssertEqual(p.detail, "正在签名…")
        p.consume("Built: /Users/k/Developer/KongReview/build/KongReview.app")
        XCTAssertEqual(p.stage, .finished)
        XCTAssertEqual(p.overall, 1)
    }

    func testCompileErrorsAndTestFailures() {
        let line = "/Users/k/Developer/KongReview/KongReview/Services/AppUpdater.swift:286:24: \u{1B}[1;31merror: \u{1B}[1;39mcannot find 'x' in scope\u{1B}[0;0m [#\u{1B}]8;;https://docs.swift.org/x\u{1B}\\X\u{1B}]8;;\u{1B}\\]"
        var p = BuildLogProgress()
        p.consume("== tests ==")
        p.consume(line)
        p.consume(line)
        p.consume("error: SwiftCompile normal arm64 /Users/k/AppUpdater.swift failed with a nonzero exit code.")
        XCTAssertEqual(p.compileErrors, ["AppUpdater.swift 第 286 行：cannot find 'x' in scope"])
        XCTAssertNil(BuildLogProgress.compileError("error: Build failed"))

        var q = BuildLogProgress()
        q.consume("== tests ==")
        q.consume("Test Suite 'All tests' started at 2026-11-03 11:31:00.000.")
        q.consume("/Users/k/Developer/KongReview/KongReviewTests/V601SlimTests.swift:48: error: -[KongReviewTests.V601SlimTests testExports] : XCTAssertEqual failed: (\"2\") is not equal to (\"1\")")
        q.consume("Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range")
        XCTAssertTrue(q.compileErrors.isEmpty)
        XCTAssertEqual(q.failedTests, ["V601SlimTests testExports"])
        XCTAssertEqual(q.testFailures, ["V601SlimTests.swift 第 48 行：XCTAssertEqual failed: (\"2\") is not equal to (\"1\")"])
        XCTAssertTrue(q.testsCrashed)
        XCTAssertNil(BuildLogProgress.stepCounter("[4 / 3]"))
        XCTAssertEqual(BuildLogProgress.testName("Test Case '-[KongReviewTests.V601SlimTests testX]' failed (0.02 seconds)."), "V601SlimTests testX")
    }

    func testVersionAndNotes() {
        let yml = "name: KongReview\nsettings:\n  base:\n    MARKETING_VERSION: \"6.0.2\"\n    CURRENT_PROJECT_VERSION: \"1\"\n"
        XCTAssertEqual(ReleaseNotes.version(inProjectYML: yml), "6.0.2")
        XCTAssertNil(ReleaseNotes.version(inProjectYML: "name: x"))

        let readme = """
        # KongReview

        说明。

        ## 6.0.2 点一下就更新（6.0 第三步）

        - **更新**：点一下。

        ## 6.0.1 精简为“考场”

        - 精简。

        ## 6.0.0 卡片模板的 HTML 编辑

        - 模板。

        ## 构建方法

        - 不是版本。
        """
        let s = ReleaseNotes.sections(in: readme, newerThan: "6.0.0")
        XCTAssertEqual(s.map(\.version), ["6.0.2", "6.0.1"])
        XCTAssertEqual(s.first?.title, "点一下就更新（6.0 第三步）")
        XCTAssertEqual(s.first?.body, "- **更新**：点一下。")
        XCTAssertEqual(ReleaseNotes.sections(in: readme, newerThan: "6.0.2"), [])
        XCTAssertEqual(ReleaseNotes.sections(in: readme, newerThan: "预览").count, 3, "本机版本读不出时全列")
        XCTAssertEqual(ReleaseNotes.sections(in: readme, newerThan: "5.0", limit: 1).map(\.version), ["6.0.2"])
    }

    func testProxy() {
        XCTAssertEqual(ProxySettings.normalized("127.0.0.1:7890"), "http://127.0.0.1:7890")
        XCTAssertEqual(ProxySettings.normalized(" socks5://127.0.0.1:7891 "), "socks5://127.0.0.1:7891")
        XCTAssertNil(ProxySettings.normalized(""))
        XCTAssertNil(ProxySettings.normalized("ftp://x"))
        XCTAssertNil(ProxySettings.normalized("a b"))
        XCTAssertEqual(ProxySettings.gitProxy(fromSystem: ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]), "http://127.0.0.1:7890")
        XCTAssertEqual(ProxySettings.gitProxy(fromSystem: ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891]), "socks5h://127.0.0.1:7891")
        XCTAssertNil(ProxySettings.gitProxy(fromSystem: ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1"]))
        XCTAssertTrue(ProxySettings.isConnectionFailure("fatal: unable to access: Failed to connect to github.com port 443"))
        XCTAssertFalse(ProxySettings.isConnectionFailure("fatal: couldn't find remote ref main"))
    }

    func testLocalChanges() {
        let published: [String: Set<String>] = ["a.swift": ["h1", "h2"], "b.swift": ["h3"]]
        let local: [(path: String, hash: String)] = [("a.swift", "h1"), ("b.swift", "hX"), ("c.swift", "h4"), ("notes.txt", "h5")]
        XCTAssertEqual(SourceLocalChanges.conflicts(local: local, tracked: ["a.swift", "b.swift", "c.swift"], published: published),
                       ["b.swift", "c.swift"], "与已发布版本相同的可以覆盖；改过的、跟踪中但从未发布的不行；未跟踪的新文件不动")
    }

    /// 6.3：同一份源码在本机测过时 build-app.sh 跳过测试，进度直接越过测试段
    func testSkippedTests() {
        var p = BuildLogProgress(expectedTests: 600)
        p.consume("== tests ==")
        p.consume("这份源码（树 abc1234）已在本机用同一版 Swift 测过、全部通过，这次不再测。")
        XCTAssertEqual(p.stage, .runningTests)
        XCTAssertEqual(p.detail, "这份源码已在本机测过、全部通过，不再测一遍")
        XCTAssertEqual(p.overall, 0.55, accuracy: 0.001)
        p.consume("== compile ==")
        XCTAssertEqual(p.stage, .compiling)
        XCTAssertEqual(p.testsRun, 0)
    }
}
