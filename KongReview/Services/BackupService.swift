import Foundation
import KongReviewCore

/// 每日自动备份：每天第一次启动时把数据库快照成 review-YYYY-MM-DD.sqlite，保留最近 30 份。
enum BackupService {
    static let keepCount = 30

    enum Location: String, CaseIterable {
        /// ~/Library/Application Support/KongReview/Backups
        case local
        /// iCloud 云盘/KongReview备份（需在系统设置里开启 iCloud 云盘）
        case icloud

        var label: String {
            switch self {
            case .local: return "本机（应用支持文件夹）"
            case .icloud: return "iCloud 云盘"
            }
        }
    }

    static let locationKey = "backup.location"
    static let lastBackupKey = "backup.lastDate"

    static var location: Location {
        get { Location(rawValue: UserDefaults.standard.string(forKey: locationKey) ?? "") ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: locationKey) }
    }

    static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var isICloudAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDriveRoot.path)
    }

    /// 当前备份文件夹（iCloud 不可用时退回本机）
    static func directory(for location: Location = location) throws -> URL {
        let fm = FileManager.default
        let dir: URL
        if location == .icloud, isICloudAvailable {
            dir = iCloudDriveRoot.appendingPathComponent("KongReview备份", isDirectory: true)
        } else {
            dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("KongReview/Backups", isDirectory: true)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 今天还没备份就备份一次；返回新备份的路径（已备份过则返回 nil）
    @discardableResult
    static func backupIfNeeded(db: AppDatabase, now: Date = Date(), directory: URL? = nil) throws -> URL? {
        let dir = try directory ?? self.directory()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard BackupPolicy.needsBackup(existing: existing, now: now) else { return nil }
        return try backupNow(db: db, now: now, directory: dir)
    }

    /// 立即备份（同一天重复执行会覆盖当天那一份）
    @discardableResult
    static func backupNow(db: AppDatabase, now: Date = Date(), directory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = try directory ?? self.directory()
        let target = dir.appendingPathComponent(BackupPolicy.fileName(for: now))
        // VACUUM INTO 要求目标文件不存在：先写到临时名，成功后再替换
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).sqlite")
        try db.backup(to: temp)
        if fm.fileExists(atPath: target.path) {
            // 只会是当天较早的那份备份，用新快照取代
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: temp, to: target)
        UserDefaults.standard.set(now, forKey: lastBackupKey)
        try prune(directory: dir)
        return target
    }

    /// 只清理本应用生成的、超出保留份数的旧备份
    static func prune(directory dir: URL) throws {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in BackupPolicy.filesToPrune(existing: names, keep: keepCount) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static var lastBackupDate: Date? {
        UserDefaults.standard.object(forKey: lastBackupKey) as? Date
    }
}
