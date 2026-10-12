import Foundation

// MARK: - 存档文章

/// 网页存档：抓取时用 Readability 提取正文，保存清理后的 HTML 与纯文本。
/// 每篇文章对应一个“网页”类出处，在文章里划的线就是该出处下的摘录。
public struct Article: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var sourceId: Int64?
    public var url: String
    public var title: String
    public var author: String?
    public var siteName: String?
    /// 网页声明的发布时间（原样保存，格式各异）
    public var publishedAt: String?
    public var excerpt: String?
    public var contentHTML: String
    public var contentText: String
    /// 字数（中文按字计，不含空白）
    public var wordCount: Int
    public var savedAt: Date
    public var lastOpenedAt: Date?
    public var isRead: Bool

    public init(
        id: Int64? = nil,
        sourceId: Int64? = nil,
        url: String,
        title: String,
        author: String? = nil,
        siteName: String? = nil,
        publishedAt: String? = nil,
        excerpt: String? = nil,
        contentHTML: String,
        contentText: String,
        wordCount: Int,
        savedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        isRead: Bool = false
    ) {
        self.id = id
        self.sourceId = sourceId
        self.url = url
        self.title = title
        self.author = author
        self.siteName = siteName
        self.publishedAt = publishedAt
        self.excerpt = excerpt
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.wordCount = wordCount
        self.savedAt = savedAt
        self.lastOpenedAt = lastOpenedAt
        self.isRead = isRead
    }

    /// 发布日期的“年份”，用于出处的年份字段
    public var publishedYear: String? {
        guard let p = publishedAt, p.count >= 4 else { return nil }
        let y = String(p.prefix(4))
        return Int(y) != nil ? y : nil
    }

    /// 阅读时长估计（中文约 400 字/分钟）
    public var readingMinutes: Int { max(1, Int((Double(wordCount) / 400).rounded())) }
}

// MARK: - 提取结果（extract.js 返回的 JSON）

public struct ArticleExtraction: Decodable, Equatable, Sendable {
    public var title: String
    public var byline: String?
    public var siteName: String?
    public var publishedTime: String?
    public var excerpt: String?
    public var content: String
    public var textContent: String
    public var length: Int?
    public var lang: String?
    public var h1: String?
    public var url: String?

    public enum ParseError: Error, LocalizedError, Equatable {
        case noArticle
        case script(String)
        case tooShort

        public var errorDescription: String? {
            switch self {
            case .noArticle: return "没能从这个网页里识别出正文。它可能是首页、目录页，或需要登录才能查看。"
            case .script(let m): return "提取正文时出错：\(m)"
            case .tooShort: return "识别出的正文太短，可能不是文章页面。"
            }
        }
    }

    /// 解析 extract.js 的返回值
    public static func decode(_ json: String) throws -> ArticleExtraction {
        if json == "null" { throw ParseError.noArticle }
        struct Failure: Decodable { var error: String }
        let data = Data(json.utf8)
        if let f = try? JSONDecoder().decode(Failure.self, from: data) { throw ParseError.script(f.error) }
        let e = try JSONDecoder().decode(ArticleExtraction.self, from: data)
        guard ArticleText.wordCount(e.textContent) >= 50 else { throw ParseError.tooShort }
        return e
    }

    /// 转成可保存的文章
    public func makeArticle(url fallbackURL: String, now: Date = Date()) -> Article {
        let cleanTitle = ArticleText.cleanTitle(title, h1: h1, siteName: siteName)
        let text = ArticleText.normalize(textContent)
        return Article(
            url: url ?? fallbackURL,
            title: cleanTitle.isEmpty ? (url ?? fallbackURL) : cleanTitle,
            author: byline.flatMap(ArticleText.cleanByline),
            siteName: siteName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            publishedAt: publishedTime?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            excerpt: excerpt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            contentHTML: content,
            contentText: text,
            wordCount: ArticleText.wordCount(text),
            savedAt: now
        )
    }
}

// MARK: - 文本处理

public enum ArticleText {
    static let separators = [" - ", " – ", " — ", " | ", " _ ", "_", "——", "－", "｜", " · "]

