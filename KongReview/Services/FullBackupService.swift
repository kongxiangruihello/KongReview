import Foundation
import Observation
import CryptoKit
import CoreFoundation
import Darwin
import GRDB
import KongReviewCore

/// 一个可拷贝到新电脑的文件。媒体、音频、封面及网页缓存都由 SQLite 管理，
/// 不复制用户的外部目录、收件箱、日志或旧备份。容器不使用压缩及外部解压程序。
enum FullBackupService {
    static let fileExtension = "kongreviewbackup"
    static let magic = Data("KONGREVIEW-BACKUP\n".utf8)
    static let maximumManifestBytes: UInt64 = 1_048_576
    static let maximumArchiveBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
    static let maximumDraftBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumSettingsBytes: UInt64 = 1_048_576
    private static let chunkSize = 1_048_576
    private static let databaseName = "library.sqlite"
    private static let draftName = "editor-drafts.json"
    private static let settingsName = "settings.plist"

    struct Manifest: Codable {
        var formatVersion = 1
        var application = "KongReview"
        var appVersion: String
        var createdAt: Date
        var entries: [Entry]
    }

    struct Entry: Codable {
        var name: String
        var bytes: UInt64
        var sha256: String
    }

    struct Counts: Equatable {
        var highlights: Int
        var cards: Int
        var sources: Int
        var articles: Int
        var reviewEvents: Int
        var media: Int
        var highlightDrafts: Int
        var cardDrafts: Int
        var settings: Int
    }

    enum RestorePhase: Equatable { case database, drafts, settings }

