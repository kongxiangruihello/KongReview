import Foundation
#if canImport(AppKit)
import AppKit
#endif
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

// MARK: - 1.2：LiquidText 导出文件夹自动导入

/// 选一个文件夹，在 LiquidText 里把笔记导出（Word / 纯文本）到这里，KongReview 自动导入：
/// - 启动、回到前台时和每分钟检查一次；只处理新出现或改动过的文件（按文件大小与修改时间判断）；
/// - 不移动、不改动文件夹里的文件；
/// - 每条摘录按“出处 + 页码 + 导入时的原文”记一个来源键（见 AppDatabase.importKey），
///   同一本书重新导出整份笔记时只导入新摘的，在 KongReview 里改过或删掉的摘录也不会被加回来。
enum LiquidTextFolder {
    static let folderKey = "liquidtext.folder"
    static let enabledKey = "liquidtext.autoImport"
    static let seenKey = "liquidtext.seenFiles"
    static let skipShortKey = "liquidtext.skipShort"
    static let keyPrefix = "liquidtext"

    static var folder: URL? {
        get { UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: folderKey) }
    }
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) && folder != nil }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// 跳过很短的摘录（不足 4 个字、不含图片，如只摘了一个人名）
    static var skipShort: Bool {
        get { UserDefaults.standard.bool(forKey: skipShortKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipShortKey) }
    }

    struct Result: Equatable {
        var files = 0
        var added = 0
        var duplicates = 0
        var images = 0
        var failed: [String] = []
        var sources: [String] = []
    }

    /// 文件夹里可导入的文件（不含子文件夹、隐藏文件和 Word 的临时文件 ~$xxx.docx）
    static func candidates(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ["docx", "txt", "rtf"].contains(ext) && !$0.lastPathComponent.hasPrefix("~$")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 文件的“指纹”：大小 + 修改时间
    static func fingerprint(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(v?.fileSize ?? -1)-\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }

    /// 检查一次（可在后台线程调用）。force 为 true 时忽略指纹、全部重新检查（去重键保证不会重复导入）。
    static func process(db: AppDatabase, force: Bool = false) -> Result {
        var r = Result()
        guard let folder, isEnabled || force else { return r }
        var seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
        for url in candidates(in: folder) {
            let fp = fingerprint(url)
            if !force && seen[url.path] == fp { continue }
            r.files += 1
            do {
                let preview = try LiquidTextReader.read(url)
                let result = skipShort ? preview.withoutShort() : preview.result
                if !preview.media.isEmpty { try db.saveMedia(preview.media) }
                let rep = try db.importReadwise(result, extraTag: "LiquidText", keyPrefix: keyPrefix)
                r.added += rep.highlightsImported
                r.duplicates += rep.duplicatesSkipped
                if rep.highlightsImported > 0 {
                    r.images += preview.media.count
                    for s in result.sources where !r.sources.contains(s.title) { r.sources.append(s.title) }
                    AppLog.write("LiquidText 文件夹：\(url.lastPathComponent) 导入 \(rep.highlightsImported) 条")
                }
                seen[url.path] = fp
            } catch {
                // 读不了的文件只提示一次；文件改动（如重新导出）后会再试
                r.failed.append(url.lastPathComponent + "：" + error.localizedDescription)
                seen[url.path] = fp
                AppLog.write("LiquidText 文件夹：\(url.lastPathComponent) 无法导入：\(error.localizedDescription)")
            }
        }
        // 已不在文件夹里的文件，从记录里去掉
        let present = Set(candidates(in: folder).map(\.path))
        seen = seen.filter { present.contains($0.key) }
        UserDefaults.standard.set(seen, forKey: seenKey)
        return r
    }
}

// MARK: - 读取 LiquidText 导出的文件（与界面无关，文件夹自动导入与菜单导入共用）

enum LiquidTextReader {
    static func read(_ url: URL) throws -> ImportPreview {
        let name = url.lastPathComponent
        // 文件名一般是“文档名 Notes.docx”，没有出处行时用它作标题
        var fallback = url.deletingPathExtension().lastPathComponent
        if fallback.hasSuffix(" Notes") { fallback = String(fallback.dropLast(6)) }
        fallback = fallback.trimmingCharacters(in: .whitespaces)

        guard url.pathExtension.lowercased() == "docx" else {
            let data = try Data(contentsOf: url)
            let text: String
            if url.pathExtension.lowercased() == "rtf", let t = rtfText(data) {
                text = t
            } else if let t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                text = t
            } else {
                throw ImportFileError("无法读取文件编码（应为 UTF-8）。")
            }
            let parsed = LiquidTextImporter.parse(LiquidTextImporter.blocks(plainText: text))
            return ImportPreview(fileName: name, result: LiquidTextImporter.result(parsed, fallbackTitle: fallback),
                                 origin: .liquidText)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-lt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // .docx 就是 zip 包；用系统自带的 ditto 解压（Linux 测试环境用 unzip）
        let p = Process()
        if FileManager.default.fileExists(atPath: "/usr/bin/ditto") {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, tmp.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", url.path, "-d", tmp.path]
        }
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportFileError("解压失败：\(name) 可能不是有效的 Word 文件。") }
        let word = tmp.appendingPathComponent("word")
        let xml = try Data(contentsOf: word.appendingPathComponent("document.xml"))
        let rels = (try? Data(contentsOf: word.appendingPathComponent("_rels/document.xml.rels")))
            .map(LiquidTextImporter.relationships) ?? [:]
        let parsed = LiquidTextImporter.parse(try LiquidTextImporter.blocks(documentXML: xml))

        var media: [String: Data] = [:]
        let result = LiquidTextImporter.result(parsed, fallbackTitle: fallback) { rid, location in
            guard let target = rels[rid] else { return nil }
            let file = word.appendingPathComponent(target).standardizedFileURL
            guard file.path.hasPrefix(tmp.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { return nil }
            let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
            // 按内容取名：同一张图重复导入不会多存
            let mediaName = "liquidtext-\(SHA1.hex(data).prefix(16)).\(ext)"
            media[mediaName] = data
            return "![\(location ?? "图片")](kr-media://media/\(mediaName))"
        }
        return ImportPreview(fileName: name, result: result, origin: .liquidText, media: media)
    }

    static func rtfText(_ data: Data) -> String? {
        #if canImport(AppKit)
        return (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                        documentAttributes: nil))?.string
        #else
        return nil
        #endif
    }
}

/// 导入文件时的错误（提示给用户的文字）
struct ImportFileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
