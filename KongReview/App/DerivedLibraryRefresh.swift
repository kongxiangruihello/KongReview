import Foundation
import KongReviewCore

extension LibraryStore {
    /// 正常应用后台更新；内存测试可同步读取同一个快照构建器。
    func refreshDerivedLibrary() {
        let now = Date()
        let request = DerivedLibraryRequest(now: now,
            dailyReviewCount: max(0, UserDefaults.standard.object(forKey: SettingsKeys.dailyCount) as? Int ?? 10),
            limits: CardSettings.limits(now: now),
            scope: currentCardLearningScope, session: ReviewSessionRecordStore.load())
        let key = "\(revision)|\(request.scope)|\(request.dailyReviewCount)|\(request.limits.hashValue)|\(request.session?.day ?? "")|\(request.session?.position ?? -1)|\(request.session?.regularIds ?? [])|\(request.session?.masteryIds ?? [])|\(Int(request.now.timeIntervalSince1970 / 60))"
        if usesBackgroundStatistics, derivedIsLoading, derivedPendingKey == key { return }
        derivedRefreshGeneration += 1
        let generation = derivedRefreshGeneration
        derivedRefreshTask?.cancel()
        derivedPendingKey = key
        if !usesBackgroundStatistics {
            do { applyDerivedLibrary(try db.derivedLibrarySnapshot(request), request: request) }
            catch { derivedStatisticsFailed(error) }
            return
        }
        derivedIsLoading = true
        let db = self.db
        let loader = derivedSnapshotLoader
        derivedRefreshTask = Task<Void, Never> { @MainActor [weak self] in
            do {
                let snapshot: DerivedLibrarySnapshot
                if let loader { snapshot = try await loader(request) }
                else {
                    let worker = Task<DerivedLibrarySnapshot, Error>.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try db.derivedLibrarySnapshot(request)
                    }
                    snapshot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                }
                guard let self, !Task.isCancelled, generation == self.derivedRefreshGeneration else { return }
                guard request.scope == self.currentCardLearningScope else { self.refreshDerived(); return }
                self.applyDerivedLibrary(snapshot, request: request)
                self.onReload?()
            } catch {
                guard let self, !Task.isCancelled, generation == self.derivedRefreshGeneration else { return }
                self.derivedStatisticsFailed(error)
            }
        }
    }

    func invalidateDerivedStatistics() {
        derivedRefreshGeneration += 1
        derivedRefreshTask?.cancel()
        derivedRefreshTask = nil
        derivedPendingKey = nil
        derivedIsLoading = false
    }

    private func applyDerivedLibrary(_ snapshot: DerivedLibrarySnapshot, request: DerivedLibraryRequest) {
        staleSummary = snapshot.stale
        stats = snapshot.activity.eventSummary
        learningActivitySummary = snapshot.activity
        deckSummaryCache = snapshot.decks
        dailyLimitLedgerCache = snapshot.ledger
        globalCardLearningSummary = snapshot.globalCards
        homeLearningSummary = snapshot.home
        cardLearningSummary = snapshot.scopedCards
        cardLearningSummaryScope = request.scope
        if study.notebookId != nil { study.notebookCounts = snapshot.scopedCards.pending }
        derivedIsLoading = false
        derivedStatisticsError = nil
        derivedPendingKey = nil
    }

    private func derivedStatisticsFailed(_ error: Error) {
        derivedIsLoading = false
        derivedPendingKey = nil
        derivedStatisticsError = "暂时无法读取学习统计，请稍后再试。"
        AppLog.write("后台统计更新失败：\(error.localizedDescription)")
    }
}
