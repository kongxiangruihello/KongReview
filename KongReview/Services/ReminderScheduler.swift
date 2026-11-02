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
        applyReflectionReminder()
        applyCheckinReminder()
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: SettingsKeys.reminderEnabled)
        let hour = d.object(forKey: SettingsKeys.reminderHour) as? Int ?? 8
        let minute = d.object(forKey: SettingsKeys.reminderMinute) as? Int ?? 0
        let store = QuickCaptureController.shared.store
        let reviewed = store?.reviewedToday ?? false
        let dailyCount = d.object(forKey: SettingsKeys.dailyCount) as? Int ?? 10
        let today = store?.todayCounts()
        let calendar = Calendar.current
        /// 1.9：日课卡——当天要看的摘录、记忆卡（新 / 学习中 / 复习）、约几分钟；今天、明天的还写上前一天做了多少
        /// （未来几天按每日条数与卡片到期日估算）
        func info(for fire: Date) -> (highlights: Int, cards: StudyQueue.Counts, yesterday: (highlights: Int, cards: Int)?, streak: Int) {
            let isToday = calendar.isDateInToday(fire)
            let highlights = isToday ? (today?.highlights ?? dailyCount) : dailyCount
            var cards = StudyQueue.Counts()
            if isToday {
                cards = store?.todayCardPending ?? StudyQueue.Counts()
            } else if let db = store?.db,
                      let n = try? db.cardsDue(on: fire, limits: CardSettings.limits(now: fire)) {
                cards.review = n
            }
            var yesterday: (highlights: Int, cards: Int)?
            let streak = store?.stats.currentStreak ?? 0
            if let db = store?.db {
                // 只有今天这条写“昨天”：明天的提醒是今天排的，那时今天还没做完
                if isToday, let y = calendar.date(byAdding: .day, value: -1, to: fire) {
                    yesterday = try? db.activity(on: y)
                }
            }
            return (highlights, cards, yesterday, streak)
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

            for (i, fire) in ReminderPlan.days(now: Date(), hour: hour, minute: minute, reviewedToday: reviewed).enumerated() {
                let content = UNMutableNotificationContent()
                let x = info(for: fire)
                content.title = DailyCard.title(fire)
                content.body = DailyCard.body(highlights: x.highlights, cards: x.cards, yesterday: x.yesterday, streak: x.streak)
                content.sound = .default
                // 最近两天的提醒附一张“日课卡”小图（生成失败就只有文字）
                if i < 2, let url = DailyCardImage.write(date: fire, highlights: x.highlights, cards: x.cards, streak: x.streak),
                   let att = try? UNNotificationAttachment(identifier: "dailycard", url: url, options: nil) {
                    content.attachments = [att]
                }
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: ReminderPlan.identifier(for: fire),
                                                    content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// 5.2.2：晚间打卡提醒（默认开启，21:00）：今天还没打卡才提醒；打卡后撤掉今天那条
    func applyCheckinReminder() {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: CheckinReminderPlan.enabledKey) as? Bool ?? true
        let hour = d.object(forKey: CheckinReminderPlan.hourKey) as? Int ?? CheckinReminderPlan.defaultHour
        let minute = d.object(forKey: CheckinReminderPlan.minuteKey) as? Int ?? 0
        let checked = QuickCaptureController.shared.store?.checkin.todayChecked ?? false
        let fires = enabled ? CheckinReminderPlan.fires(now: Date(), hour: hour, minute: minute, checkedToday: checked) : []
        let center = self.center
        Task {
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(CheckinReminderPlan.prefix) })
            if checked { center.removeDeliveredNotifications(withIdentifiers: [CheckinReminderPlan.identifier(for: Date())]) }
            guard enabled, !fires.isEmpty else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            for fire in fires {
                let content = UNMutableNotificationContent()
                content.title = "今天还没打卡"
                content.body = "做完今日检查中的一组，再写下日评（给今天打个分），就算打卡。"
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: CheckinReminderPlan.identifier(for: fire), content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                try? await center.add(request)
            }
        }
    }

    /// 5.0.1：每周复盘提醒（默认关闭；打开后默认星期日 20:00）。排好之后 4 次，提醒所对应的那一周已复盘就跳过。
    func applyReflectionReminder() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: ReflectionReminderPlan.enabledKey)
        let weekday = d.object(forKey: ReflectionReminderPlan.weekdayKey) as? Int ?? 1
        let hour = d.object(forKey: ReflectionReminderPlan.hourKey) as? Int ?? 20
        let minute = d.object(forKey: ReflectionReminderPlan.minuteKey) as? Int ?? 0
        let db = QuickCaptureController.shared.store?.db
        let fires = enabled ? ReflectionReminderPlan.fires(now: Date(), weekday: weekday, hour: hour, minute: minute) { window in
            db?.reflectionCompleted(window) ?? false
        } : []
        let center = self.center
        Task {
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(ReflectionReminderPlan.prefix) })
            guard enabled, !fires.isEmpty else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            for fire in fires {
                let content = UNMutableNotificationContent()
                content.title = "每周复盘"
                content.body = "约十分钟：看数字、看新材料、看自己的想法、过一遍常念问题，写下收获、困难与下一步。"
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: ReflectionReminderPlan.prefix + ReminderPlan.dayKey(fire), content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                try? await center.add(request)
            }
        }
    }
}
