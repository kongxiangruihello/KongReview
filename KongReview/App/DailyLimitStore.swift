import Foundation
import KongReviewCore

// MARK: - 3.13：每日学习量面板与“仅今天”加量

/// 每日学习量面板的草稿：保存前只在内存里预览，不改任何设置
struct DailyLimitsDraft: Identifiable, Equatable {
    var id = UUID()
    var overview: DailyLimitOverview
    var newPerDay: Int
    var reviewsPerDay: Int
    var totalNewEnabled: Bool
    var totalNew: Int
    var totalReviewEnabled: Bool
    var totalReview: Int
    var overrides: [String: DailyLimitOverride]
    /// 今天已有的加量；面板里可以清除，不在这里新增
    var extra: DailyLimitExtra?
    /// 从某个牌组进入时，面板滚到这一行并高亮
    var focusDeck: String?

    var settings: DailyLimitSettings {
        DailyLimitSettings(newPerDay: newPerDay, reviewsPerDay: reviewsPerDay,
                           totalNewPerDay: totalNewEnabled ? totalNew : nil,
                           totalReviewsPerDay: totalReviewEnabled ? totalReview : nil,
                           extra: extra)
    }

    var ledger: DailyLimitLedger { overview.ledger(settings, overrides: overrides) }

    /// 按草稿设置，今天此刻全库还可学多少
    var preview: StudyQueue.Counts {
        let ledger = self.ledger
        var counts = StudyQueue.Counts()
        for row in overview.rows {
            let left = ledger.deckLeft(row.deck)
            counts.new += min(left.new, row.availableNew)
            counts.review += min(left.review, row.dueReview)
            counts.learning += row.learning
        }
        let total = ledger.totalLeft
        counts.new = min(counts.new, total.new)
        counts.review = min(counts.review, total.review)
        return counts
    }

    /// 每个牌组此刻实际可学（牌组余额、全库余额与现有卡片三者取小）
    func deckPreview(_ row: DailyLimitDeckRow) -> DailyAmount {
        let left = ledger.left(row.deck)
        return DailyAmount(new: min(left.new, row.availableNew), review: min(left.review, row.dueReview))
    }

    /// 各牌组自己的上限加起来（与全库合计对照）
    var sumOfDeckLimits: DailyAmount {
        let ledger = self.ledger
        return overview.rows.reduce(.zero) { $0 + ledger.deckLimit($1.deck) }
    }

    func limit(_ deck: String, _ kind: DailyLimitKind) -> Int? {
        kind == .new ? overrides[deck]?.new : overrides[deck]?.review
    }

    mutating func setLimit(_ deck: String, _ kind: DailyLimitKind, _ value: Int?) {
        var o = overrides[deck] ?? DailyLimitOverride()
        let clamped = value.map(DailyLimitSettings.clamp)
        if kind == .new { o.new = clamped } else { o.review = clamped }
        overrides[deck] = o
    }

    var hasTodayExtra: Bool { !(extra?.isEmpty ?? true) }

    /// “今天加量”的说明，如“全库新卡 +10；牌组“甲”复习 +50”
    var todayExtraDescription: String {
        guard let extra, !extra.isEmpty else { return "" }
        var parts: [String] = []
        func describe(_ a: DailyAmount) -> String {
            [a.new > 0 ? "新卡 +\(a.new)" : nil, a.review > 0 ? "复习 +\(a.review)" : nil].compactMap { $0 }.joined(separator: "、")
        }
        if !extra.total.isZero { parts.append("全库合计 " + describe(extra.total)) }
        for (key, amount) in extra.decks.sorted(by: { $0.key < $1.key }) where !amount.isZero {
            let name = DailyLimitLedger.isScopeKey(key) ? "笔记本学习" : "牌组“\(key)”"
            parts.append(name + " " + describe(amount))
        }
        return parts.joined(separator: "；")
    }
}

extension LibraryStore {
    /// 打开每日学习量面板；从牌组进入时高亮这个牌组
    func openDailyLimits(focus deck: String? = nil) {
        do {
            let overview = try db.dailyLimitOverview()
            dailyLimitsEditor = DailyLimitsDraft(
                overview: overview,
                newPerDay: CardSettings.newPerDay, reviewsPerDay: CardSettings.reviewsPerDay,
                totalNewEnabled: CardSettings.totalNewPerDay != nil, totalNew: CardSettings.lastTotal(.new),
                totalReviewEnabled: CardSettings.totalReviewsPerDay != nil, totalReview: CardSettings.lastTotal(.review),
                overrides: Dictionary(uniqueKeysWithValues: overview.rows.map { ($0.deck, $0.override) }),
                extra: CardSettings.todayExtra(), focusDeck: deck)
        } catch { report(error) }
    }

