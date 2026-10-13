import Foundation

// MARK: - 标签整理（1.1）

/// 标签可以用“/”分层，如“儒家/孟子”。父标签包含其下所有子标签。
public enum TagOps {
    public static let separator: Character = "/"

    /// 规范化：去首尾空白、去掉开头的 #、把“／”和“ / ”统一成“/”、去掉空层级
    public static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.replacingOccurrences(of: "／", with: "/")
        let parts = t.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }

    /// tag 是否等于 parent 或在 parent 之下
    public static func isWithin(_ tag: String, _ parent: String) -> Bool {
        tag == parent || tag.hasPrefix(parent + "/")
    }

    /// 改名（也用于合并：改成已有的标签名即合并）。子标签随父标签一起改：“儒家/孟子”→“先秦儒家/孟子”。
    /// 结果去重，保持原有顺序。
    public static func rename(_ tags: [String], from old: String, to new: String) -> [String] {
        let new = normalize(new)
        var out: [String] = []
        for t in tags {
            var r = t
            if t == old {
                r = new
            } else if t.hasPrefix(old + "/") {
                r = new.isEmpty ? String(t.dropFirst(old.count + 1)) : new + t.dropFirst(old.count)
            }
            if !r.isEmpty, !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// 删除标签（连同其下的子标签）
    public static func remove(_ tags: [String], tag: String) -> [String] {
        tags.filter { !isWithin($0, tag) }
    }
}

/// 侧边栏里的标签树
public struct TagNode: Identifiable, Hashable, Sendable {
    public var path: String          // 完整路径，如“儒家/孟子”
    public var name: String          // 本层名字，如“孟子”
    public var count: Int            // 本标签及子标签下的摘录数（同一条摘录只算一次由调用方保证；这里是简单相加的上界）
    public var ownCount: Int         // 恰好带这个标签的摘录数
    public var children: [TagNode]
    public var id: String { path }
    /// 给 OutlineGroup 用：没有子标签时为 nil（不显示展开箭头）
    public var childrenOrNil: [TagNode]? { children.isEmpty ? nil : children }

    /// 由“标签 → 摘录数”建树；中间层即使自己没有摘录也会出现。按名字排序。
    public static func tree(_ counts: [String: Int]) -> [TagNode] {
        final class Box {
            var name: String, path: String, own = 0
            var kids: [String: Box] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }
            func node() -> TagNode {
                let children = kids.values.map { $0.node() }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return TagNode(path: path, name: name, count: own + children.reduce(0) { $0 + $1.count },
                               ownCount: own, children: children)
            }
        }
        let root = Box(name: "", path: "")
        for (tag, n) in counts {
            let parts = tag.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var cur = root
            var path = ""
            for p in parts {
                path = path.isEmpty ? p : path + "/" + p
                if let next = cur.kids[p] {
                    cur = next
                } else {
                    let b = Box(name: p, path: path)
                    cur.kids[p] = b
                    cur = b
                }
            }
            cur.own += n
        }
        return root.node().children
    }
}
