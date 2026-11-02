import XCTest
@testable import KongReviewCore

/// 5.2.1：在线更新——版本比较、发布信息解析、进度文字、安装脚本
final class V521UpdateTests: XCTestCase {
    func testVersionCompare() {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        XCTAssertLessThan(v("5.2.0"), v("5.2.1"))
        XCTAssertLessThan(v("5.9"), v("5.10"), "按数字比较，不按字符")
        XCTAssertEqual(v("5.2"), v("5.2.0"), "缺的段按 0 计")
        XCTAssertEqual(v("v5.2.1"), v("5.2.1"))
        XCTAssertEqual(v("KongReview 5.2.1").description, "5.2.1")
        XCTAssertLessThan(v("4.99.99"), v("5"))
        XCTAssertNil(AppVersion("预览"))
        XCTAssertNil(AppVersion(""))
    }

    private func json(tag: String = "v5.2.1", draft: Bool = false, assets: String? = nil) -> Data {
        let a = assets ?? """
            [{"name":"KongReview-5.2.1-src.tar.gz","browser_download_url":"https://example.com/src.tgz","size":10},
             {"name":"KongReview-5.2.1.dmg","browser_download_url":"https://github.com/kongxiangruihello/KongReview/releases/download/v5.2.1/KongReview-5.2.1.dmg","size":13200225,"digest":"sha256:ABCDEF0123"}]
            """
        return Data("""
            {"tag_name":"\(tag)","name":"5.2.1","draft":\(draft),"prerelease":false,
             "body":"- 日评分\\n- 在线更新","published_at":"2026-11-03T02:00:00Z",
             "html_url":"https://github.com/kongxiangruihello/KongReview/releases/tag/\(tag)","assets":\(a)}
            """.utf8)
    }

    func testParseRelease() throws {
        let r = try UpdateRelease.parse(json())
        XCTAssertEqual(r.version.description, "5.2.1")
        XCTAssertEqual(r.tag, "v5.2.1")
        XCTAssertEqual(r.dmgName, "KongReview-5.2.1.dmg", "取 .dmg，不取源码包")
        XCTAssertEqual(r.dmgSize, 13_200_225)
        XCTAssertEqual(r.sha256, "abcdef0123", "摘要去掉前缀并转小写")
        XCTAssertEqual(r.notes, "- 日评分\n- 在线更新")
        XCTAssertNotNil(r.publishedAt)
        XCTAssertEqual(r.pageURL?.lastPathComponent, "v5.2.1")
    }

    func testParseErrors() {
        XCTAssertThrowsError(try UpdateRelease.parse(Data("oops".utf8))) { XCTAssertEqual($0 as? UpdateRelease.ParseError, .notJSON) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(tag: "latest"))) { XCTAssertEqual($0 as? UpdateRelease.ParseError, .notVersion("latest")) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(draft: true))) { XCTAssertEqual($0 as? UpdateRelease.ParseError, .draft) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(assets: "[]"))) { XCTAssertEqual($0 as? UpdateRelease.ParseError, .noDMG("v5.2.1")) }
        // 没有摘要也能解析
        let noDigest = try? UpdateRelease.parse(json(assets: #"[{"name":"KongReview-5.2.1.dmg","browser_download_url":"https://example.com/a.dmg","size":5}]"#))
        XCTAssertNil(noDigest?.sha256)
        XCTAssertEqual(noDigest?.dmgSize, 5)
    }

    func testProgressText() {
        let mb: Int64 = 1_048_576
        XCTAssertEqual(UpdateProgressText.line(received: 3 * mb, total: 12 * mb, bytesPerSecond: nil), "3.0 / 12.0 MB")
        XCTAssertEqual(UpdateProgressText.line(received: 3 * mb, total: 12 * mb, bytesPerSecond: Double(mb)), "3.0 / 12.0 MB · 1.0 MB/s · 约 9 秒")
        XCTAssertEqual(UpdateProgressText.line(received: 0, total: 120 * mb, bytesPerSecond: Double(mb)), "0.0 / 120.0 MB · 1.0 MB/s · 约 2 分 0 秒")
        XCTAssertEqual(UpdateProgressText.line(received: 2 * mb, total: 0, bytesPerSecond: nil), "2.0 MB")
    }

    func testInstallScript() {
        let s = UpdateInstallScript.make(pid: 4242, source: "/Users/k/Library/Caches/KongReview-updates/新版/KongReview.app",
                                         target: "/Applications/KongReview.app",
                                         backup: "/Users/k/Library/Caches/KongReview-updates/上一版/KongReview.app",
                                         dmgMount: nil, log: "/tmp/log's.log")
        XCTAssertTrue(s.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(s.contains("kill -0 4242"), "等应用退出")
        XCTAssertTrue(s.contains("mv '/Applications/KongReview.app' '/Users/k/Library/Caches/KongReview-updates/上一版/KongReview.app'"), "旧版移到后备处")
        XCTAssertTrue(s.contains("ditto '/Users/k/Library/Caches/KongReview-updates/新版/KongReview.app' '/Applications/KongReview.app'"))
        XCTAssertTrue(s.contains("复制新版失败，恢复旧版"), "复制失败时放回旧版")
        XCTAssertTrue(s.contains("xattr -cr '/Applications/KongReview.app'"))
        XCTAssertTrue(s.hasSuffix("open '/Applications/KongReview.app'\n"), "最后重新打开")
        XCTAssertTrue(s.contains(#"'/tmp/log'\''s.log'"#), "单引号转义")
        XCTAssertFalse(s.contains("hdiutil"), "不传挂载点就不卸载")
        XCTAssertTrue(UpdateInstallScript.make(pid: 1, source: "a", target: "b", backup: "c", dmgMount: "/Volumes/x", log: "l").contains("hdiutil detach '/Volumes/x'"))
    }
}
