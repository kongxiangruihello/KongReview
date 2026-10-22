import Foundation

// MARK: - 专题笔记本 → 打印用 HTML（1.6，导出 PDF）

/// 生成供打印成 PDF 的 HTML：版式与 Word 导出一致（宋体小四、1.5 倍行距、首行缩进、黑体标题、楷体引文段）。
///
/// 网页打印做不到“页脚注”，所以出处排成**节末注**：正文里标 ①②，每个小标题一节，节末列出该节的注释
/// （没有小标题时在全文末尾）。页眉（标题）与页码由应用在生成 PDF 后补画。
public enum NotebookHTML {

    static func circled(_ n: Int) -> String {
        if (1...20).contains(n), let u = Unicode.Scalar(0x2460 + n - 1) { return String(Character(u)) }
        return "[\(n)]"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ spans: [NotebookExporter.Span]) -> String {
        spans.map { s in
            var t = esc(s.text)
            if s.strike { t = "<s>\(t)</s>" }
            if s.italic { t = "<i>\(t)</i>" }
            if s.bold { t = "<b>\(t)</b>" }
            return t
        }.joined()
    }

    public static func page(title: String, pieces: [NotebookPiece], options: NotebookExportOptions = .init()) -> String {
        var body: [String] = ["<h1 class=\"title\">\(esc(title))</h1>"]

        // 目录
        if options.toc {
            var entries: [(Int, String)] = []
            for p in pieces {
                switch p.kind {
                case .heading(let h): entries.append((1, h))
                case .text(let t):
                    for pr in NotebookExporter.paragraphs(fromMarkdown: t) where pr.headingLevel > 0 {
                        entries.append((pr.headingLevel <= 1 ? 1 : 2, pr.spans.map(\.text).joined()))
                    }
                default: break
                }
            }
            if !entries.isEmpty {
                body.append("<div class=\"toc\"><div class=\"toc-title\">目　录</div>"
                            + entries.map { "<div class=\"toc\($0.0)\">\(esc($0.1))</div>" }.joined() + "</div>")
                body.append("<div class=\"pagebreak\"></div>")
            }
        }

        var notes: [String] = []
        func flushNotes() {
            guard !notes.isEmpty else { return }
            body.append("<div class=\"notes\"><div class=\"notes-rule\"></div>"
                        + notes.enumerated().map { "<p><span class=\"n\">\(circled($0.offset + 1))</span>\(esc($0.element))</p>" }.joined()
                        + "</div>")
            notes = []
        }

        for p in pieces {
            switch p.kind {
            case .heading(let h):
                flushNotes()
                body.append("<h2>\(esc(h))</h2>")
            case .text(let t):
                for pr in NotebookExporter.paragraphs(fromMarkdown: t) {
                    if pr.headingLevel > 0 {
                        if pr.headingLevel <= 1 { flushNotes() }
                        body.append(pr.headingLevel <= 1 ? "<h2>\(inline(pr.spans))</h2>" : "<h3>\(inline(pr.spans))</h3>")
                    } else if let m = pr.listMarker {
                        body.append("<p class=\"li\"><span class=\"mk\">\(esc(m))</span>\(inline(pr.spans))</p>")
                    } else if pr.isQuote {
                        body.append("<blockquote><p>\(inline(pr.spans))</p></blockquote>")
                    } else {
                        body.append("<p>\(inline(pr.spans))</p>")
                    }
                }
            case .quote(let q, let cite):
                let paras = NotebookExporter.paragraphs(fromMarkdown: q)
                var html = paras.enumerated().map { k, pr -> String in
                    var s = inline(pr.spans)
                    if k == paras.count - 1, !cite.isEmpty {
                        if options.footnotes {
                            notes.append(cite)
                            s += "<sup class=\"ref\">\(circled(notes.count))</sup>"
                        } else {
                            s += "<span class=\"cite\">（\(esc(cite))）</span>"
                        }
                    }
                    return "<p>\(s)</p>"
                }.joined()
                if html.isEmpty { html = "<p></p>" }
                body.append("<blockquote>\(html)</blockquote>")
            case .comment(let c):
                for (k, pr) in NotebookExporter.paragraphs(fromMarkdown: c).enumerated() {
                    body.append("<p class=\"comment\">\(k == 0 ? "<b>按：</b>" : "")\(inline(pr.spans))</p>")
                }
            case .essay(let t, let cites):
                let paras = NotebookExporter.essayParagraphs(t)
                for (k, pr) in paras.enumerated() {
                    var s = inline(pr.spans)
                    if k == paras.count - 1, !cites.isEmpty {
                        if options.footnotes {
                            for c in cites { notes.append(c); s += "<sup class=\"ref\">\(circled(notes.count))</sup>" }
                        } else {
                            s += "<span class=\"cite\">（\(esc(cites.joined(separator: "；")))）</span>"
                        }
                    }
                    body.append("<p>\(s)</p>")
                }
            }
        }
        flushNotes()

        if !options.bibliography.isEmpty {
            body.append("<h2>参考文献</h2>")
            body.append(options.bibliography.map { "<p class=\"bib\">\(esc($0))</p>" }.joined())
        }

        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(esc(title))</title><style>\(css)</style></head><body>"
            + body.joined(separator: "\n") + "</body></html>"
    }

