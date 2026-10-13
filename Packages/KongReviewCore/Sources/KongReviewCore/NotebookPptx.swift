import Foundation

// MARK: - 专题笔记本 → 演示稿（.pptx，1.4）

/// 直接写 PresentationML（ECMA-376 第 1 部分第 19 章），PowerPoint 与 Keynote 都能打开。
///
/// 版式（16:9，纸色底，与应用的回顾卡片一致）：
/// - 封面：标题 + 日期；
/// - 小标题 → 章节页（大字居中，下方一道蓝线）；
/// - 摘录 → 引文页（左侧蓝色竖条，宋体大字，右下角出处）；字多时自动缩小字号，特别长的按句子拆成几页（标“续”）；
/// - 文字 → 正文页（同样按长度拆页）；按语（可选）排在引文下方，小字灰色；
/// - 文末可附参考文献页。
public enum NotebookPptx {

    // 尺寸（EMU）：13.333 × 7.5 英寸
    static let W = 12_192_000
    static let H = 6_858_000
    static let inch = 914_400

    public struct Palette: Sendable {
        public var paper = "F6F4EF", ink = "1F1E1C", sub = "8A857C", accent = "3B73EF", soft = "E7EEFD"
        public init() {}
    }

    public static func files(title: String, pieces: [NotebookPiece], options: NotebookExportOptions = .init(),
                             date: Date = Date(), palette: Palette = .init()) -> [String: String] {
        var slides: [String] = []
        let p = palette

        // 封面
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        slides.append(slide(p, shapes: [
            textBox(id: 2, x: inch, y: Int(Double(H) * 0.34), w: W - 2 * inch, h: Int(1.4 * Double(inch)),
                    paras: [para([run(title, size: 4000, bold: true, color: p.ink)], align: "ctr")], anchor: "b"),
            rect(id: 3, x: W / 2 - inch / 2, y: Int(Double(H) * 0.56), w: inch, h: 38_100, color: p.accent),
            textBox(id: 4, x: inch, y: Int(Double(H) * 0.60), w: W - 2 * inch, h: Int(0.6 * Double(inch)),
                    paras: [para([run("\(c.year ?? 0) 年 \(c.month ?? 0) 月 \(c.day ?? 0) 日", size: 1600, color: p.sub, serif: false)], align: "ctr")],
                    anchor: "t"),
        ]))

        var pendingComment: String?
        var lastQuote: (text: String, cite: String)?
        func flushQuote() {
            guard let q = lastQuote else { return }
            slides += quoteSlides(q.text, cite: q.cite, comment: pendingComment, p)
            lastQuote = nil
            pendingComment = nil
        }

        for piece in pieces {
            switch piece.kind {
            case .heading(let h):
                flushQuote()
                slides.append(sectionSlide(h, p))
            case .text(let t):
                flushQuote()
                // 文字块里的 # 小标题也做成章节页
                var buffer: [NotebookExporter.Paragraph] = []
                func flushText() {
                    if !buffer.isEmpty { slides += textSlides(buffer, p) }
                    buffer = []
                }
                for pr in NotebookExporter.paragraphs(fromMarkdown: t) {
                    if pr.headingLevel > 0 {
                        flushText()
                        slides.append(sectionSlide(pr.spans.map(\.text).joined(), p))
                    } else {
                        buffer.append(pr)
                    }
                }
                flushText()
            case .quote(let q, let cite):
                flushQuote()
                lastQuote = (q, cite)
            case .comment(let cm):
                if lastQuote != nil { pendingComment = cm }
            }
        }
        flushQuote()

        if !options.bibliography.isEmpty {
            let paras = options.bibliography.map { para([run($0, size: 1400, color: p.ink, serif: false)], align: "l", spaceAfter: 600) }
            for chunk in stride(from: 0, to: paras.count, by: 12).map({ Array(paras[$0..<min($0 + 12, paras.count)]) }) {
                slides.append(slide(p, shapes: [
                    textBox(id: 2, x: inch, y: Int(0.55 * Double(inch)), w: W - 2 * inch, h: Int(0.8 * Double(inch)),
                            paras: [para([run("参考文献", size: 2800, bold: true, color: p.ink)], align: "l")], anchor: "b"),
                    rect(id: 3, x: inch, y: Int(1.42 * Double(inch)), w: Int(0.8 * Double(inch)), h: 31_750, color: p.accent),
                    textBox(id: 4, x: inch, y: Int(1.7 * Double(inch)), w: W - 2 * inch, h: H - Int(2.3 * Double(inch)),
                            paras: chunk, anchor: "t"),
                ]))
            }
        }

        return package(slides: slides, title: title, date: date)
    }

