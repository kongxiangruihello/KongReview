import SwiftUI
import KongReviewCore

// 6.0.5：首页改为考场门口；原首页的“今日学习”标题、摘录题与记忆卡两张卡片、近七天与今日一句拿掉，只留今日试卷这一条。

/// 3.15：今日功课——先回顾、再记忆卡，一个入口、一个合计时长；有本期焦点时一并标出
/// 5.0.0：第三步“重温”，没有到期的就不显示这一步
struct TodayWorkBar: View {
    let summary: HomeLearningSummary
    var revisit = RevisitCounts()
    /// 6.0.4：今天要标注的文章（篇）
    var annotate = DailyCheckCount()
    /// 6.0.7：设了每天考多久时，各组按分到的题数（还没答的）
    var capped: [DailyCheckGroup: DailyCheckCount]? = nil
    /// 5.0.2：今日收获（功课做完时显示）
    var gains: [String] = []
    let focus: LearningFocus?
    /// 5.2.0：今日检查的合计（已做 / 应做），点开今日检查页
    var check = DailyCheckState.empty
    /// 5.2.2：今天已打卡
    var checkedIn = false
    let onStart: () -> Void
    var onCheck: () -> Void = {}
    let onFocus: () -> Void

    private var cards: StudyQueue.Counts {
        StudyQueue.Counts(new: summary.cardsNewDueCount, learning: summary.cardsLearningDueCount, review: summary.cardsReviewDueCount)
    }

    var body: some View {
        let reviewLeft = capped?[.review]?.left ?? summary.reviewPendingCount
        let cardsLeft = capped?[.cards]?.left ?? cards.total
        let revisitLeft = capped?[.revisit]?.left ?? revisit.left
        // 6.0.4：标注一篇按约 8 分钟计
        let minutes = (capped == nil
            ? LibraryStore.todayWorkMinutes(reviewPending: reviewLeft, cards: cards, revisit: revisitLeft)
            : (reviewLeft * 30 + cardsLeft * 20 + revisitLeft * 60 + 59) / 60) + annotate.left * 8
        let allDone = reviewLeft == 0 && cardsLeft == 0 && revisitLeft == 0 && annotate.left == 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日试卷").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if !allDone { Text("约 \(minutes) 分钟").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).monospacedDigit() }
                Spacer(minLength: 8)
                Button(action: onCheck) {
                    Label(checkedIn ? "今日已打卡" : check.due > 0 ? "已答 \(check.done)/\(check.due)" : "成绩单",
                          systemImage: checkedIn ? "checkmark.seal.fill" : "checklist.checked").lineLimit(1)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(checkedIn || (check.due > 0 && check.left == 0) ? ReviewPalette.done : ReviewPalette.accent)
                .help("打开今日试卷：已答 / 应答，答完看成绩单").handCursor()
                if let focus {
                    Button(action: onFocus) {
                        Label(focus.kind == .project ? "当前\(focus.label)" : "本期焦点：\(focus.label)", systemImage: "scope").lineLimit(1)
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                    .help("打开当前项目：阶段、下一步、未解问题与材料").handCursor()
                }
            }
            if allDone && !gains.isEmpty {
                Label("今日收获：" + gains.joined(separator: "；"), systemImage: "sparkles")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.done)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { steps(reviewLeft: reviewLeft, cardsLeft: cardsLeft, revisitLeft: revisitLeft); Spacer(minLength: 8); startButton(allDone: allDone) }
                VStack(alignment: .leading, spacing: 12) { steps(reviewLeft: reviewLeft, cardsLeft: cardsLeft, revisitLeft: revisitLeft); startButton(allDone: allDone) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(allDone ? ReviewPalette.hair : ReviewPalette.pending.opacity(0.35)))
    }

    private func steps(reviewLeft: Int, cardsLeft: Int, revisitLeft: Int) -> some View {
        HStack(spacing: 10) {
            step(1, "摘录", reviewLeft, unit: "题", done: summary.reviewCompletedCount)
            step(2, "记忆卡", cardsLeft, unit: "题", done: summary.cardsStudiedCount)
            if revisitLeft > 0 || revisit.done > 0 {
                step(3, "札记·笔记·问题", revisitLeft, unit: "题", done: revisit.done)
            }
            if annotate.total > 0 {
                step(revisitLeft > 0 || revisit.done > 0 ? 4 : 3, "标注文章", annotate.left, unit: "篇", done: annotate.done)
            }
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
                Text(allDone ? "今日试卷已答完 · 看成绩单" : (summary.reviewCompletedCount + summary.cardsStudiedCount + revisit.done + annotate.done > 0 ? "接着答卷" : "开始答卷")).font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(allDone ? ReviewPalette.ink : Color.white)
            .padding(.horizontal, 14).frame(height: 34)
            .background(allDone ? ReviewPalette.soft : ReviewPalette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).handCursor().fixedSize()
        .help("五类题交错出在一张卷子上：记忆卡、摘录、札记、笔记、问题")
    }
}
