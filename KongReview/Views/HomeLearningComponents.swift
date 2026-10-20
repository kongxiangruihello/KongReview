import SwiftUI
import KongReviewCore

struct HomeLearningHeader: View {
    let summary: HomeLearningSummary
    let day: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HomeLearningDate.longDate(day))
                .font(.system(size: 12.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(ReviewPalette.sub)
            Text("今日学习")
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(ReviewPalette.ink)
            if summary.isComplete {
                Label("今日学习已完成", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(ReviewPalette.easy)
            } else {
                Text(summary.isEmpty ? "从一条摘录、一张记忆卡开始积累。" : "重读摘录，巩固记忆，让每天的积累留得更久。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(ReviewPalette.sub)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 无环境依赖的首页主体，宽窗口并列两项任务，窄窗口依次排列。
struct HomeLearningDashboard: View {
    let summary: HomeLearningSummary
    var quote: (text: String, source: String)? = nil
    let onReview: () -> Void
    let onCards: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    reviewCard.frame(minWidth: 300)
                    cardsCard.frame(minWidth: 300)
                }
                VStack(spacing: 20) {
                    reviewCard
                    cardsCard
                }
            }
            HomeLearningHistory(summary: summary)
            if let quote {
                HomeLearningQuote(text: quote.text, source: quote.source)
            }
        }
    }

    private var reviewCard: some View {
        HomeLearningTaskCard {
            HomeLearningTaskHeader(icon: "sun.max", title: "今日回顾",
                                   status: reviewStatus, completed: summary.reviewIsComplete,
                                   pending: summary.reviewPendingCount > 0)
            HomeLearningMetrics(completed: summary.reviewCompletedCount, completedLabel: "已回顾",
                                pending: summary.reviewPendingCount, pendingLabel: "待回顾", unit: "条")
            reviewProgress
            HomeLearningButton(title: reviewButtonTitle, pending: summary.reviewPendingCount > 0,
                               action: onReview)
                .help(summary.reviewIsComplete ? "查看今天的回顾统计" : "进入今日回顾，继续当前这一组摘录")
        }
    }

    private var cardsCard: some View {
        HomeLearningTaskCard {
            HomeLearningTaskHeader(icon: "brain", title: "记忆卡",
                                   status: cardsStatus, completed: summary.cardsIsComplete,
                                   pending: summary.cardsDueCount > 0)
            HomeLearningMetrics(completed: summary.cardsStudiedCount, completedLabel: "今日已学",
                                pending: summary.cardsDueCount, pendingLabel: "当前待学", unit: "张")
            cardsBreakdown
            HomeLearningButton(title: "去学习记忆卡", pending: summary.cardsDueCount > 0,
                               action: onCards)
                .help("打开记忆卡首页，选择牌组后开始学习")
        }
    }

    private var reviewProgress: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(reviewProgressTitle)
                Spacer(minLength: 4)
                if summary.reviewTotalCount > 0 {
                    Text("\(summary.reviewCompletedCount) / \(summary.reviewTotalCount)")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(ReviewPalette.sub)
            DonePendingBar(done: summary.reviewCompletedCount, pending: summary.reviewPendingCount)
            Text(summary.reviewHasSession ? "按当前这一组摘录计算" : "每天读一点，回顾曾经的思考")
                .font(.system(size: 11))
                .foregroundStyle(ReviewPalette.sub)
        }
        .frame(minHeight: 58, alignment: .top)
        .help("回顾进度按当前这一组计算。再抽一组会开始新的进度；下方学习足迹按当天去重后的记录统计。")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前回顾进度：已回顾 \(summary.reviewCompletedCount) 条，共 \(summary.reviewTotalCount) 条")
    }

    private var cardsBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            DonePendingBar(done: summary.cardsStudiedCount, pending: summary.cardsDueCount)
                .help("松绿为今日已学，朱红为当前待学")
            HStack(spacing: 6) {
                HomeLearningDueCount(title: "新卡", count: summary.cardsNewDueCount, color: ReviewPalette.accent)
                HomeLearningDueCount(title: "学习中", count: summary.cardsLearningDueCount, color: ReviewPalette.hard)
                HomeLearningDueCount(title: "复习", count: summary.cardsReviewDueCount, color: ReviewPalette.easy)
            }
            Text("评分 \(summary.cardsRatingCount) 次 · 已学按卡片去重")
                .font(.system(size: 11))
                .foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
            if summary.cardsDueCount == 0, let detail = summary.cardAvailability?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ReviewPalette.sub)
                    .lineLimit(2)
                    .help(detail)
            }
        }
        .frame(minHeight: 58, alignment: .top)
        .help("今日已学按不同卡片计数；同一张卡反复评分只算一张。当前待学按到期时间更新，可能包含今天已经学过的卡。")
    }

    private var reviewProgressTitle: String {
        if summary.reviewTotalCount > 0 { return "今日回顾进度" }
        return summary.reviewCandidateCount > 0 ? "今日暂无回顾任务" : "添加摘录后开始回顾"
    }

    private var reviewStatus: String {
        if summary.reviewIsComplete { return "已完成" }
        if summary.reviewPendingCount > 0 { return "待回顾" }
        return summary.reviewCandidateCount > 0 ? "尚未开始" : "暂无摘录"
    }

    private var cardsStatus: String {
        if let availability = summary.cardAvailability {
            switch availability.kind {
            case .waitingLearning: return "稍后可学"
            case .dailyLimit: return "已达上限"
            case .allSuspended: return "全部暂停"
            case .scheduled: return "暂无到期"
            default: break
            }
        }
        if summary.cardsIsComplete { return "当前待学已完成" }
        return summary.activeCardCount > 0 ? "待学习" : "尚无卡片"
    }

    private var reviewButtonTitle: String {
        if summary.reviewIsComplete { return "查看今日回顾统计" }
        if summary.reviewHasSession, summary.reviewCompletedCount > 0 { return "继续今日回顾" }
        return summary.reviewPendingCount > 0 ? "开始今日回顾" : "去今日回顾"
    }
}