    // MARK: 各类页面

    static func sectionSlide(_ text: String, _ p: Palette) -> String {
        slide(p, shapes: [
            textBox(id: 2, x: inch, y: Int(Double(H) * 0.30), w: W - 2 * inch, h: Int(1.6 * Double(inch)),
                    paras: [para([run(text, size: 3600, bold: true, color: p.ink)], align: "ctr")], anchor: "b"),
            rect(id: 3, x: W / 2 - Int(0.6 * Double(inch)), y: Int(Double(H) * 0.56), w: Int(1.2 * Double(inch)), h: 38_100, color: p.accent),
        ])
    }

    /// 字数 → 字号（百分之一磅）
    static func quoteSize(_ n: Int) -> Int {
        switch n {
        case ..<40: return 3600
        case ..<90: return 3000
        case ..<160: return 2600
        case ..<240: return 2200
        default: return 2000
        }
    }

    static func quoteSlides(_ text: String, cite: String, comment: String?, _ p: Palette) -> [String] {
        let paras = NotebookExporter.paragraphs(fromMarkdown: text)
        let pages = chunks(paras, limit: 320)
        let citeShort = shortCite(cite)
        return pages.enumerated().map { k, page in
            let n = page.reduce(0) { $0 + $1.spans.reduce(0) { $0 + $1.text.count } }
            let size = quoteSize(n)
            var shapes: [String] = []
            shapes.append(rect(id: 2, x: Int(0.9 * Double(inch)), y: Int(1.0 * Double(inch)), w: 57_150,
                               h: H - Int(2.5 * Double(inch)), color: p.accent))
            let bodyParas = page.map { pr in
                para(pr.spans.map { run($0.text, size: size, bold: $0.bold, italic: $0.italic, strike: $0.strike, color: p.ink) },
                     align: "l", lineSpacing: 140_000, spaceAfter: 800)
            }
            let isLast = k == pages.count - 1
            let hasComment = isLast && !(comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let bodyH = H - Int((hasComment ? 3.6 : 2.5) * Double(inch))
            shapes.append(textBox(id: 3, x: Int(1.25 * Double(inch)), y: Int(1.0 * Double(inch)),
                                  w: W - Int(2.3 * Double(inch)), h: bodyH, paras: bodyParas, anchor: "ctr", autofit: true))
            if hasComment, let comment {
                let cm = NotebookExporter.plain(comment)
                shapes.append(textBox(id: 4, x: Int(1.25 * Double(inch)), y: Int(1.0 * Double(inch)) + bodyH + Int(0.15 * Double(inch)),
                                      w: W - Int(2.3 * Double(inch)), h: Int(1.0 * Double(inch)),
                                      paras: [para([run("按：", size: 1500, bold: true, color: p.sub, serif: false),
                                                    run(cm, size: 1500, color: p.sub, serif: false)], align: "l")],
                                      anchor: "t", fill: p.soft, inset: 91_440, autofit: true))
            }
            var label = citeShort
            if pages.count > 1 { label = (label.isEmpty ? "" : label + "  ") + "（\(k + 1)/\(pages.count)）" }
            if !label.isEmpty {
                shapes.append(textBox(id: 5, x: Int(1.25 * Double(inch)), y: H - Int(1.15 * Double(inch)),
                                      w: W - Int(2.3 * Double(inch)), h: Int(0.5 * Double(inch)),
                                      paras: [para([run("—— " + label, size: 1500, color: p.sub, serif: false)], align: "r")],
                                      anchor: "t"))
            }
            return slide(p, shapes: shapes)
        }
    }

    static func textSlides(_ paras: [NotebookExporter.Paragraph], _ p: Palette) -> [String] {
        chunks(paras, limit: 380).map { page in
            let n = page.reduce(0) { $0 + $1.spans.reduce(0) { $0 + $1.text.count } }
            let size = n < 120 ? 2400 : (n < 240 ? 2000 : 1800)
            let ps = page.map { pr -> String in
                var spans = pr.spans.map { run($0.text, size: size, bold: $0.bold, italic: $0.italic, strike: $0.strike, color: p.ink, serif: false) }
                if let m = pr.listMarker { spans.insert(run(m + " ", size: size, color: p.accent, serif: false), at: 0) }
                return para(spans, align: "l", lineSpacing: 130_000, spaceAfter: 900)
            }
            return slide(p, shapes: [
                textBox(id: 2, x: Int(1.1 * Double(inch)), y: Int(0.9 * Double(inch)), w: W - Int(2.2 * Double(inch)),
                        h: H - Int(1.8 * Double(inch)), paras: ps, anchor: "ctr", autofit: true),
            ])
        }
    }

    /// 出处写短一点：去掉句末句号
    static func shortCite(_ cite: String) -> String {
        cite.trimmingCharacters(in: CharacterSet(charactersIn: "。．. "))
    }

    /// 按字数分页：先按段落，单段太长再按句子切
    static func chunks(_ paras: [NotebookExporter.Paragraph], limit: Int) -> [[NotebookExporter.Paragraph]] {
        var pieces: [NotebookExporter.Paragraph] = []
        for pr in paras {
            let len = pr.spans.reduce(0) { $0 + $1.text.count }
            if len <= limit { pieces.append(pr); continue }
            // 按句末标点切成若干段（保留粗斜体会过于复杂：长段落拆分时按纯文字处理）
            let text = pr.spans.map(\.text).joined()
            var cur = ""
            for ch in text {
                cur.append(ch)
                if "。！？；!?;".contains(ch), cur.count >= limit / 2 {
                    var np = pr; np.spans = [.init(cur)]; pieces.append(np); cur = ""
                } else if cur.count >= limit {
                    var np = pr; np.spans = [.init(cur)]; pieces.append(np); cur = ""
                }
            }
            if !cur.isEmpty { var np = pr; np.spans = [.init(cur)]; pieces.append(np) }
        }
        var out: [[NotebookExporter.Paragraph]] = []
        var page: [NotebookExporter.Paragraph] = []
        var count = 0
        for pr in pieces {
            let len = pr.spans.reduce(0) { $0 + $1.text.count }
            if !page.isEmpty && count + len > limit {
                out.append(page); page = []; count = 0
            }
            page.append(pr); count += len
        }
        if !page.isEmpty { out.append(page) }
        return out.isEmpty ? [[]] : out
    }

    // MARK: 形状

    static func run(_ t: String, size: Int, bold: Bool = false, italic: Bool = false, strike: Bool = false,
                    color: String, serif: Bool = true) -> String {
        let font = serif ? "Songti SC" : "PingFang SC"
        var attrs = "lang=\"zh-CN\" altLang=\"en-US\" sz=\"\(size)\""
        if bold { attrs += " b=\"1\"" }
        if italic { attrs += " i=\"1\"" }
        if strike { attrs += " strike=\"sngStrike\"" }
        return "<a:r><a:rPr \(attrs) dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>"
            + "<a:latin typeface=\"\(font)\"/><a:ea typeface=\"\(font)\"/></a:rPr><a:t>\(NotebookDocx.esc(t))</a:t></a:r>"
    }

    static func para(_ runs: [String], align: String, lineSpacing: Int? = nil, spaceAfter: Int? = nil) -> String {
        var pPr = "<a:pPr algn=\"\(align)\">"
        if let l = lineSpacing { pPr += "<a:lnSpc><a:spcPct val=\"\(l)\"/></a:lnSpc>" }
        if let s = spaceAfter { pPr += "<a:spcAft><a:spcPts val=\"\(s)\"/></a:spcAft>" }
        pPr += "<a:buNone/></a:pPr>"
        return "<a:p>" + pPr + runs.joined() + "</a:p>"
    }

    static func textBox(id: Int, x: Int, y: Int, w: Int, h: Int, paras: [String], anchor: String,
                        fill: String? = nil, inset: Int = 0, autofit: Bool = false) -> String {
        let fillXML = fill.map { "<a:solidFill><a:srgbClr val=\"\($0)\"/></a:solidFill>" } ?? "<a:noFill/>"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(fillXML)</p:spPr>"
            + "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"\(inset)\" tIns=\"\(inset)\" rIns=\"\(inset)\" bIns=\"\(inset)\" anchor=\"\(anchor)\">"
            + (autofit ? "<a:normAutofit/>" : "<a:noAutofit/>") + "</a:bodyPr><a:lstStyle/>"
            + (paras.isEmpty ? "<a:p><a:endParaRPr lang=\"zh-CN\"/></a:p>" : paras.joined())
            + "</p:txBody></p:sp>"
    }

    static func rect(id: Int, x: Int, y: Int, w: Int, h: Int, color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Bar \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>"
            + "<a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
    }

    static func slide(_ p: Palette, shapes: [String]) -> String {
        NotebookDocx.xmlHead + "<p:sld \(ns)><p:cSld>"
            + "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(p.paper)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
            + "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
            + shapes.joined()
            + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    static let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

    // MARK: 包

    static func package(slides: [String], title: String, date: Date) -> [String: String] {
        var files: [String: String] = [:]
        let head = NotebookDocx.xmlHead
        var overrides = """
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        """
        var sldIds = ""
        var presRels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for (i, s) in slides.enumerated() {
            let n = i + 1
            files["ppt/slides/slide\(n).xml"] = s
            files["ppt/slides/_rels/slide\(n).xml.rels"] = head + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            </Relationships>
            """
            overrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            sldIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 1)\"/>"
            presRels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
        }
        let themeRel = "rId\(slides.count + 2)"
        presRels += "<Relationship Id=\"\(themeRel)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"

        files["[Content_Types].xml"] = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" + overrides + "</Types>"
        files["_rels/.rels"] = head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """
        files["ppt/presentation.xml"] = head + "<p:presentation \(ns) saveSubsetFonts=\"1\">"
            + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
            + "<p:sldIdLst>\(sldIds)</p:sldIdLst>"
            + "<p:sldSz cx=\"\(W)\" cy=\"\(H)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        files["ppt/_rels/presentation.xml.rels"] = head
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(presRels)</Relationships>"
        files["ppt/slideMasters/slideMaster1.xml"] = head + "<p:sldMaster \(ns)><p:cSld>"
            + "<p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
            + "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
            + "</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" "
            + "accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
        </Relationships>
        """
        files["ppt/slideLayouts/slideLayout1.xml"] = head + "<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"空白\">"
            + "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
            + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
        </Relationships>
        """
        files["ppt/theme/theme1.xml"] = head + theme
        let iso = ISO8601DateFormatter().string(from: date)
        files["docProps/core.xml"] = head + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(NotebookDocx.esc(title))</dc:title>\
        <dc:creator>KongReview</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(iso)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(iso)</dcterms:modified></cp:coreProperties>
        """
        return files
    }

    /// 最小但完整的主题（颜色、字体、格式方案三部分都必须有）
    static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="KongReview">\
    <a:themeElements><a:clrScheme name="KongReview">\
    <a:dk1><a:srgbClr val="1F1E1C"/></a:dk1><a:lt1><a:srgbClr val="F6F4EF"/></a:lt1>\
    <a:dk2><a:srgbClr val="3B3833"/></a:dk2><a:lt2><a:srgbClr val="FFFFFF"/></a:lt2>\
    <a:accent1><a:srgbClr val="3B73EF"/></a:accent1><a:accent2><a:srgbClr val="D9822B"/></a:accent2>\
    <a:accent3><a:srgbClr val="4C9A6A"/></a:accent3><a:accent4><a:srgbClr val="B5534B"/></a:accent4>\
    <a:accent5><a:srgbClr val="7A5CC2"/></a:accent5><a:accent6><a:srgbClr val="8A857C"/></a:accent6>\
    <a:hlink><a:srgbClr val="3B73EF"/></a:hlink><a:folHlink><a:srgbClr val="7A5CC2"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="KongReview"><a:majorFont><a:latin typeface="Songti SC"/><a:ea typeface="Songti SC"/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="PingFang SC"/><a:ea typeface="PingFang SC"/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="KongReview"><a:fillStyleLst>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    </a:fillStyleLst><a:lnStyleLst>\
    <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    </a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
}
