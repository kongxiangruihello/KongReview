import Foundation

/// 备份文件命名与保留策略（纯逻辑，便于测试）。
/// 文件名形如 review-2026-10-06.sqlite，每天最多一份。
public enum BackupPolicy {
    public static let prefix = "review-"
    public static let suffix = ".sqlite"

    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y: Int = c.year ?? 0
        let m: Int = c.month ?? 0
        let d: Int = c.day ?? 0
        return prefix + String(format: "%04d-%02d-%02d", y, m, d) + suffix
    }

    public static func isBackupFile(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count == prefix.count + 10 + suffix.count
    }

    /// 今天是否还需要备份
    public static func needsBackup(existing: [String], now: Date, calendar: Calendar = .current) -> Bool {
        !existing.contains(fileName(for: now, calendar: calendar))
    }

    /// 超出保留份数、应清除的旧备份（按文件名中的日期，从旧到新）
    public static func filesToPrune(existing: [String], keep: Int) -> [String] {
        let backups = existing.filter(isBackupFile).sorted()
        guard backups.count > keep else { return [] }
        return Array(backups.prefix(backups.count - keep))
    }
}

/// “最近删除”的保留期
public enum TrashPolicy {
    public static let retentionDays: Double = 30

    public static func isExpired(deletedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) >= retentionDays * 86_400
    }

    public static func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-retentionDays * 86_400)
    }
}
