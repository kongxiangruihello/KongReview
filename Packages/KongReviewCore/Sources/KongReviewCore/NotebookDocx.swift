import Foundation

// MARK: - 专题笔记本 → Word（.docx，含真脚注）

/// 直接写 Office Open XML（WordprocessingML）。macOS 自带的 NSAttributedString 导出 .docx 不支持脚注，
/// 所以这里自己生成 document.xml、footnotes.xml、styles.xml 等，再由应用用 zip 打包。
///
/// 版式：A4，宋体小四（12 磅）1.5 倍行距、首行缩进 2 字；标题黑体；摘录为“引文”样式（楷体、左右缩进）；
/// 脚注宋体小五（9 磅）。结构见 ECMA-376 第 1 部分（17.11 脚注）。
public enum NotebookDocx {

    /// 包内各文件：路径 → 内容
    public static func files(title: String, pieces: [NotebookPiece], options: NotebookExportOptions = .init(),
                             created: Date = Date()) -> [String: String] {
        var body: [String] = []
        var notes: [String] = []

        func runs(_ spans: [NotebookExporter.Span]) -> String {
            spans.map { s in
                var pr = ""
                if s.bold { pr += "<w:b/>" }
                if s.italic { pr += "<w:i/>" }
                if s.strike { pr += "<w:strike/>" }
                return "<w:r>" + (pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>") + "<w:t xml:space=\"preserve\">\(esc(s.text))</w:t></w:r>"
            }.joined()
        }
        func para(_ style: String?, _ content: String) -> String {
            "<w:p>" + (style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? "") + content + "</w:p>"
        }
        func noteRef(_ cite: String) -> String {
            notes.append(cite)
            let id = notes.count   // 0 与 -1 留给分隔线
            return "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(id)\"/></w:r>"
        }

        body.append(para("Title", runs([.init(title)])))

        // 1.4：目录——按小标题（一、二级）预先列出，Word 打开时会提示更新以填上页码（TOC 域）
        if options.toc {
            var entries: [(level: Int, text: String)] = []
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
                body.append(para("TOCHeading", runs([.init("目　录")])))
                let begin = "<w:r><w:fldChar w:fldCharType=\"begin\" w:dirty=\"true\"/></w:r>"
                    + "<w:r><w:instrText xml:space=\"preserve\"> TOC \\o \"1-2\" \\h \\z \\u </w:instrText></w:r>"
                    + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
                let end = "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
                for (k, e) in entries.enumerated() {
                    var content = runs([.init(e.text)])
                    if k == 0 { content = begin + content }
                    if k == entries.count - 1 { content += end }
                    body.append(para(e.level == 1 ? "TOC1" : "TOC2", content))
                }
                body.append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>")
            }
        }

        for p in pieces {
            switch p.kind {
            case .heading(let h):
                body.append(para("Heading1", runs([.init(h)])))
            case .text(let t):
                for pr in NotebookExporter.paragraphs(fromMarkdown: t) {
                    if pr.headingLevel > 0 {
                        body.append(para(pr.headingLevel <= 1 ? "Heading1" : "Heading2", runs(pr.spans)))
                    } else if let m = pr.listMarker {
                        body.append(para("ListPara", runs([.init(m + " ")] + pr.spans)))
                    } else if pr.isQuote {
                        body.append(para("Quote", runs(pr.spans)))
                    } else {
                        body.append(para(nil, runs(pr.spans)))
                    }
                }
            case .quote(let q, let cite):
                let paras = NotebookExporter.paragraphs(fromMarkdown: q)
                for (k, pr) in paras.enumerated() {
                    var content = runs(pr.spans)
                    if k == paras.count - 1, !cite.isEmpty {
                        content += options.footnotes ? noteRef(cite) : runs([.init("（\(cite)）")])
                    }
                    body.append(para("Quote", content))
                }
            case .comment(let c):
                for (k, pr) in NotebookExporter.paragraphs(fromMarkdown: c).enumerated() {
                    let lead: [NotebookExporter.Span] = k == 0 ? [.init("按：", bold: true)] : []
                    body.append(para("Comment", runs(lead + pr.spans)))
                }
            case .essay(let t, let cites):
                let paras = NotebookExporter.essayParagraphs(t)
                for (k, pr) in paras.enumerated() {
                    var content = runs(pr.spans)
                    if k == paras.count - 1, !cites.isEmpty {
                        content += options.footnotes ? cites.map { noteRef($0) }.joined() : runs([.init("（" + cites.joined(separator: "；") + "）")])
                    }
                    body.append(para(nil, content))
                }
            }
        }
        if !options.bibliography.isEmpty {
            body.append(para("Heading1", runs([.init("参考文献")])))
            for e in options.bibliography { body.append(para("Bibliography", runs([.init(e)]))) }
        }

        let hf = options.headerFooter
            ? "<w:headerReference w:type=\"default\" r:id=\"rId4\"/><w:footerReference w:type=\"default\" r:id=\"rId5\"/>"
            : ""
        let sect = """
        <w:sectPr>\(hf)<w:footnotePr><w:numFmt w:val="decimalEnclosedCircleChinese"/><w:numRestart w:val="eachPage"/></w:footnotePr>\
        <w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr>
        """
        let document = xmlHead + "<w:document \(ns)><w:body>" + body.joined() + sect + "</w:body></w:document>"

        var fn = xmlHead + "<w:footnotes \(ns)>"
        fn += "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>"
        fn += "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
        for (i, n) in notes.enumerated() {
            fn += "<w:footnote w:id=\"\(i + 1)\"><w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                + "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>"
                + "<w:r><w:t xml:space=\"preserve\"> \(esc(n))</w:t></w:r></w:p></w:footnote>"
        }
        fn += "</w:footnotes>"

        let iso = ISO8601DateFormatter().string(from: created)
        // 页眉：标题（居中，小五）；页脚：页码（居中）
        let header = xmlHead + "<w:hdr \(ns)>" + para("Header", runs([.init(title)])) + "</w:hdr>"
        let footer = xmlHead + "<w:ftr \(ns)><w:p><w:pPr><w:pStyle w:val=\"Footer\"/></w:pPr>"
            + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> PAGE </w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
            + "</w:p></w:ftr>"
        return [
            "word/header1.xml": header,
            "word/footer1.xml": footer,
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRels,
            "word/document.xml": document,
            "word/footnotes.xml": fn,
            "word/styles.xml": styles,
            "word/settings.xml": settings,
            "word/_rels/document.xml.rels": docRels,
            "docProps/core.xml": xmlHead + """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(esc(title))</dc:title>\
            <dc:creator>KongReview</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(iso)</dcterms:created>\
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(iso)</dcterms:modified></cp:coreProperties>
            """,
        ]
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 不允许的控制字符去掉
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""

    static let contentTypes = xmlHead + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
    <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>\
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    static let rootRels = xmlHead + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    static let docRels = xmlHead + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>\
    <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>\
    <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>\
    </Relationships>
    """

    static let settings = xmlHead + """
    <w:settings \(ns)><w:defaultTabStop w:val="420"/><w:updateFields w:val="true"/><w:footnotePr><w:numFmt w:val="decimalEnclosedCircleChinese"/><w:numRestart w:val="eachPage"/>\
    <w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
    """

    /// 字体：中文宋体 / 黑体 / 楷体（Mac 上 Word 会映射到 Songti SC、Heiti SC、Kaiti SC），西文 Times New Roman
    static let styles = xmlHead + """
    <w:styles \(ns)>\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="宋体" w:cs="Times New Roman"/>\
    <w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:ind w:firstLine="480"/><w:jc w:val="both"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:before="240" w:after="360"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>\
    <w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:ind w:firstLine="0"/><w:outlineLvl w:val="0"/></w:pPr>\
    <w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:ind w:firstLine="0"/><w:outlineLvl w:val="1"/></w:pPr>\
    <w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:before="60" w:after="120" w:line="320" w:lineRule="auto"/><w:ind w:left="840" w:right="420" w:firstLine="0"/></w:pPr>\
    <w:rPr><w:rFonts w:eastAsia="楷体"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListPara"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:ind w:left="480" w:hanging="240" w:firstLine="0"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Bibliography"><w:name w:val="Bibliography"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:ind w:left="420" w:hanging="420" w:firstLine="0"/><w:jc w:val="left"/></w:pPr><w:rPr><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="left"/></w:pPr><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Comment"><w:name w:val="Comment Text KR"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/><w:ind w:left="840" w:right="420" w:firstLine="0"/></w:pPr>\
    <w:rPr><w:color w:val="555555"/><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:before="120" w:after="240"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>\
    <w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="TOC1"><w:name w:val="toc 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:tabs><w:tab w:val="right" w:leader="dot" w:pos="8296"/></w:tabs><w:spacing w:after="60"/><w:ind w:firstLine="0"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="TOC2"><w:name w:val="toc 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:tabs><w:tab w:val="right" w:leader="dot" w:pos="8296"/></w:tabs><w:spacing w:after="60"/><w:ind w:left="420" w:firstLine="0"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Header"><w:name w:val="header"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="1" w:color="999999"/></w:pBdr><w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>\
    <w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Footer"><w:name w:val="footer"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>\
    <w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>\
    </w:styles>
    """
}
