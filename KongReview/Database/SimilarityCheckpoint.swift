import Foundation
import CryptoKit
import GRDB
import KongReviewCore

struct SimilarityCheckpoint: Codable, Sendable {
    static let key = "similarity.checkpoint.v1"
    var ids: [Int64]
    var deck: String?
    var leftIndex: Int
    var rightID: Int64
    var compared: Int
    var fingerprint: String
    var groups: [CardDuplicateGroup]
    var finished: Bool
}
extension AppDatabase {
    func similarityInventory(deck: String?) async throws -> (ids: [Int64], fingerprint: String) {
        try await writer.read { db in
            let rows = try Row.fetchAll(db,sql:"SELECT id,updatedAt FROM card WHERE deletedAt IS NULL" + (deck == nil ? "":" AND deck=?") + " ORDER BY id",arguments:StatementArguments(deck.map { [$0] } ?? []))
            var hash=SHA256()
            let ids: [Int64] = rows.map { row in
                let id: Int64=row["id"], date: Date=row["updatedAt"]
                hash.update(data:Data("\(id):\(date.timeIntervalSince1970);".utf8)); return id
            }
            return (ids,hash.finalize().map { String(format:"%02x",$0) }.joined())
        }
    }
}
extension LibraryStore {
    func resumeSavedSimilarity() {
        guard duplicateCardReview?.processing != true else { return }
        do {
            guard let saved=try db.progressValue(SimilarityCheckpoint.self,key:SimilarityCheckpoint.key) else {
                infoMessage="没有保存的扫描进度，请先开始一次相似卡扫描。"; return
            }
            var state=CardDuplicateReview(); state.mode = .similar; state.scopeDeck=saved.deck; state.resumeSaved=true
            duplicateCardReview=state
            fullSimilarityTask?.cancel(); fullSimilaritySession=nil
            continueFullSimilarity()
        } catch { report(error) }
    }
}
