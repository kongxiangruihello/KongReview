import Foundation

// MARK: - 带脚注的 RTF（1.2，引文速查“原文 + 脚注”）

/// 生成一小段 RTF 放进剪贴板：Word、Pages 粘贴 RTF 时会把 `\footnote` 建成真正的脚注（自动编号、出现在页脚）。
/// 中文等非 ASCII 字符用 `\uN?` 转义，RTF 本身只含 ASCII。
public enum RTFWriter {
    public enum Run: Equatable, Sendable {
        case text(String)
        /// 正文里此处插一个脚注，内容为给出的文字
        case footnote(String)
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "\n": out += "\\line "
            case "\t": out += "\\tab "
            case "\r": continue
            default:
                if scalar.value < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else {
                    for unit in String(scalar).utf16 {
                        out += "\\u\(Int16(bitPattern: unit))?"
                    }
                }
            }
        }
        return out
    }

    /// 一个完整的 RTF 文档；每个元素是一段
    public static func document(_ paragraphs: [[Run]], font: String = "Songti SC", size: Int = 12) -> String {
        let half = size * 2
        let noteHalf = max(16, half - 4)
        let body = paragraphs.map { runs in
            runs.map { run -> String in
                switch run {
                case .text(let t):
                    return escape(t)
                case .footnote(let n):
                    return "{\\super\\chftn}{\\footnote\\pard\\plain\\f0\\fs\(noteHalf) {\\super\\chftn} \(escape(n))}"
                }
            }.joined()
        }.joined(separator: "\\par\n")
        return "{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0{\\fonttbl{\\f0\\fnil \(escape(font));}}\n\\pard\\plain\\f0\\fs\(half) \(body)\\par\n}"
    }
}
