import Foundation
import KongReviewCore

enum MediaReferenceInventory {
    static func references(inJSON data: Data) throws -> Set<String> {
        var pending: [Any] = [try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)]
        var names = Set<String>()
        while let value = pending.popLast() {
            if let text = value as? String { names.formUnion(AnkiPackage.mediaReferences(in:text)) }
            else if let object = value as? [String:Any] { pending.append(contentsOf:object.values) }
            else if let array = value as? [Any] { pending.append(contentsOf:array) }
        }
        return names
    }
}