    func saveDailyLimits(_ draft: DailyLimitsDraft) {
        UserDefaults.standard.set(DailyLimitSettings.clamp(draft.newPerDay), forKey: CardSettings.newPerDayKey)
        UserDefaults.standard.set(DailyLimitSettings.clamp(draft.reviewsPerDay), forKey: CardSettings.reviewsPerDayKey)
        UserDefaults.standard.set(DailyLimitSettings.clamp(draft.totalNew), forKey: CardSettings.totalNewPerDayKey)
        UserDefaults.standard.set(DailyLimitSettings.clamp(draft.totalReview), forKey: CardSettings.totalReviewsPerDayKey)
        UserDefaults.standard.set(draft.totalNewEnabled, forKey: CardSettings.totalNewEnabledKey)
        UserDefaults.standard.set(draft.totalReviewEnabled, forKey: CardSettings.totalReviewsEnabledKey)
        // 今日加量由“清除”按钮或完成页即时写入，保存面板时不改动
        perform { try db.saveDailyLimitOverrides(draft.overrides) }
        dailyLimitsEditor = nil
        dailyLimitsChanged()
    }

    /// 上限变了：已学完的学习会话立即按新余额取卡（正在看的卡不替换），统计与菜单栏随之更新
    func dailyLimitsChanged() {
        if study.deck != nil, study.browsingDeck == nil, study.current == nil {
            nextCard()
        }
        refreshDerived()
        StatusItemController.shared.updateCounts()
    }

    /// “仅今天”在当前学习范围再多学 n 张：只在真正卡住的那一级加量，次日自动失效。返回实际放出的张数。
    @discardableResult
    func addTodayExtra(_ n: Int, kind: DailyLimitKind, now: Date = Date()) -> Int {
        guard n > 0 else { return 0 }
        do {
            let limits = CardSettings.limits(now: now)
            var ledger = try db.dailyLimitLedger(now: now, limits: limits)
            var available: [String: Int] = [:]
            func count(_ cards: [Card], key: String) {
                let c = StudyQueue.counts(cards, now: now, newLimitLeft: .max, reviewLimitLeft: .max)
                available[key, default: 0] += kind == .new ? c.new : c.review
            }
            switch currentCardLearningScope {
            case .notebook(let id):
                let ids = try db.notebookHighlights(id).compactMap(\.id)
                let cards = try db.cards(highlightIds: ids)
                let done = try db.studiedToday(cardIds: cards.compactMap(\.id), now: now)
                let key = DailyLimitLedger.notebookKey(id)
                ledger = ledger.with(scope: key, spent: DailyAmount(new: done.new, review: done.review))
                count(cards, key: key)
            case .deck(let deck):
                count(try db.cards(deck: deck), key: deck)
            case .all:
                for (deck, cards) in Dictionary(grouping: try db.cards(), by: \.deck) { count(cards, key: deck) }
            }
            let plan = ledger.extraPlan(adding: n, kind: kind, available: available)
            guard plan.added > 0 else {
                infoMessage = "当前范围没有更多\(kind == .new ? "新卡" : "到期复习卡")可以放出。"
                return 0
            }
            let current = CardSettings.todayExtra(now: now) ?? DailyLimitExtra(day: ledger.day)
            CardSettings.setTodayExtra(current.adding(plan.extra))
            dailyLimitsChanged()
            return plan.added
        } catch {
            report(error)
            return 0
        }
    }

    /// 撤掉今天的全部加量
    func clearTodayExtra() {
        CardSettings.setTodayExtra(nil)
        if dailyLimitsEditor != nil { dailyLimitsEditor?.extra = nil }
        dailyLimitsChanged()
    }

    /// 牌组改名或合并后，今天的加量跟着牌组走
    func moveTodayExtra(from old: String, to new: String) {
        guard var extra = CardSettings.todayExtra() else { return }
        extra.renameDeck(old, to: new)
        CardSettings.setTodayExtra(extra)
    }
}
