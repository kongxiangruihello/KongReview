import AppKit
import WebKit
import CoreText
import KongReviewCore

// MARK: - 1.6：HTML → PDF（专题笔记本导出 PDF）

/// 用 WebKit 把排好版的 HTML 分页打印成 A4 的 PDF，再补画页眉（标题）与页脚（页码）。
///
/// 做法：离屏窗口里放一个 WKWebView 载入 HTML → NSPrintOperation 以“存为文件”的方式打印（不弹打印面板）
/// → 用 Core Graphics 逐页重绘一遍，加上页眉页码（封面页不加页眉）。
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var html = ""
    private var title = ""
    private var target: URL?
    private var tmp: URL?
    private var completion: ((Error?) -> Void)?
    /// 导出进行中时保持自身存活
    private static var running: [PDFExporter] = []

    static let a4 = NSSize(width: 595.28, height: 841.89)
    static let margin = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)

    static func export(html: String, title: String, to url: URL, completion: @escaping (Error?) -> Void) {
        let e = PDFExporter()
        running.append(e)
        e.start(html: html, title: title, to: url) { err in
            completion(err)
            running.removeAll { $0 === e }
        }
    }

    private func start(html: String, title: String, to url: URL, completion: @escaping (Error?) -> Void) {
        self.html = html
        self.title = title
        self.target = url
        self.completion = completion
        let width = Self.a4.width - Self.margin.left - Self.margin.right
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 800),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        wv.navigationDelegate = self
        w.contentView = wv
        // 窗口要真的在屏幕上（透明、放在最后面），WebKit 才会正常排版绘制，否则可能打出空白页
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.orderBack(nil)
        window = w
        webView = wv
        wv.loadHTMLString(html, baseURL: nil)
        // 兜底：60 秒还没完成就报错，不让“正在生成 PDF…”一直挂着
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if self?.completion != nil { self?.finish(ImportFileError("生成 PDF 超时。")) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(ImportFileError("排版失败（网页进程意外退出）。"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等字体排好再打印
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.print()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func print() {
        guard let wv = webView, let window else { return finish(ImportFileError("排版失败。")) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-pdf-\(UUID().uuidString).pdf")
        self.tmp = tmp
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary().setObject(tmp, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)
        info.paperSize = Self.a4
        info.topMargin = Self.margin.top
        info.bottomMargin = Self.margin.bottom
        info.leftMargin = Self.margin.left
        info.rightMargin = Self.margin.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let op = wv.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        // 已知问题：不给打印视图一个尺寸，WebKit 有时会打出空白页
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard success, let tmp, let target else { return finish(ImportFileError("生成 PDF 失败。")) }
        do {
            try Self.stamp(source: tmp, to: target, title: title)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        guard completion != nil else { return }
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        window?.close()
        window = nil
        webView = nil
        completion?(error)
        completion = nil
    }

    /// 逐页重绘，加页眉（第 2 页起：标题 + 细线）与页脚（居中页码）
    static func stamp(source: URL, to target: URL, title: String) throws {
        guard let doc = CGPDFDocument(source as CFURL), doc.numberOfPages > 0 else { throw ImportFileError("生成的 PDF 是空的。") }
        try? FileManager.default.removeItem(at: target)
        var box = CGRect(origin: .zero, size: a4)
        guard let ctx = CGContext(target as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: title,
                                                                     kCGPDFContextCreator as String: "KongReview"] as CFDictionary) else {
            throw ImportFileError("无法写入 PDF。")
        }
        let font = NSFont(name: "Songti SC", size: 9) ?? NSFont.systemFont(ofSize: 9)
        let gray = NSColor(white: 0.35, alpha: 1)
        func line(_ s: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: gray]))
        }
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            var media = page.getBoxRect(.mediaBox)
            ctx.beginPage(mediaBox: &media)
            ctx.saveGState()
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            ctx.textMatrix = .identity
            ctx.setFillColor(gray.cgColor)
            let w = media.width, h = media.height
            if i > 1 {
                let l = line(title)
                let tw = CTLineGetTypographicBounds(l, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (w - tw) / 2, y: h - 44)
                CTLineDraw(l, ctx)
                ctx.setStrokeColor(gray.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: margin.left, y: h - 50))
                ctx.addLine(to: CGPoint(x: w - margin.right, y: h - 50))
                ctx.strokePath()
            }
            let n = line("— \(i) —")
            let nw = CTLineGetTypographicBounds(n, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (w - nw) / 2, y: 36)
            CTLineDraw(n, ctx)
            ctx.endPage()
        }
        ctx.closePDF()
    }
}
