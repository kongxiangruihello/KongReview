import Foundation
import KongReviewCore

/// 学习统计的范围和当前队列的范围一致，不把全库评分混入某个牌组的完成页。
enum CardLearningScope: Equatable {
    case all
    case deck(String)
    case notebook(Int64)
}

struct CardLearningSummary: Equatable {
    var scopeLabel: String
    var studiedCards: Int
    var ratingCount: Int
    var correctRatings: Int
    /// 严格限定在明天 [00:00, 后天 00:00)，不包括逾期、新卡、暂停或删除的卡。
    var dueTomorrow: Int
    var pending: StudyQueue.Counts
    var availability: CardStudyAvailability
    /// 全库/牌组总览可直接使用同次读取算出的各牌组状态。
    var deckAvailability: [String: CardStudyAvailability] = [:]

    var accuracy: Double? { ratingCount == 0 ? nil : Double(correctRatings) / Double(ratingCount) }
}

struct CardStudyAvailability: Equatable {
    enum Kind: Equatable {
        case ready, noCards, allSuspended, dailyLimit, waitingLearning, scheduled, complete
    }
    var kind: Kind
    var title: String
    var detail: String
    /// 排程允许再次开始学习的时间；学习中的卡可提前 20 分钟。
    var nextAvailableAt: Date?
    var learningDueAt: Date?
    var blockedNew = 0
    var blockedReview = 0

    struct Group {
        var cards: [Card]
        var newLimit: Int
        var reviewLimit: Int
        var newLimitLeft: Int
        var reviewLimitLeft: Int
        var studiedCards = 0
    }

    /// 只解释 StudyQueue 的结果；到期判断和计数仍由同一个学习队列负责。
    static func summarize(_ groups: [Group], now: Date, calendar: Calendar,
                          studiedCards: Int) -> (counts: StudyQueue.Counts, status: Self) {
        let all = groups.flatMap(\.cards).filter { $0.deletedAt == nil }
        let active = all.filter { !$0.isSuspended }
        var counts = StudyQueue.Counts()
        var blockedNew = 0, blockedReview = 0
        var nextDates: [Date] = []
        var zeroLimits: [String] = []
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        for group in groups {
            let due = StudyQueue.counts(group.cards, now: now, newLimitLeft: group.newLimitLeft,
                                       reviewLimitLeft: group.reviewLimitLeft)
            counts.new += due.new
            counts.learning += due.learning
            counts.review += due.review
            let unrestricted = StudyQueue.counts(group.cards, now: now, newLimitLeft: Int.max,
                                                 reviewLimitLeft: Int.max)
            let newBlocked = unrestricted.new - due.new
            let reviewBlocked = unrestricted.review - due.review
            blockedNew += newBlocked
            blockedReview += reviewBlocked
            if newBlocked > 0 {
                if group.newLimit > 0 { nextDates.append(tomorrow) }
                else { zeroLimits.append("新卡每日上限为 0") }
            }
            if reviewBlocked > 0 {
                if group.reviewLimit > 0 { nextDates.append(tomorrow) }
                else { zeroLimits.append("复习每日上限为 0") }
            }
            for card in group.cards where !card.isSuspended && card.deletedAt == nil {
                switch card.state {
                case .learning, .relearning:
                    let eligible = card.due.addingTimeInterval(-1_200)
                    if eligible > now { nextDates.append(eligible) }
                case .review:
                    if !StudyQueue.isDue(card, now: now), group.reviewLimit > 0 {
                        nextDates.append(calendar.startOfDay(for: card.due))
                    }
                case .new: break
                }
            }
        }
        let learningDue = active.filter { $0.state == .learning || $0.state == .relearning }
            .map(\.due).min()
        let next = nextDates.min()
        let waitingLearning = learningDue.map { $0.addingTimeInterval(-1_200) > now } ?? false
        let blocked = blockedNew > 0 || blockedReview > 0
        var reasons: [String] = []
        if blockedNew > 0 { reasons.append("尚有 \(blockedNew) 张新卡受每日上限限制") }
        if blockedReview > 0 { reasons.append("尚有 \(blockedReview) 张到期复习卡受每日上限限制") }
        reasons += Array(Set(zeroLimits)).sorted()
        if waitingLearning, let learningDue {
            reasons.append("学习中的卡于\(dateLabel(learningDue, now: now, calendar: calendar))到期，可提前 20 分钟学习")
        }
        if let next { reasons.append("下次可学：\(dateLabel(next, now: now, calendar: calendar))") }

        let kind: Kind
        let title: String
        if counts.total > 0 {
            kind = .ready; title = "还有 \(counts.total) 张卡片可学"
        } else if all.isEmpty {
            kind = .noCards; title = "还没有记忆卡"
            reasons = ["新建卡片，或将摘录做成记忆卡后开始学习。"]
        } else if active.isEmpty {
            kind = .allSuspended; title = "卡片均已暂停"
            reasons = ["在卡片浏览中取消暂停后即可继续学习。"]
        } else if waitingLearning,
                  !blocked || (learningDue!.addingTimeInterval(-1_200) < tomorrow) {
            kind = .waitingLearning; title = "学习中的卡片稍后可学"
        } else if blocked {
            kind = .dailyLimit; title = zeroLimits.isEmpty ? "今日学习上限已达到" : "每日上限限制了待学卡片"
        } else if studiedCards > 0 {
            kind = .complete; title = "当前待学已完成"
        } else {
            kind = .scheduled; title = "当前没有到期卡片"
        }
        if reasons.isEmpty && kind == .ready { reasons = ["新卡、学习中和复习卡按当前学习排程排列。"] }
        return (counts, Self(kind: kind, title: title, detail: reasons.joined(separator: "；"),
                             nextAvailableAt: next, learningDueAt: learningDue,
                             blockedNew: blockedNew, blockedReview: blockedReview))
    }

    private static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "今天 HH:mm" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                calendar.isDate(date, inSameDayAs: tomorrow) { formatter.dateFormat = "明天 HH:mm" }
        else { formatter.dateFormat = "M月d日 HH:mm" }
        return formatter.string(from: date)
    }
}
