import Foundation
import UserNotifications

/// 每日回顾的本地通知
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private let identifier = "kongreview.daily-review"
    private let center = UNUserNotificationCenter.current()

    func applySavedSettings() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: SettingsKeys.reminderEnabled)
        let hour = d.object(forKey: SettingsKeys.reminderHour) as? Int ?? 8
        let minute = d.object(forKey: SettingsKeys.reminderMinute) as? Int ?? 0

        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "今日回顾"
            content.body = "几条旧摘录在等你。"
            content.sound = .default

            var when = DateComponents()
            when.hour = hour
            when.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
