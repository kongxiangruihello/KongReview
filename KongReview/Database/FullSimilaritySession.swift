import Foundation
import GRDB
import KongReviewCore

/// 会话只保留 ID、游标和一批正文；暂停不会丢失游标。新加入的卡在重新扫描时纳入。
actor FullSimilaritySession {
    struct Progress: Sendable {
        var completed: Int
        var total: Int
        var compared: Int
        var groups: [CardDuplicateGroup]
        var finished: Bool
    }
    private let db: AppDatabase
    private let ids: [Int64]
    private let deck: String?
    private var leftIndex = 0
    private var rightID: Int64 = 0
    private var compared = 0
    private var left: CardSimilarity.Candidate?
    private var leftLoaded = false

    init(db: AppDatabase, ids: [Int64], deck: String?) {
        self.db = db; self.ids = ids; self.deck = deck
    }
    static func create(db: AppDatabase, deck: String?) async throws -> FullSimilaritySession {
        let ids = try await db.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT id FROM card WHERE deletedAt IS NULL" + (deck == nil ? "" : " AND deck=?") + " ORDER BY id", arguments: StatementArguments(deck.map { [$0] } ?? []))
        }
        return FullSimilaritySession(db: db, ids: ids, deck: deck)
    }
    func nextBatch() throws -> Progress {
        try Task.checkCancellation()
        guard leftIndex < ids.count else { return .init(completed: ids.count, total: ids.count, compared: compared, groups: [], finished: true) }
        let id = ids[leftIndex]
        if !leftLoaded {
            let card = try db.writer.read { connection in try Card.fetchOne(connection, key: id) }
            left = card.flatMap { $0.deletedAt == nil && (deck == nil || $0.deck == deck) ? CardSimilarity.candidate($0, includeLongText: true) : nil }
            leftLoaded = true
            rightID = id
        }
        guard let left else {
            leftIndex += 1; leftLoaded = false
            return .init(completed: leftIndex, total: ids.count, compared: compared, groups: [], finished: leftIndex == ids.count)
        }
        let cursor = rightID, maximum = ids.last ?? 0, deck = self.deck
        let cards = try db.writer.read { connection in
            try Card.fetchAll(connection, sql: "SELECT * FROM card WHERE deletedAt IS NULL AND id>? AND id<=?" + (deck == nil ? "" : " AND deck=?") + " ORDER BY id LIMIT 32", arguments: StatementArguments([cursor, maximum] as [any DatabaseValueConvertible] + (deck.map { [$0] } ?? [])))
        }
        var groups: [CardDuplicateGroup] = []
        // 提交游标在批次成功完成之后，取消/失败不会漏掉剩余候选。
        for card in cards {
            try Task.checkCancellation()
            if let other = CardSimilarity.candidate(card, includeLongText: true),
               left.signature != other.signature, let score = CardSimilarity.score(left, other) {
                groups.append(.init(signature: other.signature, cards: [left.card, card], similarityScore: score))
            }
        }
        compared += cards.count
        if let last = cards.last?.id { rightID = last }
        if cards.count < 32 { leftIndex += 1; leftLoaded = false; self.left = nil }
        return .init(completed: leftIndex, total: ids.count, compared: compared, groups: groups, finished: leftIndex == ids.count)
    }
}

extension LibraryStore {
    func pauseFullSimilarity() {
        fullSimilarityRunID = UUID()
        fullSimilarityTask?.cancel()
        duplicateCardReview?.scanning = false
        duplicateCardReview?.paused = true
    }
    func continueFullSimilarity() {
        guard let state = duplicateCardReview, state.mode == .similar, !state.processing else { return }
        let token = state.scanID, deck = state.scopeDeck
        let runID = UUID()
        fullSimilarityRunID = runID
        duplicateCardReview?.scanning = true
        duplicateCardReview?.paused = false
        fullSimilarityTask?.cancel()
        fullSimilarityTask = Task { @MainActor in
            do {
                if fullSimilaritySession == nil {
                    let session = try await FullSimilaritySession.create(db: db, deck: deck)
                    try Task.checkCancellation()
                    guard duplicateCardReview?.scanID == token else { return }
                    fullSimilaritySession = session
                }
                guard let session = fullSimilaritySession else { return }
                while !Task.isCancelled {
                    let progress = try await session.nextBatch()
                    // 一批成功提交的结果即使恰逢暂停也保留，避免游标前移却漏掉建议。
                    guard duplicateCardReview?.scanID == token else { return }
                    duplicateCardReview?.groups += progress.groups
                    guard fullSimilarityRunID == runID else { return }
                    duplicateCardReview?.scanNote = "已检查 \(progress.completed) / \(progress.total) 张起始卡，完成 \(progress.compared) 对比较。包含长卡片；相似不代表重复。新增或修改内容后请重新扫描。"
                    if progress.finished {
                        duplicateCardReview?.scanning = false
                        duplicateCardReview?.paused = false
                        fullSimilaritySession = nil
                        return
                    }
                    if (duplicateCardReview?.groups.count ?? 0) >= 200 {
                        pauseFullSimilarity()
                        duplicateCardReview?.scanNote = (duplicateCardReview?.scanNote ?? "") + " 已积累200组建议，请先整理或清空本批建议，再继续。"
                        return
                    }
                }
            } catch is CancellationError { }
            catch {
                guard duplicateCardReview?.scanID == token, fullSimilarityRunID == runID else { return }
                duplicateCardReview?.error = error.localizedDescription
                duplicateCardReview?.scanning = false
                duplicateCardReview?.paused = true
            }
        }
    }
}
