import Foundation
import KongReviewCore

struct CardDuplicateReview: Identifiable {
    let id = UUID()
    var scanID = UUID()
    var scanning = true
    var processing = false
    var paused = false
    var groups: [CardDuplicateGroup] = []
    var position = 0
    var keeper: [String: Int64] = [:]
    var confirmingGroupID: String?
    var error: String?
    var removed = 0
    var backupDone = false
    var mode: CardDuplicateScanMode = .exact
    var scanNote: String?
    var scopeDeck: String?

    var currentGroup: CardDuplicateGroup? {
        groups.indices.contains(position) ? groups[position] : nil
    }
}

extension LibraryStore {
    func findDuplicateCards(mode: CardDuplicateScanMode? = nil, scopeDeck: String? = nil) {
        guard duplicateCardReview?.processing != true else { return }
        var state = duplicateCardReview ?? CardDuplicateReview()
        if let mode { state.mode = mode }
        if let scopeDeck { state.scopeDeck = scopeDeck.isEmpty ? nil : scopeDeck }
        state.scanID = UUID()
        state.scanning = true
        state.paused = false
        fullSimilarityTask?.cancel()
        fullSimilaritySession = nil
        state.backupDone = false
        state.groups = []
        state.position = 0
        state.keeper = [:]
        state.confirmingGroupID = nil
        state.error = nil
        state.scanNote = nil
        duplicateCardReview = state
        if state.mode == .similar { continueFullSimilarity(); return }
        let token = state.scanID
        let db = self.db
        let deck = state.scopeDeck
        Task.detached(priority: .userInitiated) {
            do {
                let groups = try await db.cardDuplicateGroups(deck: deck)
                await MainActor.run {
                    guard self.duplicateCardReview?.scanID == token else { return }
                    self.duplicateCardReview?.groups = groups
                    self.duplicateCardReview?.scanNote = nil
                    self.duplicateCardReview?.scanning = false
                }
            } catch {
                await MainActor.run {
                    guard self.duplicateCardReview?.scanID == token else { return }
                    self.duplicateCardReview?.scanning = false
                    self.duplicateCardReview?.error = error.localizedDescription
                }
            }
        }
    }

    func selectDuplicateCardKeeper(groupID: String, cardID: Int64) {
        guard let state = duplicateCardReview, !state.processing, !state.scanning,
              state.groups.first(where: { $0.id == groupID })?.ids.contains(cardID) == true else { return }
        duplicateCardReview?.keeper[groupID] = cardID
    }

    func moveDuplicateCardGroup(_ offset: Int) {
        guard let state = duplicateCardReview, !state.processing, !state.scanning else { return }
        duplicateCardReview?.position = max(0, min(state.position + offset, state.groups.count - 1))
    }

    func requestResolveDuplicateCardGroup(_ groupID: String) {
        guard let state = duplicateCardReview, !state.processing, !state.scanning,
              state.keeper[groupID] != nil else { return }
        duplicateCardReview?.confirmingGroupID = groupID
    }

    func resolveDuplicateCardGroup(_ groupID: String, backupDirectory: URL? = nil) {
        guard let state = duplicateCardReview, !state.processing, !state.scanning,
              let group = state.groups.first(where: { $0.id == groupID }),
              let keeperID = state.keeper[groupID] else { return }
        duplicateCardReview?.confirmingGroupID = nil
        duplicateCardReview?.processing = true
        duplicateCardReview?.error = nil
        let token = state.scanID
        let needsBackup = !state.backupDone
        let db = self.db
        Task.detached(priority: .userInitiated) {
            do {
                let snapshot = try CardDuplicateCleanup.resolve(db: db, group: group, keeperID: keeperID,
                    backupRequired: needsBackup) {
                        _ = try BackupService.backupNow(db: db, directory: backupDirectory)
                    }
                await MainActor.run {
                    guard var current = self.duplicateCardReview, current.scanID == token else { return }
                    current.processing = false
                    current.backupDone = true
                    current.removed += snapshot.cards.count
                    let removedIDs = Set(snapshot.cardIds)
                    current.groups.removeAll { $0.id == groupID || !$0.ids.allSatisfy({ !removedIDs.contains($0) }) }
                    current.keeper[groupID] = nil
                    current.position = max(0, min(current.position, current.groups.count - 1))
                    self.duplicateCardReview = current
                    self.recordCardCleanupUndo(snapshot)
                    self.reload()
                    // 预先加载的学习卡若刚被整理，应退出到牌组总览，避免继续回答已删除卡。
                    if snapshot.cardIds.contains(self.study.current?.id ?? -1) {
                        self.openCardsHome()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.duplicateCardReview?.scanID == token else { return }
                    self.duplicateCardReview?.processing = false
                    self.duplicateCardReview?.error = error.localizedDescription
                }
            }
        }
    }

    func closeDuplicateCardReview() {
        guard duplicateCardReview?.processing != true else { return }
        fullSimilarityTask?.cancel()
        fullSimilaritySession = nil
        duplicateCardReview = nil
    }
}
