import SwiftUI
import UserNotifications
import KongReviewCore

// MARK: - 1.3：每周小结

/// 今日回顾页顶部的“上周小结”卡片：本周第一次打开时出现，点“知道了”收起
struct WeeklyDigestCard: View {
    @Environment(LibraryStore.self) private var store
    let digest: WeeklyDigest

    var body: some View {
        let quote = digest.quoteID.flatMap { try? store.db.highlights(ids: [$0]).first }
        ReviewCardContainer(padding: 22) {
            HStack(alignment: .firstTextBaseline) {
                Label("上周小结", systemImage: "calendar.badge.checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ReviewPalette.ink)
                Text(digest.rangeLabel())
                    .font(.system(size: 12.5))
                    .foregroundStyle(ReviewPalette.sub)
                Spacer()
                Button("全部统计 ›") { store.selection = .stats }
                    .buttonStyle(.plain)
                    .handCursor()
                    .font(.system(size: 12.5))
                    .foregroundStyle(ReviewPalette.accent)
                CardIconButton(icon: "xmark", help: "知道了（本周不再显示）") { store.dismissWeeklyDigest() }
            }
            HStack(spacing: 0) {
                stat("\(digest.highlightsReviewed)", "条", "回顾摘录")
                divider
                stat("\(digest.cardsReviewed)", "次", digest.accuracy.map { "记忆卡 · 答对 \(Int(($0 * 100).rounded()))%" } ?? "记忆卡")
                divider
                stat("\(digest.newHighlights)", "条", "新增摘录")
                divider
                stat("\(digest.activeDays)", "/ 7 天", "有回顾")
            }
            .padding(.top, 14)
            if let q = quote {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本周金句").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                    Text(MarkdownText.attributed(q.text))
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(ReviewPalette.ink)
                        .lineLimit(5)
                    if let s = store.source(for: q) {
                        Text("——《\(s.title)》" + (s.author.isEmpty ? "" : " " + s.author))
                            .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReviewPalette.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 14)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 34)
    }

    private func stat(_ number: String, _ unit: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
                Text(unit).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 每周一 8 点以后第一次检查时推送一条“上周小结”通知（只在已允许通知时）
@MainActor
enum WeeklyDigestNotifier {
    static func checkAndPost(store: LibraryStore, now: Date = Date()) {
        guard store.weeklyDigestEnabled else { return }
        let cal = WeeklyDigest.mondayCalendar()
        guard let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start,
              now >= monday.addingTimeInterval(8 * 3600) else { return }
        let week = WeeklyDigest.previousWeek(of: now)
        let key = WeeklyDigest.dayKey(week.start)
        guard UserDefaults.standard.string(forKey: LibraryStore.digestNotifiedKey) != key else { return }
        guard let d = try? store.db.weeklyDigest(now: now), !d.isEmpty else {
            UserDefaults.standard.set(key, forKey: LibraryStore.digestNotifiedKey)
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "上周小结（\(d.rangeLabel())）"
            content.body = d.notificationBody + " 打开今日回顾看本周金句。"
            let req = UNNotificationRequest(identifier: "weekly-digest-\(key)", content: content, trigger: nil)
            try? await center.add(req)
            UserDefaults.standard.set(key, forKey: LibraryStore.digestNotifiedKey)
        }
    }
}
