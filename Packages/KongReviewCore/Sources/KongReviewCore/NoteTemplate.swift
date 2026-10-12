import Foundation

/// 笔记类型的显示模板：哪些字段放正面、哪些放背面、哪些默认折叠。
///
/// 从 Anki 导入的多字段笔记（如“正文 / 注释 / 译文 / 解题 / 备注”）保留各字段原文，
/// 显示时按模板拼出正反面；改模板不改卡片内容，所有同类型卡片立即按新模板显示。
public struct NoteTemplate: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var fieldNames: [String]
    /// 字段序号
    public var front: [Int]
    public var back: [Int]
    /// 在背面折叠显示（点开才看到）的字段
    public var collapsed: [Int]
    /// 完形填空类型：正面第一个字段按 {{c1::…}} 挖空
    public var isCloze: Bool
    public var id: String { name }

    public init(name: String, fieldNames: [String], front: [Int], back: [Int], collapsed: [Int] = [], isCloze: Bool = false) {
        self.name = name; self.fieldNames = fieldNames; self.front = front; self.back = back
        self.collapsed = collapsed; self.isCloze = isCloze
    }

    /// 默认模板：第一个字段为正面，其余在背面；名称像“注释、备注、笔记、补充”的字段默认折叠
    public static func defaultTemplate(name: String, fieldNames: [String], isCloze: Bool = false) -> NoteTemplate {
        let rest = Array(fieldNames.indices.dropFirst())
        let foldWords = ["注释", "注", "备注", "笔记", "补充", "extra", "notes", "note", "remarks"]
        let collapsed = rest.filter { i in
            let n = fieldNames[i].lowercased()
            return foldWords.contains { n == $0 || (n.contains($0) && $0.count > 1) }
        }
        return NoteTemplate(name: name, fieldNames: fieldNames, front: fieldNames.isEmpty ? [] : [0],
                            back: rest, collapsed: collapsed, isCloze: isCloze)
    }

    func value(_ fields: [String], _ i: Int) -> String {
        i < fields.count ? AnkiContent.stripSound(fields[i]) : ""
    }

    func label(_ i: Int) -> String { i < fieldNames.count ? fieldNames[i] : "字段\(i + 1)" }

    static func isBlank(_ s: String) -> Bool {
        Markdown.plainText(fromHTML: s).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !s.lowercased().contains("<img")
    }

    /// 按模板生成正反面 HTML
    public func render(_ fields: [String]) -> (front: String, back: String) {
        var frontParts: [String] = []
        var clozeBack: String?
        for i in front {
            var v = value(fields, i)
            if Self.isBlank(v) { continue }
            if isCloze && i == front.first, AnkiContent.isCloze(v) {
                let c = AnkiContent.cloze(v)
                v = c.front
                clozeBack = c.back
            }
            frontParts.append("<div class=\"kr-field\">\(v)</div>")
        }
        var backParts: [String] = []
        if let clozeBack { backParts.append("<div class=\"kr-field\">\(clozeBack)</div>") }
        let shown = back.filter { !Self.isBlank(value(fields, $0)) }
        let labelled = shown.count > 1 || !collapsed.isEmpty
        for i in shown {
            let v = value(fields, i)
            let name = Markdown.escape(label(i))
            if collapsed.contains(i) {
                backParts.append("<details class=\"kr-field\"><summary>\(name)</summary>\(v)</details>")
            } else if labelled {
                backParts.append("<div class=\"kr-field\"><div class=\"kr-label\">\(name)</div>\(v)</div>")
            } else {
                backParts.append("<div class=\"kr-field\">\(v)</div>")
            }
        }
        return (frontParts.joined(separator: "\n"), backParts.joined(separator: "\n"))
    }
}

extension Card {
    /// 实际显示的正反面：有笔记类型与字段时按模板生成，否则用卡片自己的 front / back
    public func faces(using template: NoteTemplate?) -> (front: String, back: String) {
        if let t = template, !fields.isEmpty { return t.render(fields) }
        return (front, back)
    }
}

// MARK: - SHA-1（导出 Anki 包时计算笔记校验和用；不用于安全目的）

public enum SHA1 {
    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        var out: [UInt8] = []
        for v in h { for s in [24, 16, 8, 0] { out.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        return out
    }
}
