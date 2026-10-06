import Foundation

/// 由 KongGlean 更名为 KongReview 后的设置迁移。
/// 数据库的迁移在 AppDatabase.makeShared() 里；这里把旧版的偏好设置（每日条数、快捷键、
/// 备份位置、引文体例、上次出处等）复制到新的 bundle id 下。只做一次，旧设置不删除。
enum LegacyMigration {
    static let oldDomain = "com.kongxiangrui.KongGlean"
    static let doneKey = "migrated.fromKongGlean"

    static func migrateSettings(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            // 窗口位置等系统自动记录的键不搬
            if key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple") { continue }
            defaults.set(value, forKey: key)
        }
    }
}