    /// 网页标题常带“ - 网站名”后缀；中文标题没有空格，Readability 的去后缀规则对它不起作用，这里补上。
    public static func cleanTitle(_ raw: String, h1: String?, siteName: String?) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. 正文大标题是网页标题的开头部分 → 用大标题
        if let h1 = h1?.trimmingCharacters(in: .whitespacesAndNewlines), h1.count >= 2,
           title.hasPrefix(h1) || title == h1 {
            return h1
        }
        // 2. 以“分隔符 + 网站名”结尾 → 去掉
        if let site = siteName?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
            for sep in separators where title.hasSuffix(sep + site) {
                return String(title.dropLast((sep + site).count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    /// 署名常带“作者：”“文/”等前缀或多余空白
    public static func cleanByline(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["作者：", "作者:", "作者", "文／", "文/", "By ", "by "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        s = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return s.isEmpty || s.count > 60 ? nil : s
    }

    /// 合并多余空行，去掉行首尾空白
    public static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for l in lines {
            if l.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(l)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// 字数：不含空白的字符数（中文一个字算一个）
    public static func wordCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }

    /// 划线文字的整理：去首尾空白、合并多余空行
    public static func cleanSelection(_ s: String) -> String {
        normalize(s)
    }
}

// MARK: - 阅读器页面

public enum ReaderPage {
    public struct Mark: Encodable, Equatable {
        public var id: Int64
        public var text: String
        public init(id: Int64, text: String) { self.id = id; self.text = text }
    }

    /// 生成完整的阅读器 HTML（正文 + 样式 + 划线脚本）
    public static func html(for article: Article) -> String {
        let meta = [article.author, article.siteName, article.publishedAt.map { String($0.prefix(10)) }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map(escape)
            .joined(separator: " · ")
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style></head>
        <body>
        <header id="kg-header">
          <h1>\(escape(article.title))</h1>
          <div class="kg-meta">\(meta)</div>
          <div class="kg-meta"><a href="\(escapeAttribute(article.url))">\(escape(article.url))</a></div>
        </header>
        <article id="kg-content">\(ArticleImages.rewrite(article.contentHTML, base: article.url).html)</article>
        <script>\(WebScripts.reader)</script>
        </body></html>
        """
    }

    /// 调用 kgApply 的 JS 语句
    public static func applyScript(_ marks: [Mark]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(marks)) ?? Data("[]".utf8)
        return "window.kgApply && window.kgApply(\(String(decoding: data, as: UTF8.self)));"
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --bg:#fbfaf7; --mark:rgba(255,200,70,.45); --link:#2860e1; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e8e6e1; --muted:#9a9893; --bg:#1e1e1e; --mark:rgba(255,190,60,.35); --link:#7aa2ff; } }
    html { background: var(--bg); }
    body { color: var(--fg); background: var(--bg); margin: 0 auto; max-width: 720px; padding: 40px 32px 120px;
           font: 18px/1.9 "Songti SC", "STSong", "Source Han Serif SC", Georgia, serif; -webkit-font-smoothing: antialiased; }
    #kg-header h1 { font-size: 30px; line-height: 1.4; margin: 0 0 12px; }
    .kg-meta { color: var(--muted); font: 13px/1.6 -apple-system, "PingFang SC", sans-serif; word-break: break-all; }
    .kg-meta a { color: var(--muted); }
    #kg-header { border-bottom: 1px solid rgba(127,127,127,.25); padding-bottom: 18px; margin-bottom: 28px; }
    #kg-content p { margin: 0 0 1.1em; text-align: justify; }
    #kg-content h2, #kg-content h3 { line-height: 1.5; margin: 1.6em 0 .6em; }
    #kg-content img, #kg-content video { max-width: 100%; height: auto; border-radius: 6px; }
    #kg-content figure { margin: 1.4em 0; } figcaption { color: var(--muted); font-size: 14px; text-align: center; }
    #kg-content blockquote { margin: 1em 0; padding: 0 1em; border-left: 3px solid rgba(127,127,127,.35); color: var(--muted); }
    #kg-content pre, #kg-content code { font: 14px/1.6 ui-monospace, Menlo, monospace; white-space: pre-wrap; }
    #kg-content table { border-collapse: collapse; } #kg-content td, #kg-content th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
    a { color: var(--link); }
    mark.kg { background: var(--mark); color: inherit; border-radius: 2px; cursor: pointer; }
    #kg-float { position: absolute; display: none; z-index: 10; padding: 5px 12px; border: 0; border-radius: 8px;
                background: #1d1d1f; color: #fff; font: 13px -apple-system, "PingFang SC", sans-serif; cursor: pointer;
                box-shadow: 0 4px 14px rgba(0,0,0,.25); }
    """
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 正文图片

public enum ArticleImages {
    /// 应用内图片地址的 scheme：阅读器通过它取图（先查本地缓存，没有再带合适的 Referer 下载）
    public static let scheme = "kr-img"

    /// 把正文里的 <img> 改写为 kr-img://img?u=原地址&r=文章地址：
    /// - 懒加载图片：优先取 data-src / data-original / data-actualsrc / data-lazy-src
    /// - 相对地址按文章网址补全；去掉 srcset，避免浏览器绕过改写直接去原站取图
    public static func rewrite(_ html: String, base: String) -> (html: String, urls: [String]) {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return (html, []) }
        let baseURL = URL(string: base)
        let ns = html as NSString
        var out = ""
        var last = 0
        var urls: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tag = ns.substring(with: m.range)
            var chosen: String?
            for attr in ["data-src", "data-original", "data-actualsrc", "data-lazy-src", "src"] {
                if let v = attribute(attr, in: tag), !v.isEmpty, !v.hasPrefix("data:"), !v.hasPrefix("\(scheme):") {
                    chosen = v
                    break
                }
            }
            if let raw = chosen?.replacingOccurrences(of: "&amp;", with: "&"),
               let abs = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
               let s = abs.scheme?.lowercased(), s == "http" || s == "https" {
                urls.append(abs.absoluteString)
                let alt = attribute("alt", in: tag).map { " alt=\"\($0)\"" } ?? ""
                out += "<img src=\"\(proxied(abs.absoluteString, referer: base))\"\(alt) loading=\"lazy\">"
            } else {
                out += tag
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, urls)
    }

    public static func proxied(_ url: String, referer: String) -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "img"
        c.queryItems = [URLQueryItem(name: "u", value: url), URLQueryItem(name: "r", value: referer)]
        return (c.string ?? "").replacingOccurrences(of: "&", with: "&amp;")
    }

    /// 从 kr-img:// 地址取回原图地址与来源页
    public static func parse(_ url: URL) -> (image: URL, referer: String?)? {
        guard url.scheme == scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let u = c.queryItems?.first(where: { $0.name == "u" })?.value, let img = URL(string: u) else { return nil }
        return (img, c.queryItems?.first(where: { $0.name == "r" })?.value)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 2...4 {
            if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    /// 微信等站点拒绝外站 Referer、但允许空 Referer：这些图片下载时不带 Referer
    public static func sendsReferer(for imageURL: URL) -> Bool {
        let host = imageURL.host?.lowercased() ?? ""
        return !(host.hasSuffix("qpic.cn") || host.hasSuffix("qlogo.cn") || host.hasSuffix("weixin.qq.com"))
    }
}
