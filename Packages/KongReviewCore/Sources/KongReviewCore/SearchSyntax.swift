import Foundation

// MARK: - 搜索语法（1.6）

/// 搜索框里可以直接写条件，空格分隔、可任意组合：
///
/// | 写法 | 含义 |
/// |---|---|
/// | `学而 时习` | 两个词都要出现（繁简通搜） |
/// | `"学而时习之"` 或 `“学而时习之”` | 整句（引号里可以有空格） |
/// | `-孟子` | 不含“孟子” |
/// | `出处:论语`、`作者:杨伯峻` | 出处书名 / 作者里含这些字 |
/// | `标签:儒家` 或 `#儒家` | 带这个标签（含其子标签） |
/// | `页:12-30`、`页:15`、`页:100-` | 页码范围（取位置里的第一个数字） |
/// | `有按语`、`有译文`、`收藏`、`记忆卡` | 只看带按语 / 带译文 / 收藏过的 / 已做成记忆卡的 |
///
/// 冒号全角半角都可以；英文写法 `source:` `author:` `tag:` `p:` 也认。
public struct ParsedSearch: Equatable, Sendable {
    public var terms: [String] = []
    public var excluded: [String] = []
    public var sources: [String] = []
    public var authors: [String] = []
    public var tags: [String] = []
    public var pageFrom: Int?
    public var pageTo: Int?
    public var hasNote = false
    public var hasTranslation = false
    public var favorite = false
    public var card = false

    public var isEmpty: Bool {
        terms.isEmpty && excluded.isEmpty && sources.isEmpty && authors.isEmpty && tags.isEmpty
            && pageFrom == nil && pageTo == nil && !hasNote && !hasTranslation && !favorite && !card
    }

    /// 用到了条件写法（而不只是关键词）
    public var hasConditions: Bool {
        !excluded.isEmpty || !sources.isEmpty || !authors.isEmpty || !tags.isEmpty
            || pageFrom != nil || pageTo != nil || hasNote || hasTranslation || favorite || card
    }
}

public enum SearchSyntax {
    static let prefixes: [(names: [String], key: String)] = [
        (["出处", "出處", "书名", "書名", "source", "src"], "source"),
        (["作者", "author"], "author"),
        (["标签", "標籤", "tag"], "tag"),
        (["页", "頁", "页码", "頁碼", "page", "p"], "page"),
    ]
    static let flags: [String: String] = [
        "有按语": "note", "有按語": "note", "按语": "note", "按語": "note",
        "有译文": "translation", "有譯文": "translation",
        "收藏": "favorite", "已收藏": "favorite",
        "记忆卡": "card", "記憶卡": "card", "有记忆卡": "card",
    ]

    /// 拆成词：引号（"" “” 「」）内的空格不拆
    static func tokens(_ s: String) -> [(text: String, quoted: Bool)] {
        var out: [(String, Bool)] = []
        var cur = ""
        var quote: Character?
        var curQuoted = false
        let closing: [Character: Character] = ["\"": "\"", "“": "”", "「": "」", "『": "』"]
        func flush() {
            if !cur.isEmpty { out.append((cur, curQuoted)) }
            cur = ""
            curQuoted = false
        }
        for ch in s {
            if let q = quote {
                if ch == closing[q] { quote = nil; flush() } else { cur.append(ch) }
            } else if closing[ch] != nil, cur.isEmpty || cur == "-" {
                quote = ch
                curQuoted = true
            } else if ch == " " || ch == "　" || ch == "\t" || ch == "\n" {
                flush()
            } else {
                cur.append(ch)
            }
        }
        flush()
        return out
    }

    public static func parse(_ query: String) -> ParsedSearch {
        var r = ParsedSearch()
        for (raw, quoted) in tokens(query) {
            var t = raw
            if quoted {
                if t.hasPrefix("-") { r.excluded.append(String(t.dropFirst())) } else { r.terms.append(t) }
                continue
            }
            if t.hasPrefix("#"), t.count > 1 { r.tags.append(String(t.dropFirst())); continue }
            if let flag = flags[t] {
                switch flag {
                case "note": r.hasNote = true
                case "translation": r.hasTranslation = true
                case "favorite": r.favorite = true
                default: r.card = true
                }
                continue
            }
            // 前缀：出处:xx、页:12-30
            if let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let name = String(t[..<colon]).lowercased()
                let value = String(t[t.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」"))
                if let p = prefixes.first(where: { $0.names.contains(name) }), !value.isEmpty {
                    switch p.key {
                    case "source": r.sources.append(value)
                    case "author": r.authors.append(value)
                    case "tag": r.tags.append(value.hasPrefix("#") ? String(value.dropFirst()) : value)
                    default:
                        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
                            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
                        if parts.count == 1 { r.pageFrom = parts[0]; r.pageTo = parts[0] }
                        else if parts.count == 2 { r.pageFrom = parts[0]; r.pageTo = parts[1] }
                    }
                    continue
                }
            }
            if t.hasPrefix("-"), t.count > 1 {
                t.removeFirst()
                r.excluded.append(t)
                continue
            }
            r.terms.append(t)
        }
        return r
    }

    /// 位置文字里的第一个整数（“第 14 页”→14，“p.120-121”→120，“卷三”→nil）
    public static func firstNumber(_ s: String?) -> Int? {
        guard let s else { return nil }
        var digits = ""
        for ch in s {
            if let d = ch.wholeNumberValue, ch.isASCII || ("０"..."９").contains(ch) {
                digits.append(String(d))
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}
