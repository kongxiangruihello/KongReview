import AppKit
import ApplicationServices
import KongReviewCore

// MARK: - 1.3：系统“服务”菜单

/// 在任何应用里选中文字 → 右键 →“服务”：
/// - “添加到 KongReview”：打开快速录入浮窗，正文为选中的文字（保留格式），出处尽量自动填：
///   浏览器取当前网页地址，其他应用（预览、Word、Pages…）取前台窗口标题（文件名，去掉扩展名；需要辅助功能权限）。
/// - “在 KongReview 中查引文”：打开引文速查浮窗，以选中的文字为关键词。
///
/// 服务在 Info.plist 的 NSServices 里声明（见 Tools/build-dmg.sh），由这里的方法响应。
/// 方法签名是系统约定的：(NSPasteboard, userData, error)。
@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    static func install() {
        NSApp.servicesProvider = shared
        // 让系统重新读取服务列表（刚装好新版本时“服务”菜单里马上就有）
        NSUpdateDynamicServices()
    }

    @objc func addHighlight(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = RichClipboard.markdown(pboard)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            error?.pointee = "没有选中文字。" as NSString
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        // 发起服务的应用此刻正等着服务返回：读它的窗口标题、网址要等服务方法返回之后再做，否则会互相等待而卡住
        DispatchQueue.main.async {
            var request = CaptureRequest(text: text)
            if let id = front?.bundleIdentifier, BrowserWatcher.browsers[id] != nil,
               let page = BrowserWatcher.shared.currentPage() {
                request.url = page.url.absoluteString
                request.title = Self.windowTitle(of: front) ?? page.url.host
            } else if let title = Self.windowTitle(of: front) {
                request.title = Self.documentName(title)
            }
            AppLog.write("服务：添加到 KongReview（来自 \(front?.localizedName ?? "未知应用")）")
            QuickCaptureController.shared.show(prefill: request)
        }
    }

    /// 前台应用最前面窗口的标题（需要辅助功能权限；没有权限返回 nil）
    static func windowTitle(of app: NSRunningApplication?) -> String? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let t = title as? String else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 窗口标题 → 文档名：去掉“ — 已编辑”“（第 3 页，共 200 页）”等尾巴和扩展名
    static func documentName(_ title: String) -> String {
        var t = title
        for sep in [" — ", " - ", "（第", "(page", "（页"] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        let ext = (t as NSString).pathExtension.lowercased()
        if ["pdf", "docx", "doc", "pages", "epub", "txt", "md", "rtf", "key", "numbers"].contains(ext) {
            t = (t as NSString).deletingPathExtension
        }
        return t
    }
}
