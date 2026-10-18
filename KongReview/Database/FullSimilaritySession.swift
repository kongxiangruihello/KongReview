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
    private var fingerprint = ""
    private var restoredGroups: [CardDuplicateGroup] = []
    private var restartNotice: String?
    private var leftIndex = 0
    private var rightID: Int64 = 0
    private var compared = 0
    private var left: CardSimilarity.Candidate?
    private var leftLoaded = false

    init(db: AppDatabase, ids: [Int64], deck: String?) {
        self.db = db; self.ids = ids; self.deck = deck
    }
    static func create(db: AppDatabase, deck: String?, resume: Bool = false) async throws -> FullSimilaritySession {
        let inventory = try await db.similarityInventory(deck: deck)
        let saved = resume ? try db.progressValue(SimilarityCheckpoint.self,key:SimilarityCheckpoint.key) : nil
        let session = FullSimilaritySession(db:db,ids:inventory.ids,deck:deck)
        await session.restoreCheckpoint(saved, fingerprint:inventory.fingerprint)
        return session
    }
    private func restoreCheckpoint(_ saved: SimilarityCheckpoint?, fingerprint: String) {
        self.fingerprint = fingerprint
        guard let saved else { return }
        guard saved.fingerprint == fingerprint, saved.deck == deck, saved.ids == ids,
              saved.leftIndex >= 0, saved.leftIndex <= ids.count, saved.compared >= 0,
              saved.rightID >= 0, saved.rightID <= (ids.last ?? 0),
              saved.compared <= ids.count * max(0,ids.count-1) / 2 else {
            restartNotice = "资料或学习状态已变化，已安全重新扫描，避免遗漏新增、修改或删除的卡片。"
            return
        }
        leftIndex = saved.leftIndex; rightID = saved.rightID; compared = saved.compared
        restoredGroups = saved.groups
    }
    func inventoryUnchanged() async throws -> Bool { try await db.similarityInventory(deck: deck).fingerprint == fingerprint }
    func restoredResult() -> (groups: [CardDuplicateGroup], notice: String?) { (restoredGroups,restartNotice) }
    func saveCheckpoint(groups: [CardDuplicateGroup]) throws {
        try db.saveProgress(SimilarityCheckpoint(ids:ids,deck:deck,leftIndex:leftIndex,rightID:rightID,compared:compared,
            fingerprint:fingerprint,groups:groups,finished:leftIndex == ids.count),key:SimilarityCheckpoint.key)
    }
    func nextBatch() throws -> Progress {
        try Task.checkCancellation()
        guard leftIndex < ids.count else { return .init(completed: ids.count, total: ids.count, compared: compared, groups: [], finished: true) }
        let id = ids[leftIndex]
        if !leftLoaded {
            let card = try db.writer.read { connection in try Card.fetchOne(connection, key: id) }
            left = card.flatMap { $0.deletedAt == nil && (deck == nil || $0.deck == deck) ? CardSimilarity.candidate($0, includeLongText: true) : nil }
            leftLoaded = true
            rightID = max(rightID, id)
        }
        guard let left else {
            leftIndex += 1; rightID = 0; leftLoaded = false
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
        if cards.count < 32 { leftIndex += 1; rightID = 0; leftLoaded = false; self.left = nil }
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
        let startingRevision = revision
        let runID = UUID()
        fullSimilarityRunID = runID
        duplicateCardReview?.scanning = true
        duplicateCardReview?.paused = false
        let previousTask = fullSimilarityTask
        fullSimilarityTask?.cancel()
        fullSimilarityTask = Task { @MainActor in
            do {
                await previousTask?.value
                try Task.checkCancellation()
                var shouldResume = state.resumeSaved
                if let existing = fullSimilaritySession, !(try await existing.inventoryUnchanged()) {
                    fullSimilaritySession = nil
                    shouldResume = true
                }
                if fullSimilaritySession == nil {
                    let session = try await FullSimilaritySession.create(db: db, deck: deck, resume: shouldResume)
                    try Task.checkCancellation()
                    guard duplicateCardReview?.scanID == token else { return }
                    fullSimilaritySession = session
                    let restored = await session.restoredResult()
                    duplicateCardReview?.groups = restored.groups
                    duplicateCardReview?.error = restored.notice
                }
                guard let session = fullSimilaritySession else { return }
                while !Task.isCancelled {
                    let progress = try await session.nextBatch()
                    // 一批成功提交的结果即使恰逢暂停也保留，避免游标前移却漏掉建议。
                    guard duplicateCardReview?.scanID == token else { return }
                    duplicateCardReview?.groups += progress.groups
                    try await session.saveCheckpoint(groups: duplicateCardReview?.groups ?? [])
                    guard fullSimilarityRunID == runID else { return }
                    duplicateCardReview?.scanCompleted = progress.completed
                    duplicateCardReview?.scanTotal = progress.total
                    duplicateCardReview?.scanNote = "剩余 \(max(0,progress.total-progress.completed)) 张待检查；已检查 \(progress.completed) / \(progress.total) 张起始卡，完成 \(progress.compared) 对比较。包含长卡片；相似不代表重复。进度自动保存，关闭窗口或重启后可继续；恢复时自动检查资料变化。"
                    let inventoryChanged = progress.finished ? !(try await session.inventoryUnchanged()) : false
                    if revision != startingRevision || inventoryChanged {
                        duplicateCardReview?.scanning = false
                        duplicateCardReview?.paused = true
                        duplicateCardReview?.resumeSaved = true
                        duplicateCardReview?.error = "扫描期间资料有变化。点击继续将核对并安全重扫，避免漏项。"
                        fullSimilaritySession = nil
                        return
                    }
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
