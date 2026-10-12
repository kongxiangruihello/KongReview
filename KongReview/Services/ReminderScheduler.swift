import Foundation
import UserNotifications
import KongReviewCore

/// 每日回顾的本地通知。
///
/// 0.6 及以前用一条“每天重复”的通知，到点必响，哪怕当天已经回顾过。
/// 0.7 起改为逐日排好未来 14 天的单次通知（每天一个独立标识 kongreview.review.yyyy-MM-dd）：
/// 当天一旦回顾（每日回顾里看过一条，或复习过一张记忆卡），就撤掉当天那条；
/// 每次启动、回到前台、跨日、改设置时都会重排，所以 14 天的窗口会一直往后滚。
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private let legacyIdentifier = "kongreview.daily-review"
    private let prefix = "kongreview.review."
    private let center = UNUserNotificationCenter.current()

    func applySavedSettings() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: SettingsKeys.reminderEnabled)
        let hour = d.object(forKey: SettingsKeys.reminderHour) as? Int ?? 8
        let minute = d.object(forKey: SettingsKeys.reminderMinute) as? Int ?? 0
        let store = QuickCaptureController.shared.store
        let reviewed = store?.reviewedToday ?? false
        let dailyCount = d.object(forKey: SettingsKeys.dailyCount) as? Int ?? 10
        let today = store?.todayCounts()
        let calendar = Calendar.current
        /// 提醒正文：写明当天要看的摘录条数与待学的卡数（未来几天按每日条数与卡片到期日估算）
        func message(for fire: Date) -> String {
            let highlights = calendar.isDateInToday(fire) ? (today?.highlights ?? dailyCount) : dailyCount
            var cards = 0
            if calendar.isDateInToday(fire) {
                cards = today?.cards ?? 0
            } else if let db = store?.db,
                      let n = try? db.cardsDue(on: fire, newPerDay: CardSettings.newPerDay, reviewsPerDay: CardSettings.reviewsPerDay) {
                cards = n
            }
            var parts: [String] = []
            if highlights > 0 { parts.append("\(highlights) 条摘录") }
            if cards > 0 { parts.append("\(cards) 张记忆卡") }
            return parts.isEmpty ? "几条旧摘录在等你。" : "今天有" + parts.joined(separator: "、") + "等你回顾。"
        }
        let prefix = self.prefix
        let legacy = legacyIdentifier
        let center = self.center

        Task {
            // 先撤掉旧版的重复通知与之前排好的单次通知
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) || $0 == legacy }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            // 今天已回顾：把已经送达但还挂在通知中心里的今天那条也收起来
            if reviewed {
                center.removeDeliveredNotifications(withIdentifiers: [ReminderPlan.identifier(for: Date())])
            }
            guard enabled else { return }

            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }

            for fire in ReminderPlan.days(now: Date(), hour: hour, minute: minute, reviewedToday: reviewed) {
                let content = UNMutableNotificationContent()
                content.title = "今日回顾"
                content.body = message(for: fire)
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: ReminderPlan.identifier(for: fire),
                                                    content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }
}