private struct HomeLearningTaskCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ReviewPalette.hair))
            .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.06), radius: 16, y: 6)
    }
}

private struct HomeLearningTaskHeader: View {
    let icon: String
    let title: String
    let status: String
    let completed: Bool
    var pending = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ReviewPalette.accent)
                .frame(width: 38, height: 38)
                .background(ReviewPalette.accentSoft, in: RoundedRectangle(cornerRadius: 11))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ReviewPalette.ink)
            Spacer(minLength: 6)
            // 3.15：待回顾、待学习用实心朱红标记，白字
            Text(status)
                .font(.system(size: 10.5, weight: pending && !completed ? .semibold : .medium))
                .foregroundStyle(completed ? ReviewPalette.done : (pending ? Color.white : ReviewPalette.sub))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(completed ? ReviewPalette.doneSoft : (pending ? ReviewPalette.pending : ReviewPalette.soft), in: Capsule())
                .fixedSize()
        }
    }
}

private struct HomeLearningMetrics: View {
    let completed: Int
    let completedLabel: String
    let pending: Int
    let pendingLabel: String
    let unit: String

    var body: some View {
        HStack(spacing: 20) {
            metric(completed, label: completedLabel, state: .done)
            Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 50)
            metric(pending, label: pendingLabel, state: .pending)
        }
        .padding(.vertical, 4)
    }

    /// 3.14：“已”用松绿、“待”用朱红；数量为 0 时数字转为灰色，标签圆点保留颜色
    private func metric(_ count: Int, label: String, state: ProgressStateLabel.Kind) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressStateLabel(state: state, text: label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(count)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(count == 0 ? ReviewPalette.sub.opacity(0.7)
                                     : (state == .done ? ReviewPalette.done : ReviewPalette.pending))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(unit).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(count) \(unit)")
    }
}

private struct HomeLearningDueCount: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(title).foregroundStyle(ReviewPalette.sub)
            Text("\(count)").monospacedDigit().foregroundStyle(count > 0 ? ReviewPalette.pending : ReviewPalette.sub)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct HomeLearningButton: View {
    let title: String
    let pending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(pending ? Color.white : ReviewPalette.ink)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(pending ? ReviewPalette.accent : ReviewPalette.soft,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(pending ? Color.clear : ReviewPalette.hair))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

private struct HomeLearningHistory: View {
    let summary: HomeLearningSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text("学习足迹")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ReviewPalette.ink)
                Spacer()
                Text("近 7 天").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 30) {
                    streaks.frame(width: 210)
                    Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 70)
                    chart.frame(minWidth: 270)
                }
                VStack(alignment: .leading, spacing: 20) {
                    streaks
                    Rectangle().fill(ReviewPalette.hair).frame(height: 1)
                    chart
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ReviewPalette.hair))
    }

    private var streaks: some View {
        HStack(spacing: 24) {
            streak(summary.learningStreak, label: "连续学习")
            streak(summary.longestLearningStreak, label: "最长连续")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func streak(_ count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(count)").font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ReviewPalette.ink)
                Text("天").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
        }
    }

    private var chart: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(summary.recentDays.enumerated()), id: \.element.key) { index, day in
                    dayBar(day, isToday: index == summary.recentDays.count - 1)
                }
            }
            HStack(spacing: 16) {
                legend("回顾摘录", color: ReviewPalette.accent)
                legend("已学卡片", color: ReviewPalette.easy)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func dayBar(_ day: HomeLearningSummary.Day, isToday: Bool) -> some View {
        let peak = max(1, summary.recentDays.map(\.total).max() ?? 1)
        let scale = 54 / CGFloat(peak)
        return VStack(spacing: 7) {
            VStack(spacing: 0) {
                if day.cards > 0 {
                    Rectangle().fill(ReviewPalette.easy.opacity(isToday ? 1 : 0.6))
                        .frame(height: CGFloat(day.cards) * scale)
                }
                if day.highlights > 0 {
                    Rectangle().fill(ReviewPalette.accent.opacity(isToday ? 1 : 0.6))
                        .frame(height: CGFloat(day.highlights) * scale)
                }
                if day.total == 0 {
                    Rectangle().fill(ReviewPalette.hair).frame(height: 3)
                }
            }
            .frame(width: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(height: 54, alignment: .bottom)
            Text(isToday ? "今天" : HomeLearningDate.weekday(day.date))
                .font(.system(size: 10.5, weight: isToday ? .medium : .regular))
                .foregroundStyle(isToday ? ReviewPalette.ink : ReviewPalette.sub)
        }
        .frame(maxWidth: .infinity)
        .help("\(day.key)：回顾 \(day.highlights) 条摘录，已学 \(day.cards) 张卡片，评分 \(day.cardRatings) 次")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.key)，回顾 \(day.highlights) 条摘录，已学 \(day.cards) 张卡片，评分 \(day.cardRatings) 次")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10.5)).foregroundStyle(ReviewPalette.sub)
        }
    }
}

