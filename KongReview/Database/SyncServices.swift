import Foundation
import GRDB
import KongReviewCore

// MARK: - 自动同步到 Obsidian

/// 把每个出处写成一个 Markdown 文件（YAML 头 + 摘录引用块 + 按语、出处、标签），放进选定的文件夹（通常是 Obsidian 库里的一个子文件夹）。
/// 只在内容变化时写文件，文件里的日期取该出处最近一次修改的时间，所以没改动的出处不会每天被重写。
/// 这些文件由 KongReview 生成，请在 KongReview 里修改摘录；在 Obsidian 里改动会在下次同步时被覆盖。
enum ObsidianSync {
    static let folderKey = "obsidian.folder"
    static let enabledKey = "obsidian.enabled"
    static let lastSyncKey = "obsidian.lastSync"

    static var folder: URL? {
        get { UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: folderKey) }
    }
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) && folder != nil }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    struct Report: Equatable {
        var written = 0
        var unchanged = 0
    }

    /// 同步一次：返回写入与未变的文件数
    static func run(db: AppDatabase, to folder: URL, style: CitationStyle) throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = Report()
        var usedNames = Set<String>()

        func write(_ text: String, name: String) throws {
            // 同名书（如上下册）加序号，避免互相覆盖
            var file = name
            var n = 2
            while usedNames.contains(file) {
                file = (name as NSString).deletingPathExtension + " (\(n)).md"
                n += 1
            }
            usedNames.insert(file)
            let url = folder.appendingPathComponent(file)
            if let old = try? String(contentsOf: url, encoding: .utf8), old == text {
                report.unchanged += 1
                return
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            report.written += 1
        }

        for source in try db.allSources().sorted(by: { $0.createdAt < $1.createdAt }) {
            let hs = try db.highlights(HighlightQuery(sourceId: source.id)).reversed()
            guard !hs.isEmpty else { continue }
            let stamp = hs.map(\.updatedAt).max() ?? source.createdAt
            try write(MarkdownExporter.export(source: source, highlights: Array(hs), exportedAt: stamp, style: style),
                      name: MarkdownExporter.fileName(for: source))
        }
        let unsorted = try db.highlights(HighlightQuery(unsortedOnly: true)).reversed()
        if !unsorted.isEmpty {
            let stamp = unsorted.map(\.updatedAt).max() ?? Date()
            try write(MarkdownExporter.export(source: Source(title: "未归类"), highlights: Array(unsorted), exportedAt: stamp, style: style),
                      name: "未归类.md")
        }
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        return report
    }
}

// MARK: - 收件箱：其他应用投递的摘录

/// 收件箱文件夹：~/Library/Application Support/KongReview/Inbox。
/// 其他应用（计划中的 PDF 批注应用、脚本、快捷指令）把 JSON 文件放进来（格式见 InboxPayload 与 docs/INTEGRATIONS.md），
/// KongReview 启动、回到前台和每分钟检查一次：导入成功的移到“已导入”，格式不对的移到“出错”并附上原因。
enum InboxService {
    static var folder: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KongReview/Inbox", isDirectory: true)
    }

    struct Result: Equatable {
        var files = 0
        var added = 0
        var duplicates = 0
        var failed: [String] = []
        var sources: [String] = []
    }

    static func process(db: AppDatabase, folder: URL = InboxService.folder) -> Result {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var r = Result()
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            r.files += 1
            do {
                let file = try InboxPayload.parse(try Data(contentsOf: url))
                let rep = try db.importInbox(file)
                r.added += rep.added
                r.duplicates += rep.duplicates
                if rep.added > 0 && !r.sources.contains(rep.sourceTitle) { r.sources.append(rep.sourceTitle) }
                move(url, into: folder.appendingPathComponent("已导入", isDirectory: true))
            } catch {
                r.failed.append(url.lastPathComponent + "：" + error.localizedDescription)
                let dest = move(url, into: folder.appendingPathComponent("出错", isDirectory: true))
                try? error.localizedDescription.write(to: dest.appendingPathExtension("原因.txt"), atomically: true, encoding: .utf8)
            }
        }
        return r
    }

    @discardableResult
    static func move(_ url: URL, into dir: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(stamp)." + url.pathExtension)
        }
        try? fm.moveItem(at: url, to: dest)
        return dest
    }
}
