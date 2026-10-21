import SwiftUI

/// 独立的学习总结内容，适配窄窗口，并明确区分当前范围与全库。
struct CardLearningCompletionView: View {
    let summary: CardLearningSummary
    let globalStudiedCards: Int
    let globalRatingCount: Int
    let onReturn: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if summary.availability.kind == .complete {
                SealStamp(text: "当前已毕", size: 20)
            } else {
                Image(systemName: summary.availability.kind == .ready ? "play.circle" : "clock")
                    .font(.system(size: 30))
                    .foregroundStyle(ReviewPalette.accent)
            }
            Text(summary.availability.title)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(ReviewPalette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            Text(summary.scopeLabel)
                .font(.system(size: 13))
                .foregroundStyle(ReviewPalette.sub)
                .padding(.top, 6)
                .padding(.bottom, 24)
            HStack(spacing: 0) {
                summaryStat("\(summary.studiedCards)", unit: "张", label: "本范围今日已学", done: true)
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                summaryStat("\(summary.ratingCount)", unit: "次", label: "本范围今日评分")
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                summaryStat("\(summary.dueTomorrow)", unit: "张", label: "本范围明天到期", accent: true)
            }
            .frame(height: 100)
            .overlay(alignment: .top) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
            if let accuracy = summary.accuracy {
                Text("本范围今日评分中，非‘重来’占 \(Int((accuracy * 100).rounded()))%")
                    .font(.system(size: 12))
                    .foregroundStyle(ReviewPalette.sub)
                    .padding(.top, 14)
            }
            Text("全库今日已学 \(globalStudiedCards) 张 · 评分 \(globalRatingCount) 次")
                .font(.system(size: 12))
                .foregroundStyle(ReviewPalette.sub)
                .padding(.top, 8)
            if !summary.availability.detail.isEmpty {
                Text(summary.availability.detail)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .foregroundStyle(ReviewPalette.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
            // 3.13：被每日上限挡住时，可仅今天多放出几张（次日自动恢复）
            if summary.availability.blockedNew > 0 || summary.availability.blockedReview > 0 {
                TodayExtraButtons(blockedNew: summary.availability.blockedNew,
                                  blockedReview: summary.availability.blockedReview)
                    .padding(.top, 16)
            }
            HStack(spacing: 8) {
                PillButton(icon: "chevron.left", title: "返回牌组", style: .primary, action: onReturn)
                PillButton(icon: "arrow.clockwise", title: summary.availability.kind == .ready ? "继续学习" : "再查一次", action: onResume)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: 600)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ReviewPalette.hair))
        .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.08), radius: 20, y: 10)
    }

    private func summaryStat(_ number: String, unit: String, label: String, accent: Bool = false, done: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number)
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(done && number != "0" ? ReviewPalette.done : (accent ? ReviewPalette.accent : ReviewPalette.ink))
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
