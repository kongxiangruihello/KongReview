import Foundation

// MARK: - 4.0：写作字数口径
//
// 中文（汉字、假名、谚文）逐字计；西文、数字按词计（连续的字母或数字算一个词）；
// 标点、空白、HTML 标记不计。与 Word“字数统计”中的“中文字数＋西文词数”接近。

public enum WritingCount {
    /// 一段 HTML 或纯文字的字数
    public static func count(html: String) -> Int {
        let looksLikeHTML = html.range(of: "<[A-Za-z/!][^>]*>", options: .regularExpression) != nil
        return count(text: looksLikeHTML ? Markdown.plainText(fromHTML: html) : html)
    }

    public static func count(text: String) -> Int {
        var total = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                total += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { total += 1; inWord = true }
            } else if inWord, scalar == "'" || scalar == "’" || scalar == "-" {
                // don't、well-known：撇号与连字符留在词内
                continue
            } else {
                inWord = false
            }
        }
        return total
    }

    /// 汉字（含扩展区、兼容区）、日文假名、韩文谚文
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
        case 0x3040...0x30FF, 0x31F0...0x31FF: return true
        case 0xAC00...0xD7AF, 0x1100...0x11FF: return true
        default: return false
        }
    }

    /// 改写前后的增减：返回（新增，删减）
    public static func delta(from old: Int, to new: Int) -> (added: Int, removed: Int) {
        new >= old ? (new - old, 0) : (0, old - new)
    }
}