    static let css = """
    html, body { margin: 0; padding: 0; background: #fff; }
    body { font: 12pt/1.5 "Songti SC", "STSong", "SimSun", serif; color: #111; text-align: justify; }
    p { margin: 0 0 0.3em; text-indent: 2em; }
    h1.title { font: bold 18pt/1.4 "Heiti SC", "STHeiti", "SimHei", sans-serif; text-align: center; margin: 0.6em 0 1.2em; }
    h2 { font: bold 15pt/1.4 "Heiti SC", "STHeiti", "SimHei", sans-serif; margin: 1.4em 0 0.6em; page-break-after: avoid; }
    h3 { font: bold 13pt/1.4 "Heiti SC", "STHeiti", "SimHei", sans-serif; margin: 1em 0 0.5em; page-break-after: avoid; }
    blockquote { margin: 0.4em 1.5em 0.8em 3em; font-family: "Kaiti SC", "STKaiti", "KaiTi", serif; font-size: 11pt; line-height: 1.6;
                 page-break-inside: avoid; }
    blockquote p { text-indent: 0; margin-bottom: 0.25em; }
    sup.ref { font-size: 8pt; vertical-align: super; line-height: 0; margin-left: 1px; font-family: "Songti SC", serif; }
    .cite { font-family: "Songti SC", serif; font-size: 10pt; color: #444; }
    p.comment { text-indent: 0; margin: -0.3em 1.5em 0.8em 3em; font-size: 10.5pt; color: #555; }
    p.li { text-indent: 0; padding-left: 3.5em; }
    p.li .mk { display: inline-block; width: 1.5em; margin-left: -1.5em; }
    .toc { margin: 0 2em 1em; }
    .toc-title { font: bold 15pt "Heiti SC", "STHeiti", sans-serif; text-align: center; margin-bottom: 0.8em; }
    .toc1 { margin: 0.2em 0; } .toc2 { margin: 0.15em 0 0.15em 2em; font-size: 11pt; }
    .pagebreak { page-break-after: always; }
    .notes { margin: 1em 0 1.2em; font-size: 9pt; line-height: 1.5; color: #333; page-break-inside: auto; }
    .notes-rule { width: 30%; border-top: 0.5pt solid #888; margin-bottom: 0.4em; }
    .notes p { text-indent: 0; margin: 0 0 0.15em; padding-left: 1.6em; }
    .notes .n { display: inline-block; width: 1.6em; margin-left: -1.6em; }
    p.bib { text-indent: -2em; padding-left: 2em; font-size: 10.5pt; }
    """
}
