import AppKit
import KongReviewCore

/// 把专题汇编写成 Word（.docx）。
/// 用 macOS 自带的 NSAttributedString → Office Open XML 转换，不需要第三方库。
/// 版式参照中文讲稿习惯：A4、正文宋体小四（12pt）、1.5 倍行距、首行缩进两字；标题黑体。
enum DocxWriter {

    static func write(_ c: Compilation, to url: URL) throws {
        let doc = attributed(c)
        let data = try doc.data(
            from: NSRange(location: 0, length: doc.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
                .paperSize: NSSize(width: 595.3, height: 841.9),          // A4（pt）
                .leftMargin: 90.0, .rightMargin: 90.0, .topMargin: 72.0, .bottomMargin: 72.0,
                .title: c.title,
            ]
        )
        try data.write(to: url, options: .atomic)
    }

    static func attributed(_ c: Compilation) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let body = font("Songti SC", 12)
        let heiti = font("Heiti SC", 16, bold: true)
        let titleFont = font("Heiti SC", 20, bold: true)
        let small = font("Songti SC", 10.5)
        let kai = font("Kaiti SC", 12)

        func para(_ text: String, _ f: NSFont, align: NSTextAlignment = .natural, indent: CGFloat = 0,
                  firstLine: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 6, color: NSColor = .black) {
            let p = NSMutableParagraphStyle()
            p.alignment = align
            p.lineHeightMultiple = 1.5
            p.headIndent = indent
            p.firstLineHeadIndent = indent + firstLine
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: f, .paragraphStyle: p, .foregroundColor: color,
            ]))
        }

        para(c.title, titleFont, align: .center, after: 4)
        para(c.subtitle, small, align: .center, after: 18, color: .darkGray)

        let twoChars: CGFloat = 24   // 首行缩进两字（12pt × 2）
        for section in c.sections {
            if let h = section.heading { para(h, heiti, before: 14, after: 8) }
            for item in section.items {
                for line in item.text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    para(line, body, firstLine: twoChars, after: 2)
                }
                if let t = item.translation, !t.isEmpty { para("译：" + t, kai, indent: twoChars, after: 2, color: .darkGray) }
                if let n = item.note, !n.isEmpty { para("按：" + n, kai, indent: twoChars, after: 2) }
                if !item.citation.isEmpty { para("—— " + item.citation, small, align: .right, after: 2, color: .darkGray) }
                if !item.tags.isEmpty { para(item.tags.map { "#" + $0 }.joined(separator: " "), small, indent: twoChars, after: 2, color: .gray) }
                para("", small, after: 6)
            }
        }
        return out
    }

    private static func font(_ name: String, _ size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
        guard bold else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }
}