    enum BackupError: LocalizedError {
        case invalid(String)
        case unsupported
        case tooLarge
        case rollbackFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "完整备份校验失败：\(reason)。当前资料未被替换。"
            case .unsupported: return "这份完整备份来自不支持的版本，请先升级 KongReview。"
            case .tooLarge: return "备份超过安全读取上限（32 GB），无法导入。"
            case .rollbackFailed(let url, let reason):
                return "恢复失败，自动回滚也未能完成：\(reason)。恢复前的完整备份已保存在 \(url.path)，请保留该文件并重新打开应用后恢复。"
            }
        }
    }

    /// 创建完成后才原子替换目标；中途失败不会留下看似完整的文件。
    @discardableResult
    static func create(db: AppDatabase, draftURL: URL?, defaults: UserDefaults,
                       destination: URL, now: Date = Date(), appVersion: String? = nil) throws -> URL {
        let fm = FileManager.default
        let work = try makeWorkspace()
        defer { try? fm.removeItem(at: work) }
        let database = work.appendingPathComponent(databaseName)
        try db.backup(to: database)
        var files = [(databaseName, database)]
        if let draftURL, fm.fileExists(atPath: draftURL.path) {
            let size = try regularFileSize(draftURL)
            guard size <= maximumDraftBytes else { throw BackupError.tooLarge }
            _ = try EditorDraftPersistence.validateBackupFile(at: draftURL)
            let copy = work.appendingPathComponent(draftName)
            try fm.copyItem(at: draftURL, to: copy)
            files.append((draftName, copy))
        }
        let preferences = try settingsSnapshot(defaults)
        let settings = work.appendingPathComponent(settingsName)
        let settingsData = try PropertyListSerialization.data(fromPropertyList: preferences,
                                                               format: .binary, options: 0)
        guard settingsData.count <= maximumSettingsBytes else { throw BackupError.tooLarge }
        try settingsData.write(to: settings, options: .atomic)
        files.append((settingsName, settings))
        let entries = try files.map { name, file in
            Entry(name: name, bytes: try regularFileSize(file), sha256: try hash(file))
        }
        let manifest = Manifest(appVersion: appVersion ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.8.0",
                                createdAt: now, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes else { throw BackupError.tooLarge }
        let size = UInt64(magic.count + 8 + data.count) + entries.reduce(0) { $0 + $1.bytes }
        guard size <= maximumArchiveBytes else { throw BackupError.tooLarge }
        if fm.fileExists(atPath: destination.path) { _ = try regularFileSize(destination) }
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".kongreview-backup-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: partial) }
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: partial)
        do {
            try output.write(contentsOf: magic)
            var length = UInt64(data.count).bigEndian
            try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
            try output.write(contentsOf: data)
            for (_, file) in files { try copy(file, to: output) }
            try output.synchronize()
            try output.close()
        } catch { try? output.close(); throw error }
        // rename 在同一目录原子替换，目标是用户在保存面板选择的普通文件。
        guard Darwin.rename(partial.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return destination
    }

    /// 先把所有内容写入独立临时目录，再校验校验和、草稿、设置、SQLite 结构及完整性。
    /// 预览只包含重新计算的统计，绝不相信容器里声称的条数，也不触碰活动数据库。
    static func prepare(url: URL) throws -> PreparedFullBackup {
        let fm = FileManager.default
        let size = try regularFileSize(url)
        guard size <= maximumArchiveBytes else { throw BackupError.tooLarge }
        let work = try makeWorkspace()
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            guard try readExactly(input, count: magic.count) == magic else { throw BackupError.invalid("文件格式不正确") }
            let rawLength = try readExactly(input, count: 8)
            let length = rawLength.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length > 0, length <= maximumManifestBytes else { throw BackupError.invalid("清单长度不正确") }
            let manifestData = try readExactly(input, count: Int(length))
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) }
            catch { throw BackupError.invalid("清单损坏") }
            guard manifest.formatVersion == 1, manifest.application == "KongReview" else { throw BackupError.unsupported }
            guard manifest.createdAt.timeIntervalSince1970.isFinite, manifest.appVersion.count <= 100 else {
                throw BackupError.invalid("版本或日期不正确")
            }
            let names = manifest.entries.map(\.name)
            let allowed: Set<String> = [databaseName, draftName, settingsName]
            guard (2...3).contains(names.count), Set(names).count == names.count,
                  Set(names).isSubset(of: allowed), names.contains(databaseName), names.contains(settingsName) else {
                throw BackupError.invalid("含有重复、越界或未知文件名")
            }
            var expected = UInt64(magic.count + 8) + length
            for entry in manifest.entries {
                guard entry.bytes > 0, entry.bytes <= maximumArchiveBytes,
                      entry.sha256.count == 64,
                      entry.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw BackupError.invalid("文件清单不正确")
                }
                if entry.name == draftName, entry.bytes > maximumDraftBytes { throw BackupError.tooLarge }
                if entry.name == settingsName, entry.bytes > maximumSettingsBytes { throw BackupError.tooLarge }
                let (sum, overflow) = expected.addingReportingOverflow(entry.bytes)
                guard !overflow, sum <= maximumArchiveBytes else { throw BackupError.tooLarge }
                expected = sum
            }
            guard expected == size else { throw BackupError.invalid("文件缺失或含有额外数据") }
            for entry in manifest.entries {
                let file = work.appendingPathComponent(entry.name)
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let output = try FileHandle(forWritingTo: file)
                var hasher = SHA256()
                do {
                    var remaining = entry.bytes
                    while remaining > 0 {
                        let block = try readExactly(input, count: Int(min(UInt64(chunkSize), remaining)))
                        hasher.update(data: block)
                        try output.write(contentsOf: block)
                        remaining -= UInt64(block.count)
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                guard digest(hasher.finalize()) == entry.sha256 else { throw BackupError.invalid("\(entry.name) 校验和不符") }
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalid("含有额外数据") }
            let preferences = try readSettings(work.appendingPathComponent(settingsName))
            let drafts = work.appendingPathComponent(draftName)
            let draftCounts = names.contains(draftName) ? try EditorDraftPersistence.validateBackupFile(at: drafts) : (0, 0)
            let counts = try databaseCountsAndValidate(work.appendingPathComponent(databaseName),
                drafts: draftCounts, settings: preferences.count)
            return PreparedFullBackup(source: url, directory: work, manifest: manifest, counts: counts, bytes: size)
        } catch { try? fm.removeItem(at: work); throw error }
    }

    /// 恢复前生成完整安全备份；任何一个阶段失败，都回滚数据库、草稿和白名单设置。
    /// phaseObserver 仅供故障注入测试使用，不在产品中传入。
    @discardableResult
    static func restore(_ prepared: PreparedFullBackup, db: AppDatabase, draftURL: URL?,
                        defaults: UserDefaults, safetyDirectory: URL,
                        phaseObserver: ((RestorePhase) throws -> Void)? = nil) throws -> URL {
        // 临时内容可能被用户清理或篡改，确认时再次校验全部文件，防止预览后的内容被替换。
        try prepared.validateStagedFiles()
        guard draftURL != nil || !prepared.manifest.entries.contains(where: { $0.name == draftName }) else {
            throw BackupError.invalid("当前草稿目录不可用")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: safetyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safety = safetyDirectory.appendingPathComponent("恢复前-\(UUID().uuidString).\(fileExtension)")
        try create(db: db, draftURL: draftURL, defaults: defaults, destination: safety)
        let previous = try prepare(url: safety)
        defer { previous.cleanup() }
        do {
            try apply(prepared, db: db, draftURL: draftURL, defaults: defaults, phaseObserver: phaseObserver)
        } catch {
            do { try apply(previous, db: db, draftURL: draftURL, defaults: defaults, phaseObserver: nil) }
            catch { throw BackupError.rollbackFailed(safety, error.localizedDescription) }
            throw error
        }
        return safety
    }

    private static func apply(_ value: PreparedFullBackup, db: AppDatabase, draftURL: URL?,
                              defaults: UserDefaults, phaseObserver: ((RestorePhase) throws -> Void)?) throws {
        try db.restore(from: value.directory.appendingPathComponent(databaseName))
        try phaseObserver?(.database)
        if let draftURL {
            let source = value.directory.appendingPathComponent(draftName)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data(contentsOf: source).write(to: draftURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
            } else if FileManager.default.fileExists(atPath: draftURL.path) {
                try FileManager.default.removeItem(at: draftURL)
            }
        }
        try phaseObserver?(.drafts)
        let preferences = try readSettings(value.directory.appendingPathComponent(settingsName))
        for key in preferenceKeys.union(defaults.dictionaryRepresentation().keys.filter(isReviewSessionKey)) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in preferences { defaults.set(value, forKey: key) }
        try phaseObserver?(.settings)
    }

    fileprivate static func validateStaged(_ value: PreparedFullBackup) throws {
        for entry in value.manifest.entries {
            let file = value.directory.appendingPathComponent(entry.name)
            guard try regularFileSize(file) == entry.bytes, try hash(file) == entry.sha256 else {
                throw BackupError.invalid("临时文件已变化，请重新选择备份")
            }
        }
        // 校验后没有迁移或改写临时数据库，SQLite 与哈希都对应同一份快照。
        _ = try databaseCountsAndValidate(value.directory.appendingPathComponent(databaseName), drafts: (0, 0), settings: 0)
        _ = try readSettings(value.directory.appendingPathComponent(settingsName))
        if value.manifest.entries.contains(where: { $0.name == draftName }) {
            _ = try EditorDraftPersistence.validateBackupFile(at: value.directory.appendingPathComponent(draftName))
        }
    }

    private static func databaseCountsAndValidate(_ url: URL, drafts: (Int, Int), settings: Int) throws -> Counts {
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase { AppDatabase.registerFunctions($0) }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        // 格式 1 只接收本版本已认识的完整结构，不运行备份内未知触发器或更高版本迁移。
        let identifiers = try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        // 先和备份所在版本的结构逐项比较，验证后才在恢复目标执行本机迁移。
        // 4.1.2：按备份里已完成的迁移定位版本（3.16 起每版新增迁移，以前只认最新结构，旧版备份会被拒绝）
        let targetMigration = try backupMigrationTarget(identifiers)
        let reference = try AppDatabase(DatabaseQueue(), upTo:targetMigration)
        let schema = try reference.writer.read { try schemaSignature($0) }
        return try queue.read { db in
            guard try schemaSignature(db) == schema else { throw BackupError.unsupported }
            let checks = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard checks == ["ok"], try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw BackupError.invalid("数据库不完整或关联已损坏")
            }
            let expectedMigrations = try reference.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
            guard try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") == expectedMigrations else {
                throw BackupError.unsupported
            }
            func count(_ table: String, active: Bool = false) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)" + (active ? " WHERE deletedAt IS NULL" : "")) ?? 0
            }
            return try Counts(highlights: count("highlight", active: true), cards: count("card", active: true),
                sources: count("source"), articles: count("article"), reviewEvents: count("review_event"),
                media: count("card_media") + count("image_cache") + count("source_cover"),
                highlightDrafts: drafts.0, cardDrafts: drafts.1, settings: settings)
        }
    }

    /// 备份已完成的迁移必须恰好是本机迁移序列的一个前缀；返回该前缀的最后一项（与本机相同时为 nil）。
    /// 含本机不认识的迁移（更新版本的备份）或不成前缀时，视为不支持。
    static func backupMigrationTarget(_ identifiers: [String]) throws -> String? {
        let known = AppDatabase.makeEmpty().migrationIdentifiers
        let applied = Set(identifiers)
        guard !applied.isEmpty, applied.isSubset(of: Set(known)) else { throw BackupError.unsupported }
        let prefix = Array(known.prefix(applied.count))
        guard Set(prefix) == applied, let last = prefix.last else { throw BackupError.unsupported }
        return last == known.last ? nil : last
    }

    private static func schemaSignature(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")
            .map { row in [row["type"] as String, row["name"] as String, row["tbl_name"] as String, row["sql"] as String? ?? ""].joined(separator: "\u{0}") }
    }

    private static func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-FullBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw BackupError.invalid("只支持普通文件，不接受目录或符号链接") }
        return size.uint64Value
    }

    private static func readExactly(_ input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let data = try input.read(upToCount: count - result.count), !data.isEmpty else {
                throw BackupError.invalid("文件被截断")
            }
            result.append(data)
        }
        return result
    }

    private static func copy(_ file: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty { try output.write(contentsOf: data) }
    }

    private static func hash(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty { hasher.update(data: data) }
        return digest(hasher.finalize())
    }

    private static func digest(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// 所有解出的文件都在自身临时目录。取消、完成和释放均清理；原始备份保持不变。
@Observable
final class PreparedFullBackup: Identifiable {
    let id = UUID()
    let source: URL
    let directory: URL
    let manifest: FullBackupService.Manifest
    let counts: FullBackupService.Counts
    let bytes: UInt64
    var confirmsRestore = false

    fileprivate init(source: URL, directory: URL, manifest: FullBackupService.Manifest,
                     counts: FullBackupService.Counts, bytes: UInt64) {
        self.source = source; self.directory = directory; self.manifest = manifest
        self.counts = counts; self.bytes = bytes
    }

    func validateStagedFiles() throws { try FullBackupService.validateStaged(self) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { cleanup() }
}

// MARK: - 可迁移设置：只接收有类型及取值范围约束的白名单

extension FullBackupService {
    static let booleanPreferenceKeys: Set<String> = [
        "reminder.enabled", "cards.adjustDarkColors", "menubar.showCounts", "menubar.visible", "ui.handCursor",
        "review.showRelated", "study.showContext", "sidebar.sourcesExpanded", "sidebar.tagsExpanded",
        "cards.totalNewEnabled", "cards.totalReviewsEnabled"
    ]
    static let integerPreferenceKeys: [String: ClosedRange<Int>] = [
        "review.dailyCount": 0...100_000, "review.masteryLimit": 0...100_000,
        "cards.newPerDay": 0...100_000, "cards.reviewsPerDay": 0...100_000,
        "cards.totalNewPerDay": 0...100_000, "cards.totalReviewsPerDay": 0...100_000,
        "reminder.hour": 0...23, "reminder.minute": 0...59,
        // 6.1.1：今日试卷的题数与时长也随完整备份走（换电脑、预览载入备份时卷面一样）
        "exam.minutesPerDay": 0...240, "exam.freshPerDay": 0...10, "annotate.perDay": 0...20,
        "revisit.notesPerDay": 0...20, "revisit.questionsPerDay": 0...10, "revisit.blocksPerDay": 0...10, "revisit.answersPerDay": 0...10
    ]
    static let stringPreferenceKeys: Set<String> = [
        "editor.pasteStyle", "cards.fsrsInfo", "cards.syncFromHighlight", "citation.style", "sidebar.sourceSort", "hotkey.preset", "hotkey.lookup", "hotkey.note"
    ]
    static var preferenceKeys: Set<String> {
        booleanPreferenceKeys.union(integerPreferenceKeys.keys).union(stringPreferenceKeys)
            .union(["cards.fsrsParams", "cards.sectionNames", "review.session._all"])
    }

    static func settingsSnapshot(_ defaults: UserDefaults) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in preferenceKeys.union(defaults.dictionaryRepresentation().keys.filter(isReviewSessionKey)) {
            if let value = defaults.object(forKey: key) { result[key] = value }
        }
        try validateSettings(result)
        return result
    }

    /// 6.1.1：预览载入备份时用——备份里的设置（已校验）
    static func settings(of prepared: PreparedFullBackup) throws -> [String: Any] {
        try readSettings(prepared.directory.appendingPathComponent(settingsName))
    }

    /// 6.1.1：预览载入备份时用——解出的数据库文件
    static func databaseFile(of prepared: PreparedFullBackup) -> URL {
        prepared.directory.appendingPathComponent(databaseName)
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard try regularFileSize(url) <= maximumSettingsBytes,
              let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw BackupError.invalid("设置文件不正确")
        }
        try validateSettings(dictionary)
        return dictionary
    }

    private static func validateSettings(_ values: [String: Any]) throws {
        guard values.count <= 1_000,
              values.keys.allSatisfy({ preferenceKeys.contains($0) || isReviewSessionKey($0) }) else {
            throw BackupError.invalid("含有不允许迁移的设置")
        }
        for (key, value) in values {
            let valid: Bool
            if booleanPreferenceKeys.contains(key) {
                valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            } else if let range = integerPreferenceKeys[key] {
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
                    valid = number.doubleValue >= Double(range.lowerBound) && number.doubleValue <= Double(range.upperBound)
                } else { valid = false }
            } else if stringPreferenceKeys.contains(key) {
                if let text = value as? String, text.count <= 4_096 {
                    switch key {
                    case "editor.pasteStyle": valid = ["keep","clean","plain"].contains(text)
                    case "cards.syncFromHighlight": valid = ["ask", "always", "never"].contains(text)
                    case "citation.style": valid = CitationStyle.allCases.contains { $0.rawValue == text }
                    case "sidebar.sourceSort": valid = SourceSort.allCases.contains { $0.rawValue == text }
                    case "hotkey.preset", "hotkey.lookup", "hotkey.note": valid = HotKeyPreset.allCases.contains { $0.rawValue == text }
                    default: valid = true
                    }
                } else { valid = false }
            } else if key == "cards.sectionNames" {
                valid = (value as? [String]).map { $0.count <= 100 && $0.allSatisfy { $0.count <= 200 } } ?? false
            } else if key == "cards.fsrsParams" {
                valid = (value as? [Double]).map { $0.count == 21 && $0.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } } ?? false
            } else if isReviewSessionKey(key), let data = value as? Data, data.count <= 256 * 1_024,
                      let record = try? JSONDecoder().decode(ReviewSessionRecordStore.Snapshot.self, from: data) {
                valid = record.day.count == 10 && (0...record.total).contains(record.position)
                    && record.total <= 100_000 && (record.regularIds + record.masteryIds).allSatisfy { $0 > 0 }
            } else { valid = false }
            guard valid else { throw BackupError.invalid("设置 \(key) 的类型或值不正确") }
        }
    }

    private static func isReviewSessionKey(_ key: String) -> Bool {
        key.hasPrefix("review.session.") && key.count <= 200 && key.count > "review.session.".count
            && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
