import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - 版本页码对照表导入（2.2）

/// 从对照表（Excel、CSV，或在 Excel 里复制的几列）一次导入摘录在另一个版本里的页码。
///
/// 表的每一行是“原版第几页 → 该版第几页”，可以再加一列篇名区分同页码不同篇：
/// - 三列：篇名、原页码、该版页码；
/// - 两列：原页码、该版页码。
/// 第一行若是表头（页码列不是数字）自动跳过。原页码可以写范围（“3-5”表示第 3 至 5 页都对应这一行）。
public enum EditionPageImport {

    public struct Row: Equatable, Sendable {
        public var chapter: String?
        public var original: ClosedRange<Int>
        public var edition: String
        public init(chapter: String?, original: ClosedRange<Int>, edition: String) {
            self.chapter = chapter; self.original = original; self.edition = edition
        }
    }

    public struct Match: Equatable, Sendable {
        public var highlightId: Int64
        public var page: String
    }

    public struct Result: Equatable, Sendable {
        public var matches: [Match]
        /// 有页码、但对照表里找不到的摘录
        public var unmatched: [Int64]
        /// 没有页码、无法对照的摘录
        public var noPage: [Int64]
    }

    // MARK: 读表

    /// CSV / TSV 文本 → 单元格（有制表符按制表符分，否则按逗号；支持双引号包起来的单元格）
    public static func cells(fromText text: String) -> [[String]] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let sep: Character = text.contains("\t") ? "\t" : (text.contains(",") ? "," : "，")
        return lines.map { line in
            var out: [String] = []
            var cur = ""
            var quoted = false
            var it = Array(line)
            var i = 0
            while i < it.count {
                let ch = it[i]
                if ch == "\"" {
                    if quoted, i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 }
                    else { quoted.toggle() }
                } else if ch == sep && !quoted {
                    out.append(cur); cur = ""
                } else {
                    cur.append(ch)
                }
                i += 1
            }
            out.append(cur)
            it.removeAll()
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// 读 .xlsx 第一张表：sharedStrings.xml（可无）与 sheet1.xml 的内容
    public static func cells(sheetXML: Data, sharedStringsXML: Data?) -> [[String]] {
        let shared = sharedStringsXML.map { SharedStrings.parse($0) } ?? []
        return SheetParser.parse(sheetXML, shared: shared)
    }

    static func pageRange(_ s: String) -> ClosedRange<Int>? {
        let parts = s.split(whereSeparator: { "-–—~～至".contains($0) })
        let nums = parts.compactMap { SearchSyntax.firstNumber(String($0)) }
        guard nums.count == parts.count, let a = nums.first else { return nil }
        let b = nums.count > 1 ? nums[1] : a
        return min(a, b)...max(a, b)
    }

    /// 单元格 → 对照行（跳过表头与空行）
    public static func rows(_ cells: [[String]]) -> [Row] {
        cells.compactMap { r in
            // 去掉行尾的空单元格（Excel 存 CSV 时会补逗号）；多出来的备注列不影响两列的读法
            var c = r
            while let last = c.last, last.trimmingCharacters(in: .whitespaces).isEmpty { c.removeLast() }
            guard c.filter({ !$0.isEmpty }).count >= 2 else { return nil }
            let three = c.count >= 3 && pageRange(c[1]) != nil && SearchSyntax.firstNumber(c[2]) != nil
            let chapter = three ? c[0].nonEmpty : nil
            let orig = three ? c[1] : c[0]
            let ed = (three ? c[2] : c[1]).trimmingCharacters(in: .whitespaces)
            guard let range = pageRange(orig), !ed.isEmpty, SearchSyntax.firstNumber(ed) != nil else { return nil }
            return Row(chapter: chapter.map(ClassicCitation.chapterName), original: range, edition: ed)
        }
    }

    // MARK: 对照

    /// 摘录的原页码：位置里页码部分的第一个数字（位置只有一个数字时也算）
    public static func originalPage(_ location: String?) -> Int? {
        let c = ClassicCitation.components(location)
        return SearchSyntax.firstNumber(c.page)
    }

    /// 按页码（和篇名，如果表里有）对上每条摘录；同一条有几行都对得上时取第一行
    public static func match(_ highlights: [Highlight], rows: [Row]) -> Result {
        var res = Result(matches: [], unmatched: [], noPage: [])
        for h in highlights {
            guard let id = h.id else { continue }
            guard let p = originalPage(h.location) else { res.noPage.append(id); continue }
            let ch = ClassicCitation.chapterKey(h.location)
            let hit = rows.first { r in
                r.original.contains(p) && (r.chapter == nil || ch == nil || r.chapter == ch)
            }
            if let hit { res.matches.append(Match(highlightId: id, page: hit.edition)) } else { res.unmatched.append(id) }
        }
        return res
    }
}

// MARK: - xlsx 的两个 XML

private final class SharedStrings: NSObject, XMLParserDelegate {
    var items: [String] = []
    var cur = ""
    var inT = false
    var inSI = false
    /// 注音（<rPh>）里的文字不算单元格内容
    var inPh = false

    static func parse(_ data: Data) -> [String] {
        let d = SharedStrings()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { inSI = true; cur = "" }
        if name == "t" { inT = true }
        if name == "rPh" { inPh = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inSI && inT && !inPh { cur += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false }
        if name == "rPh" { inPh = false }
        if name == "si" { items.append(cur); inSI = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    var shared: [String] = []
    var rows: [[String]] = []
    var row: [Int: String] = [:]
    var col = 0
    var type = ""
    var value = ""
    var inV = false
    var inIS = false

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let d = SheetParser()
        d.shared = shared
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.rows
    }

    /// “C12”→ 列序号 2
    static func column(_ ref: String) -> Int {
        var n = 0
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row": row = [:]
        case "c":
            col = attributes["r"].map(Self.column) ?? (row.keys.max().map { $0 + 1 } ?? 0)
            type = attributes["t"] ?? ""
            value = ""
        case "v": inV = true
        case "is": inIS = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inV || inIS { value += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inV = false
        case "is": inIS = false
        case "c":
            var v = value
            if type == "s", let i = Int(v), i < shared.count { v = shared[i] }
            // 数字单元格去掉 “3.0” 的小数部分
            if type.isEmpty || type == "n", let d = Double(v), d == d.rounded(), abs(d) < 1e15 { v = String(Int(d)) }
            row[col] = v
        case "row":
            let n = (row.keys.max() ?? -1) + 1
            rows.append((0..<n).map { row[$0] ?? "" })
        default: break
        }
    }
}
