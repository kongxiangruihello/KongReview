import Foundation

// MARK: - 重复摘录（1.5）

/// 找出重复或高度相似的摘录。
///
/// - 完全重复：繁简、全半角、大小写归一，去掉空白、标点与 Markdown 标记后文字相同（跨出处也算）；
/// - 高度相似：同一出处内，一条包含另一条且长度相差不到两成，或三字片段的重合度 ≥ 0.8
///   （PDF 重复摘取时多一两个字、断句不同的情形）。
public enum DuplicateFinder {

    public struct Item: Sendable, Equatable {
        public var id: Int64
        public var text: String
        public var sourceId: Int64?
        public init(id: Int64, text: String, sourceId: Int64?) {
            self.id = id
            self.text = text
            self.sourceId = sourceId
        }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        /// 组内各条（按 id 升序）
        public var ids: [Int64]
        /// 完全重复（归一后文字相同）还是相似
        public var exact: Bool
        /// 组的标识：各条 id 用“-”连接（用来记住“不是重复”）
        public var id: String { ids.map(String.init).joined(separator: "-") }
    }

    /// 比较用的文字：繁简归一、去掉空白、标点、Markdown 与 HTML 标记
    public static func key(_ text: String) -> String {
        var t = text
        if Markdown.containsHTMLTag(t) { t = Markdown.markdown(fromHTMLFragments: t) }
        t = Markdown.replace(t, #"!\[[^\]]*\]\(([^)]*)\)"#, "［图$1］")
        t = Markdown.replace(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = ChineseFold.fold(t)
        return String(t.unicodeScalars.filter { s in
            !CharacterSet.whitespacesAndNewlines.contains(s)
                && !CharacterSet.punctuationCharacters.contains(s)
                && !CharacterSet.symbols.contains(s)
        }.map(Character.init))
    }

    static func trigrams(_ s: String) -> Set<String> {
        let a = Array(s)
        guard a.count >= 3 else { return [s] }
        var out = Set<String>()
        for i in 0...(a.count - 3) { out.insert(String(a[i..<(i + 3)])) }
        return out
    }

    /// 与运行无关的稳定哈希（FNV-1a）
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// 两段归一后文字是否“高度相似”
    public static func similar(_ a: String, _ b: String, _ ta0: Set<String>? = nil, _ tb0: Set<String>? = nil) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 6 else { return false }   // 太短（人名、词语）不算
        let ratio = Double(short.count) / Double(long.count)
        if ratio >= 0.8 && long.contains(short) { return true }
        guard ratio >= 0.7 else { return false }
        let ta = ta0 ?? trigrams(a), tb = tb0 ?? trigrams(b)
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union > 0 && Double(inter) / Double(union) >= 0.8
    }

    /// maxPerSource：同一出处内做两两比较的上限（超过时只找完全重复）
    public static func groups(_ items: [Item], maxPerSource: Int = 3000, ignored: Set<String> = []) -> [Group] {
        // 并查集
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: Int64, _ b: Int64) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var keys: [Int64: String] = [:]
        for it in items {
            parent[it.id] = it.id
            keys[it.id] = key(it.text)
        }
        // 完全重复
        var byKey: [String: [Int64]] = [:]
        for it in items {
            guard let k = keys[it.id], k.count >= 2 else { continue }
            byKey[k, default: []].append(it.id)
        }
        for (_, ids) in byKey where ids.count > 1 {
            for id in ids.dropFirst() { union(ids[0], id) }
        }
        // 同出处内相似：先用“最小哈希”分桶找候选（每条取三字片段哈希最小的 4 个），只比较同桶的，
        // 避免两两比较（一个出处几千条时两两比较要上千万次）
        var tri: [Int64: Set<String>] = [:]
        var buckets: [String: [Int64]] = [:]
        for it in items {
            guard let s = it.sourceId, let k = keys[it.id], k.count >= 6 else { continue }
            let t = trigrams(k)
            tri[it.id] = t
            let mins = t.map { stableHash($0) }.sorted().prefix(4)
            for h in mins { buckets["\(s)|\(h)", default: []].append(it.id) }
        }
        var tested = Set<String>()
        for (_, ids) in buckets where ids.count > 1 && ids.count <= 200 {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let x = ids[i], y = ids[j]
                    guard find(x) != find(y) else { continue }
                    let pk = x < y ? "\(x)-\(y)" : "\(y)-\(x)"
                    guard tested.insert(pk).inserted else { continue }
                    guard let kx = keys[x], let ky = keys[y], kx != ky else { continue }
                    if similar(kx, ky, tri[x], tri[y]) { union(x, y) }
                }
            }
        }
        _ = maxPerSource
        var members: [Int64: [Int64]] = [:]
        for it in items { members[find(it.id), default: []].append(it.id) }
        var out: [Group] = []
        for (_, ids) in members where ids.count > 1 {
            let sorted = ids.sorted()
            // 组内所有条目的 key 都相同才算“完全重复”
            let allSame = Set(sorted.compactMap { keys[$0] }).count == 1
            let g = Group(ids: sorted, exact: allSame)
            if !ignored.contains(g.id) { out.append(g) }
        }
        return out.sorted { a, b in
            if a.exact != b.exact { return a.exact }
            return a.ids[0] < b.ids[0]
        }
    }

    /// 合并后的字段：保留 keeper 的原文与出处，其余合并
    public static func merged(keeper: Highlight, others: [Highlight]) -> Highlight {
        var h = keeper
        func joinText(_ a: String?, _ b: String?) -> String? {
            let x = a?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let y = b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if y.isEmpty || x.contains(y) { return x.isEmpty ? nil : x }
            if x.isEmpty || y.contains(x) { return y }
            return x + "\n\n" + y
        }
        for o in others {
            h.note = joinText(h.note, o.note)
            if (h.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { h.translation = o.translation }
            if (h.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { h.location = o.location }
            if h.sourceId == nil { h.sourceId = o.sourceId }
            for t in o.tags where !h.tags.contains(t) { h.tags.append(t) }
            h.isFavorite = h.isFavorite || o.isFavorite
            if let f = o.frequency, f > (h.frequency ?? 0) { h.frequency = f }
            h.surfacedCount += o.surfacedCount
            if let d = o.lastSurfacedAt, d > (h.lastSurfacedAt ?? .distantPast) { h.lastSurfacedAt = d }
            if o.createdAt < h.createdAt { h.createdAt = o.createdAt }
        }
        // 弃置：只要有一条没弃置，合并后就不弃置
        h.isDiscarded = h.isDiscarded && others.allSatisfy(\.isDiscarded)
        return h
    }
}