private struct HomeLearningQuote: View {
    let text: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今日一句", systemImage: "quote.opening")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ReviewPalette.sub)
            Text(text)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(ReviewPalette.ink.opacity(0.85))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if !source.isEmpty {
                Text(source).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HomeLearningDate {
    static func longDate(_ key: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar.current
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter.string(from: parser.date(from: key) ?? Date())
    }

    static func weekday(_ date: Date) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1]
    }
}

/// 3.15：今日功课——先回顾、再记忆卡，一个入口、一个合计时长；有本期焦点时一并标出
struct TodayWorkBar: View {
    let summary: HomeLearningSummary
    let focus: LearningFocus?
    let onStart: () -> Void
    let onFocus: () -> Void

    private var cards: StudyQueue.Counts {
        StudyQueue.Counts(new: summary.cardsNewDueCount, learning: summary.cardsLearningDueCount, review: summary.cardsReviewDueCount)
    }

    var body: some View {
        let reviewLeft = summary.reviewPendingCount
        let cardsLeft = cards.total
        let minutes = LibraryStore.todayWorkMinutes(reviewPending: reviewLeft, cards: cards)
        let allDone = reviewLeft == 0 && cardsLeft == 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日功课").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if !allDone { Text("约 \(minutes) 分钟").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).monospacedDigit() }
                Spacer(minLength: 8)
                if let focus {
                    Button(action: onFocus) {
                        Label("本期焦点：\(focus.label)", systemImage: "scope").lineLimit(1)
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                    .help("在个人成长的学习小结第四节更换或取消焦点").handCursor()
                } else {
                    Button("设定本期焦点…", action: onFocus).buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).handCursor()
                        .help("在个人成长的学习小结第四节选一个专题或一本书作为焦点")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { steps(reviewLeft: reviewLeft, cardsLeft: cardsLeft); Spacer(minLength: 8); startButton(allDone: allDone) }
                VStack(alignment: .leading, spacing: 12) { steps(reviewLeft: reviewLeft, cardsLeft: cardsLeft); startButton(allDone: allDone) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(allDone ? ReviewPalette.hair : ReviewPalette.pending.opacity(0.35)))
    }

    private func steps(reviewLeft: Int, cardsLeft: Int) -> some View {
        HStack(spacing: 10) {
            step(1, "回顾", reviewLeft, unit: "条", done: summary.reviewCompletedCount)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(ReviewPalette.sub)
            step(2, "记忆卡", cardsLeft, unit: "张", done: summary.cardsStudiedCount)
        }
    }

    private func step(_ n: Int, _ title: String, _ left: Int, unit: String, done: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(left > 0 ? ReviewPalette.pending : ReviewPalette.done, in: Circle())
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
            if left > 0 {
                Text("待 \(left) \(unit)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.pending)
            } else {
                Text(done > 0 ? "已完成" : "暂无").font(.system(size: 12.5)).foregroundStyle(done > 0 ? ReviewPalette.done : ReviewPalette.sub)
            }
        }
        .fixedSize()
    }

    private func startButton(allDone: Bool) -> some View {
        Button(action: onStart) {
            HStack(spacing: 6) {
                Text(allDone ? "今日功课已完成 · 查看回顾" : "开始今日功课").font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(allDone ? ReviewPalette.ink : Color.white)
            .padding(.horizontal, 14).frame(height: 34)
            .background(allDone ? ReviewPalette.soft : ReviewPalette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).handCursor().fixedSize()
        .help("先完成今日回顾，再进入记忆卡；两个以上牌组有待学卡片时混合学习")
    }
}
