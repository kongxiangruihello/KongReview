import Foundation

// MARK: - 6.2：对照要点（idea units）
//
// 判分前把标准答案分成几个“要点”，看自己的回答写出了几处，再自己判。依据：
// Dunlosky, Hartwig, Rawson & Lipko (2011) 提出按要点对照（idea-unit standards），比只给完整答案自评更准；
// Nederhand, Tabbers, Abrahimi & Rikers (2018, Journal of Cognitive Psychology) 重复了这一结果；
// Dunlosky & Rawson (2012, Learning and Instruction 22:271–280)：自评越准，两天后记得越牢，自评偏高的会过早停止复习。
// 这里只做提示，不代替判分：要点由原文按标点切分（原文里有加粗、标记的，以标出的为要点），
// 每个要点的字（汉字取相邻两字，西文取词）有一半以上出现在回答里，就算写出。

/// 一个要点及是否在回答里写出
public struct IdeaUnit: Equatable, Sendable {
    public var text: String
    public var hit: Bool
    public init(text: String, hit: Bool) { self.text = text; self.hit = hit }
}

/// 一道题的对照结果
public struct IdeaUnitMatch: Equatable, Sendable {
    public var units: [IdeaUnit]
    public var hits: Int { units.filter(\.hit).count }
    public var total: Int { units.count }
    /// 写出的比例（没有要点时为 nil）
    public var coverage: Double? { total > 0 ? Double(hits) / Double(total) : nil }
    public init(units: [IdeaUnit]) { self.units = units }
}

/// 自评与要点对照是否一致
public enum CalibrationVerdict: String, Sendable {
    /// 判“记得”，要点写出不到一半
    case over
    /// 判“忘了”，要点写出八成以上
    case under
    case fair
}

public enum IdeaUnits {
    /// 要点至多几处：多于此数时按句（。！？；换行）合并
    public static let maximumUnits = 12
    /// 一个要点写出几成算写出
    public static let hitThreshold = 0.5

    /// 从纯文字的标准答案里切出要点；`marked` 是原文里加粗、标记的片段（有就以它们为准）
    public static func units(from answer: String, marked: [String] = []) -> [String] {
        let picked = marked.map(clean).filter { tokens($0).count >= 1 }
        if !picked.isEmpty { return Array(dedupe(picked).prefix(maximumUnits)) }
        let clauses = split(answer, by: "，,。.；;：:！!？?、\n")
        let usable = mergeShort(clauses)
        if usable.count <= maximumUnits { return usable }
        let sentences = mergeShort(split(answer, by: "。.；;！!？?\n"))
        return Array(sentences.prefix(maximumUnits))
    }

    /// 从原文里取加粗、标记、下划线的片段：HTML 的 <b>、<strong>、<mark>、<u>，Markdown 的 **…**、__…__、==…==。
    /// 标题不算（只认原文里的这几种写法，不经 HTML 转换，免得标题变粗体后被当成要点）
    public static func markedSpans(in source: String) -> [String] {
        let patterns = ["<(b|strong|mark|u)(\\s[^>]*)?>(.*?)</\\1>", "(\\*\\*|__|==)(.+?)\\1"]
        var found: [(Int, String)] = []
        let ns = source as NSString
        for (i, pattern) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let inner = ns.substring(with: m.range(at: i == 0 ? 3 : 2))
                let text = Markdown.plainText(fromHTML: inner).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { found.append((m.range.location, text)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 要点里用来比较的部分：去掉开头的短标签（“按：”“新录示例：”）
    public static func body(of unit: String) -> String {
        var rest = Substring(unit)
        while let r = rest.firstIndex(where: { $0 == "：" || $0 == ":" }), rest.distance(from: rest.startIndex, to: r) < labelLength {
            let after = rest[rest.index(after: r)...]
            guard !after.isEmpty else { break }
            rest = after
        }
        return String(rest)
    }

    /// 回答与要点对照
    public static func match(answer: String, units: [String]) -> IdeaUnitMatch {
        let have = Set(tokens(answer))
        return IdeaUnitMatch(units: units.map { u in
            let t = tokens(body(of: u))
            guard !t.isEmpty else { return IdeaUnit(text: u, hit: false) }
            let found = t.filter { have.contains($0) }.count
            return IdeaUnit(text: u, hit: Double(found) / Double(t.count) >= hitThreshold)
        })
    }

    /// 便捷：标准答案为纯文字
    public static func match(answer: String, standard: String, marked: [String] = []) -> IdeaUnitMatch {
        match(answer: answer, units: units(from: standard, marked: marked))
    }

    /// 自己判的分
    public enum Grade: Sendable { case remembered, partly, forgot }

    /// 自评对不对得上：判“记得”而要点写出不到一半为偏高；判“忘了”而写出八成以上为偏低
    public static func verdict(_ grade: Grade, coverage: Double) -> CalibrationVerdict {
        if grade == .remembered && coverage < 0.5 { return .over }
        if grade == .forgot && coverage >= 0.8 { return .under }
        return .fair
    }

    // MARK: 切分与比较

    /// 比较用的记号：汉字（繁简归一）取相邻两字，单独一个汉字取它本身；西文、数字取整词（小写）
    public static func tokens(_ text: String) -> [String] {
        let folded = ChineseFold.fold(text).lowercased()
        var out: [String] = []
        var han: [Character] = []
        var word = ""
        func flushHan() {
            if han.count == 1 { out.append(String(han[0])) }
            else if han.count > 1 { for i in 0..<(han.count - 1) { out.append(String([han[i], han[i + 1]])) } }
            han.removeAll()
        }
        func flushWord() { if !word.isEmpty { out.append(word); word = "" } }
        for ch in folded {
            if isHan(ch) { flushWord(); han.append(ch) }
            else if ch.isLetter || ch.isNumber { flushHan(); word.append(ch) }
            else { flushHan(); flushWord() }
        }
        flushHan(); flushWord()
        return out
    }

    private static func isHan(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x20000...0x2FA1F).contains(s.value)
        }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// 冒号前不足几个字的算标签（“按：”“朱注：”“新录示例：”），并入后一句，不单算一处
    public static let labelLength = 5
    /// 不足几个字的片段并到相邻一段（“子曰”“然则”之类）
    public static let shortLength = 4

    private static func split(_ text: String, by marks: String) -> [String] {
        let set = Set(marks)
        let colons: Set<Character> = ["：", ":"]
        var parts: [String] = []
        var cur = ""
        var label = ""
        for ch in text {
            if set.contains(ch) {
                let piece = clean(cur)
                if colons.contains(ch), !piece.isEmpty, piece.count < labelLength {
                    // 6.2.2：冒号前的短标签留着，接到下一段前面
                    label += piece + "："
                } else {
                    if !(label + piece).isEmpty { parts.append(label + piece) }
                    label = ""
                }
                cur = ""
            } else { cur.append(ch) }
        }
        let rest = clean(cur)
        if !(label + rest).isEmpty { parts.append(label + rest) }
        return parts.map(clean).filter { !tokens($0).isEmpty }
    }

    /// 太短的片段并到前一段（开头的并到后一段），免得“曰”“也”之类单算一处
    private static func mergeShort(_ parts: [String]) -> [String] {
        var out: [String] = []
        for p in parts {
            if p.count < shortLength, let last = out.popLast() { out.append(last + "，" + p) } else { out.append(p) }
        }
        if out.count > 1, let first = out.first, first.count < shortLength { out.removeFirst(); out[0] = first + "，" + out[0] }
        return dedupe(out)
    }

    private static func dedupe(_ parts: [String]) -> [String] {
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }
    }
}
