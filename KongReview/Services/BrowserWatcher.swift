import AppKit
import KongReviewCore

/// 记住最近一次在前台的浏览器，存档网页时自动读取它当前标签页的网址。
///
/// 读取方式是 AppleScript（Apple 事件）：
/// - Safari：`URL of current tab of front window`
/// - Chrome / Edge / Brave / Arc / Vivaldi / Opera（Chromium 系）：`URL of active tab of front window`
/// 第一次读取时 macOS 会弹窗询问“是否允许 KongReview 控制 Safari/Chrome”，允许后才能读到；
/// 拒绝或浏览器不支持（如 Firefox）时退回到读剪贴板。权限可在“系统设置 → 隐私与安全性 → 自动化”里改。
@MainActor
final class BrowserWatcher {
    static let shared = BrowserWatcher()

    enum Dialect { case safari, chromium }

    static let browsers: [String: (name: String, dialect: Dialect)] = [
        "com.apple.Safari": ("Safari", .safari),
        "com.apple.SafariTechnologyPreview": ("Safari 技术预览版", .safari),
        "com.google.Chrome": ("Chrome", .chromium),
        "com.google.Chrome.canary": ("Chrome Canary", .chromium),
        "com.microsoft.edgemac": ("Edge", .chromium),
        "com.brave.Browser": ("Brave", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("Opera", .chromium),
    ]

    /// 最近在前台的浏览器 bundle id
    private(set) var lastBrowser: String?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers[id] != nil { lastBrowser = id }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated {
                if let id, BrowserWatcher.browsers[id] != nil { BrowserWatcher.shared.lastBrowser = id }
            }
        }
    }

    /// 当前（或最近）浏览器正在看的网页；读不到返回 nil
    func currentPage() -> (url: URL, browser: String)? {
        var candidates: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers[front] != nil {
            candidates.append(front)
        }
        if let last = lastBrowser, !candidates.contains(last) { candidates.append(last) }
        for id in candidates {
            guard let info = Self.browsers[id],
                  !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { continue }
            let property = info.dialect == .safari ? "URL of current tab of front window" : "URL of active tab of front window"
            let source = """
            tell application id "\(id)"
                if (count of windows) > 0 then return \(property)
            end tell
            return ""
            """
            var error: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue,
                  error == nil,
                  let url = CaptureRequest.normalizeWebURL(result),
                  result.lowercased().hasPrefix("http") else { continue }
            return (url, info.name)
        }
        return nil
    }
}
