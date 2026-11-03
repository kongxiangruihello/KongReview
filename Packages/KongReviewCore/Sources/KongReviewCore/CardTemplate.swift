import Foundation

// MARK: - 6.0.0：卡片模板的 HTML 编辑
//
// 每种笔记类型可以写正面模板、背面模板与样式（CSS），写法与 Anki 一致：
//   {{字段}}  {{FrontSide}}  {{#字段}}…{{/字段}}  {{^字段}}…{{/字段}}  {{cloze:字段}}  {{hint:字段}}  {{text:字段}}  {{type:字段}}
// 应用在正面下方另行显示背面，所以背面里的 {{FrontSide}} 与紧随其后的 <hr id=answer> 不重复显示。
// 写了 HTML 就以 HTML 为准；没写时沿用“正面 / 背面 / 折叠”的放置。

/// 一种笔记类型的 HTML 模板
public struct NoteTemplateHTML: Codable, Hashable, Sendable {
    public var front: String
    public var back: String
    public var css: String
    public init(front: String, back: String, css: String = "") {
        self.front = front; self.back = back; self.css = css
    }
}

public enum CardTemplateEngine {
    public enum Side: Sendable { case front, back }

    // MARK: 词法

    enum Token: Equatable {
        case text(String)
        case variable(filters: [String], field: String)
        case open(String, inverted: Bool)
        case close(String)
    }

