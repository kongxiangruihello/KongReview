import Foundation
import KongReviewCore

struct ParagraphDifference {
    enum Kind { case unchanged, added, removed, modified }
    struct Row: Identifiable { var id: Int; var text: String; var kind: Kind }
    var before: [Row]
    var after: [Row]
    var coarse = false
    static func make(before oldSource: String,after newSource: String) -> Self {
        func paragraphs(_ s: String) -> [String] {
            Markdown.plainText(fromHTML:Markdown.html(s).replacingOccurrences(of:#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,with:"",options:.regularExpression)).components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let old = paragraphs(oldSource), new = paragraphs(newSource)
        var oldKinds = Array(repeating:Kind.removed,count:old.count), newKinds = Array(repeating:Kind.added,count:new.count)
        var pairs: [(Int,Int)] = [], coarse = false
        if old.count * new.count <= 300_000 {
            let width = new.count+1
            var table = Array(repeating:0,count:(old.count+1)*width)
            if !old.isEmpty && !new.isEmpty {
                for i in (0..<old.count).reversed() {
                    for j in (0..<new.count).reversed() {
                        table[i*width+j] = old[i] == new[j] ? table[(i+1)*width+j+1]+1 : max(table[(i+1)*width+j],table[i*width+j+1])
                    }
                }
            }
            var i = 0, j = 0
            while i < old.count && j < new.count {
                if old[i] == new[j] { pairs.append((i,j)); i += 1; j += 1 }
                else if table[(i+1)*width+j] >= table[i*width+j+1] { i += 1 }
                else { j += 1 }
            }
        } else {
            coarse = true
            var start = 0
            while start < min(old.count,new.count), old[start] == new[start] { pairs.append((start,start)); start += 1 }
            var i = old.count-1, j = new.count-1, tail: [(Int,Int)] = []
            while i >= start && j >= start && old[i] == new[j] { tail.append((i,j)); i -= 1; j -= 1 }
            pairs += tail.reversed()
        }
        var previousOld = -1, previousNew = -1
        for pair in pairs + [(old.count,new.count)] {
            let oldRange = (previousOld+1)..<pair.0, newRange = (previousNew+1)..<pair.1
            if !oldRange.isEmpty && !newRange.isEmpty {
                for i in oldRange { oldKinds[i] = .modified }
                for i in newRange { newKinds[i] = .modified }
            }
            if pair.0 < old.count { oldKinds[pair.0] = .unchanged; newKinds[pair.1] = .unchanged }
            previousOld = pair.0; previousNew = pair.1
        }
        return .init(before:old.indices.map { .init(id:$0,text:old[$0],kind:oldKinds[$0]) },after:new.indices.map { .init(id:$0,text:new[$0],kind:newKinds[$0]) },coarse:coarse)
    }
}
