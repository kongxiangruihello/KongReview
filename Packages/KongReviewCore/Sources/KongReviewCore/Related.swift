import Foundation

/// “相关摘录”：按用词相近程度（汉字两字组 + 西文单词，TF-IDF 加权）找出与某条摘录最相近的几条，
/// 再给同标签、同出处的加一点分。全部在内存里算，2 万条摘录建索引约几百毫秒，查询是毫秒级。
public struct RelatedIndex: Sendable {
    public struct Doc: Sendable {
        public var id: Int64
        public var text: String
        public var tags: [String]
        public var sourceId: Int64?
        public init(id: Int64, text: String, tags: [String], sourceId: Int64?) {
            self.id = id; self.text = text; self.tags = tags; self.sourceId = sourceId
        }
    }

    public struct Hit: Equatable, Sendable {
        public var id: Int64
        public var score: Double
        /// 共有的标签
        public var sharedTags: [String]
        public var sameSource: Bool
    }

    private var postings: [String: [(Int, Double)]] = [:]   // 词 → (文档序号, 权重)
    private var docTerms: [[String: Double]] = []           // 文档序号 → 词 → 权重（已归一化）
    private var docs: [Doc] = []
    private var indexOf: [Int64: Int] = [:]

    public var count: Int { docs.count }

    /// 汉字取相邻两字（“学而”“而时”…），西文与数字取整词（小写），去掉标点空白
    public static func terms(_ text: String) -> [String] {
        var out: [String] = []
        var han: [Character] = []
        var word = ""
        func flushHan() {
            if han.count == 1 { out.append(String(han[0])) }
            if han.count >= 2 { for i in 0..<(han.count - 1) { out.append(String(han[i...i + 1])) } }
            han = []
        }
        func flushWord() {
            if word.count >= 2 { out.append(word.lowercased()) }
            word = ""
        }
        for ch in text {
            if let u = ch.unicodeScalars.first, (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) {
                flushWord()
                han.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushHan()
                word.append(ch)
            } else {
                flushHan()
                flushWord()
            }
        }
        flushHan(); flushWord()
        return out
    }

    public init(_ input: [Doc]) {
        docs = input
        var df: [String: Int] = [:]
        var tfs: [[String: Int]] = []
        tfs.reserveCapacity(input.count)
        for (i, d) in input.enumerated() {
            indexOf[d.id] = i
            var tf: [String: Int] = [:]
            for t in Self.terms(d.text) { tf[t, default: 0] += 1 }
            for t in tf.keys { df[t, default: 0] += 1 }
            tfs.append(tf)
        }
        let n = Double(max(1, input.count))
        // 出现在 5% 以上文档里的词（如“之”“而”“的”的组合）区分度低，不进索引
        let maxDF = max(3, Int(n * 0.05))
        docTerms.reserveCapacity(tfs.count)
        for (i, tf) in tfs.enumerated() {
            var w: [String: Double] = [:]
            var norm = 0.0
            for (t, c) in tf {
                let d = df[t] ?? 1
                guard d >= 2, d <= maxDF else { continue }   // 只出现一次的词也无从“相关”
                let v = (1 + log(Double(c))) * log(n / Double(d))
                w[t] = v
                norm += v * v
            }
            norm = sqrt(norm)
            if norm > 0 { for (t, v) in w { w[t] = v / norm } }
            for (t, v) in w { postings[t, default: []].append((i, v)) }
            docTerms.append(w)
        }
    }

    /// 与某条摘录最相关的若干条（余弦相似度 + 同标签 0.08/个 + 同出处 0.03）
    public func related(to id: Int64, limit: Int = 5, minScore: Double = 0.12) -> [Hit] {
        guard let i = indexOf[id] else { return [] }
        var scores: [Int: Double] = [:]
        for (t, w) in docTerms[i] {
            for (j, v) in postings[t] ?? [] where j != i { scores[j, default: 0] += w * v }
        }
        let me = docs[i]
        let myTags = Set(me.tags)
        // 只有同标签的也纳入候选
        if !myTags.isEmpty {
            for (j, d) in docs.enumerated() where j != i && scores[j] == nil && !myTags.isDisjoint(with: d.tags) {
                scores[j] = 0
            }
        }
        var hits: [Hit] = []
        for (j, s) in scores {
            let d = docs[j]
            let shared = d.tags.filter { myTags.contains($0) }
            let same = me.sourceId != nil && d.sourceId == me.sourceId
            let total = s + 0.08 * Double(shared.count) + (same ? 0.03 : 0)
            if total >= minScore { hits.append(Hit(id: d.id, score: total, sharedTags: shared, sameSource: same)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return Array(hits.prefix(limit))
    }
}
