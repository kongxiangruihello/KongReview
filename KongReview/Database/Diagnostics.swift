import Foundation
import GRDB
import KongReviewCore

/// 运行日志：出错信息与关键操作写到 ~/Library/Application Support/KongReview/Logs/kongreview.log（超过 1 MB 时轮换）。
/// 只记事件与错误，不记摘录正文。
enum AppLog {
    static var file: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KongReview/Logs/kongreview.log")
    }

    private static let queue = DispatchQueue(label: "kongreview.log")

    static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message.replacingOccurrences(of: "\n", with: " ⏎ ") + "\n"
        queue.async {
            let fm = FileManager.default
            let url = file
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func tail(_ lines: Int = 200) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "（没有日志）" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// 诊断信息：版本、系统、数据规模与设置，以及最近的日志。不含任何摘录正文，可放心发给别人排查问题。
enum Diagnostics {
    static func report(db: AppDatabase, settings: [(String, String)] = []) -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        out.append("KongReview 诊断信息 · \(ISO8601DateFormatter().string(from: Date()))")
        out.append("版本：\(info["CFBundleShortVersionString"] as? String ?? "?")（构建 \(info["CFBundleVersion"] as? String ?? "?")）")
        out.append("系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("内存：\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB，处理器核数：\(ProcessInfo.processInfo.processorCount)")
        out.append("")
        out.append("— 数据规模 —")
        let counts: [(String, String)] = (try? db.writer.read { d -> [(String, String)] in
            func n(_ sql: String) -> String { String((try? Int.fetchOne(d, sql: sql)).flatMap { $0 } ?? 0) }
            return [
                ("摘录", n("SELECT COUNT(*) FROM highlight WHERE deletedAt IS NULL")),
                ("最近删除", n("SELECT COUNT(*) FROM highlight WHERE deletedAt IS NOT NULL")),
                ("出处", n("SELECT COUNT(*) FROM source")),
                ("网页存档", n("SELECT COUNT(*) FROM article")),
                ("记忆卡", n("SELECT COUNT(*) FROM card WHERE deletedAt IS NULL")),
                ("牌组", n("SELECT COUNT(DISTINCT deck) FROM card WHERE deletedAt IS NULL")),
                ("回顾日志", n("SELECT COUNT(*) FROM review_event")),
                ("封面", n("SELECT COUNT(*) FROM source_cover")),
            ]
        }) ?? []
        for (k, v) in counts { out.append("\(k)：\(v)") }
        out.append("数据文件：\(ByteCountFormatter().string(fromByteCount: db.fileSize()))")
        if let parts = try? db.storageBreakdown() {
            for (k, v) in parts { out.append("  \(k)：\(ByteCountFormatter().string(fromByteCount: v))") }
        }
        if let v: [String] = try? db.writer.read({ d in try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations") }) {
            out.append("数据库迁移：" + v.joined(separator: ", "))
        }
        if !settings.isEmpty {
            out.append("")
            out.append("— 设置 —")
            for (k, v) in settings { out.append("\(k)：\(v)") }
        }
        out.append("")
        out.append("— 最近日志 —")
        out.append(AppLog.tail())
        return out.joined(separator: "\n")
    }
}
