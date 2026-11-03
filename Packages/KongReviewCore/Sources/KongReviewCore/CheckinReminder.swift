import Foundation

// MARK: - 5.2.2：晚间打卡提醒
//
// 默认每晚 21:00，还没打卡就提醒一次；今天已打卡或时间已过就从明天排起。逐日排单次通知（未来 7 天），
// 每次打卡、启动、跨日、改设置时重排。

public enum CheckinReminderPlan {
    public static let prefix = "kongreview.checkin."
    public static let enabledKey = "checkin.reminder.enabled"
    public static let hourKey = "checkin.reminder.hour"
    public static let minuteKey = "checkin.reminder.minute"
    public static let defaultHour = 21

    /// 要排的提醒时刻：今天已打卡或已过时间就不排今天
    public static func fires(now: Date, hour: Int, minute: Int, checkedToday: Bool, days: Int = 7,
                             calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: now)
        return (0..<days).compactMap { i -> Date? in
            guard let day = calendar.date(byAdding: .day, value: i, to: start),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
            if i == 0 && (checkedToday || fire <= now) { return nil }
            return fire
        }
    }

    public static func identifier(for fire: Date, calendar: Calendar = .current) -> String {
        prefix + ReminderPlan.dayKey(fire, calendar: calendar)
    }
}