    static func tokenize(_ template: String) -> [Token] {
        var out: [Token] = []
        var rest = Substring(template)
        while let start = rest.range(of: "{{") {
            if start.lowerBound > rest.startIndex { out.append(.text(String(rest[..<start.lowerBound]))) }
            guard let end = rest[start.upperBound...].range(of: "}}") else {
                out.append(.text(String(rest[start.lowerBound...])))
                return out
            }
            let tag = rest[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("#") {
                out.append(.open(tag.dropFirst().trimmingCharacters(in: .whitespaces), inverted: false))
            } else if tag.hasPrefix("^") {
                out.append(.open(tag.dropFirst().trimmingCharacters(in: .whitespaces), inverted: true))
            } else if tag.hasPrefix("/") {
                out.append(.close(tag.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                var parts = tag.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let field = parts.removeLast()
                out.append(.variable(filters: parts.map { $0.lowercased() }, field: field))
            }
            rest = rest[end.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    // MARK: 渲染

    /// 按模板生成一面。fields：字段名 → 内容（HTML）。side 为 .back 时 {{FrontSide}} 不再重复显示。
    public static func render(_ template: String, fields: [String: String], side: Side) -> String {
        let tokens = tokenize(template)
        var i = 0
        var out = renderTokens(tokens, &i, fields: fields, side: side, until: nil)
        if side == .back {
            // 去掉 {{FrontSide}} 之后开头的分隔线
            out = out.replacingOccurrences(of: #"^\s*<hr\s+id\s*=\s*["']?answer["']?\s*/?>\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderTokens(_ tokens: [Token], _ i: inout Int, fields: [String: String], side: Side, until: String?) -> String {
        var out = ""
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            switch t {
            case .text(let s):
                out += s
            case .close(let name):
                if name == until { return out }
            case .open(let name, let inverted):
                let filled = !(fields[name].map(NoteTemplate.isBlank) ?? true)
                let inner = renderTokens(tokens, &i, fields: fields, side: side, until: name)
                if filled != inverted { out += inner }
            case .variable(let filters, let field):
                out += value(filters: filters, field: field, fields: fields, side: side)
            }
        }
        return out
    }

    private static func value(filters: [String], field: String, fields: [String: String], side: Side) -> String {
        if field == "FrontSide" && filters.isEmpty { return "" }
        let v = fields[field] ?? ""
        if filters.contains("cloze") {
            guard AnkiContent.isCloze(v) else { return side == .back ? v : "" }
            let c = AnkiContent.cloze(v)
            return side == .front ? c.front : c.back
        }
        if filters.contains("type") { return side == .back ? v : "" }
        if filters.contains("text") { return Markdown.escape(Markdown.plainText(fromHTML: v)) }
        if filters.contains("hint") {
            guard !NoteTemplate.isBlank(v) else { return "" }
            return "<details class=\"kr-hint\"><summary>显示提示</summary>\(v)</details>"
        }
        return v
    }

    // MARK: 检查

    /// 模板里的问题：用了不存在的字段、条件没有配对、正面用了 {{FrontSide}}。空数组表示可以保存。
    public static func issues(_ template: String, fieldNames: [String], side: Side) -> [String] {
        let known = Set(fieldNames)
        var problems: [String] = []
        var stack: [String] = []
        func note(_ s: String) { if !problems.contains(s) { problems.append(s) } }
        for t in tokenize(template) {
            switch t {
            case .text:
                break
            case .open(let name, _):
                if !known.contains(name) { note("没有名为“\(name)”的字段") }
                stack.append(name)
            case .close(let name):
                if stack.last == name { stack.removeLast() }
                else { note("{{/\(name)}} 没有对应的开头") }
            case .variable(let filters, let field):
                if field == "FrontSide" && filters.isEmpty {
                    if side == .front { note("正面模板不能用 {{FrontSide}}") }
                } else if field.isEmpty {
                    note("有一处 {{}} 是空的")
                } else if !known.contains(field) {
                    note("没有名为“\(field)”的字段")
                }
                let unknownFilters = filters.filter { !["cloze", "text", "hint", "type", "nc", "ci"].contains($0) }
                if let f = unknownFilters.first { note("不认识的写法“\(f):”") }
            }
        }
        for name in stack.reversed() { note("{{#\(name)}} 或 {{^\(name)}} 没有收尾的 {{/\(name)}}") }
        return problems
    }

    // MARK: 由放置生成

    /// 把“正面 / 背面 / 折叠”的放置写成等价的 HTML 模板，作为切到 HTML 时的初始代码
    public static func html(from t: NoteTemplate) -> NoteTemplateHTML {
        func name(_ i: Int) -> String { i < t.fieldNames.count ? t.fieldNames[i] : "字段\(i + 1)" }
        var front: [String] = []
        for (n, i) in t.front.enumerated() {
            let f = name(i)
            let tag = t.isCloze && n == 0 ? "{{cloze:\(f)}}" : "{{\(f)}}"
            front.append("{{#\(f)}}<div class=\"kr-field\">\(tag)</div>{{/\(f)}}")
        }
        var back: [String] = ["{{FrontSide}}", "", "<hr id=answer>", ""]
        if t.isCloze, let first = t.front.first {
            back.append("<div class=\"kr-field\">{{cloze:\(name(first))}}</div>")
        }
        let labelled = t.back.count > 1 || !t.collapsed.isEmpty
        for i in t.back {
            let f = name(i)
            let label = Markdown.escape(f)
            if t.collapsed.contains(i) {
                back.append("{{#\(f)}}<details class=\"kr-field\"><summary>\(label)</summary>{{\(f)}}</details>{{/\(f)}}")
            } else if labelled {
                back.append("{{#\(f)}}<div class=\"kr-field\"><div class=\"kr-label\">\(label)</div>{{\(f)}}</div>{{/\(f)}}")
            } else {
                back.append("{{#\(f)}}<div class=\"kr-field\">{{\(f)}}</div>{{/\(f)}}")
            }
        }
        return NoteTemplateHTML(front: front.joined(separator: "\n"), back: back.joined(separator: "\n"), css: "")
    }
}

// MARK: - Anki 新格式（schema 18）里的模板：protobuf 中的字符串字段

public enum AnkiProtobuf {
    /// 读出一段 protobuf 顶层的“长度前缀”字段（字段号 → 按 UTF-8 解出的字符串）；同一字段号取第一个。读不懂就返回已读到的部分。
    public static func strings(_ data: Data) -> [Int: String] {
        let b = [UInt8](data)
        var i = 0
        var out: [Int: String] = [:]
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            let field = Int(key >> 3), wire = key & 7
            switch wire {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), i + Int(len) <= b.count else { return out }
                if out[field] == nil, let s = String(bytes: b[i..<(i + Int(len))], encoding: .utf8) { out[field] = s }
                i += Int(len)
            default: return out
            }
        }
        return out
    }
}
