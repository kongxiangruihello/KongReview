import AppKit
import UniformTypeIdentifiers
import KongReviewCore

/// Markdown 导出（Obsidian 友好，带 YAML 头）
@MainActor
enum ExportService {

    static func export(source: Source, store: LibraryStore) {
        do {
            let hs = try store.db.highlights(sourceId: source.id)
            let md = MarkdownExporter.export(source: source, highlights: hs.reversed(), style: CitationSettings.style)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MarkdownExporter.fileName(for: source)
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.report(error)
        }
    }

    /// 选择 Readwise 导出的 CSV，解析后交给预览面板确认
    static func importReadwiseCSV(store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择从 readwise.io/export 下载的 CSV 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importProgress = "正在读取 \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let outcome: Swift.Result<ReadwiseCSVImporter.Result, Error>
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                    throw ImportFileError("无法读取文件编码（应为 UTF-8）。")
                }
                let result = try ReadwiseCSVImporter.parse(text)
                guard result.highlightCount > 0 else { throw ImportFileError("文件里没有可导入的摘录。") }
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                store.importProgress = nil
                switch outcome {
                case .success(let result):
                    store.pendingImport = ImportPreview(fileName: url.lastPathComponent, result: result)
                case .failure(let error):
                    store.report(error)
                }
            }
        }
    }

    // MARK: LiquidText

    /// 选择 LiquidText 导出的 Word 笔记（.docx）或纯文本，解析后交给同一个导入预览
    static func importLiquidText(store: LibraryStore) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .rtf]
        if let docx = UTType(filenameExtension: "docx") { types.insert(docx, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        panel.message = "选择 LiquidText 导出的笔记：在 LiquidText 里点“导出 → 笔记 → Word”得到的 .docx（可多选）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        store.importProgress = "正在读取 \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件")…"
        Task.detached(priority: .userInitiated) {
            let outcome: Swift.Result<ImportPreview, Error>
            do {
                var merged: ImportPreview?
                for url in urls {
                    let p = try ExportService.readLiquidText(url)
                    if var m = merged {
                        m.result.sources += p.result.sources
                        m.result.skippedRows += p.result.skippedRows
                        m.media.merge(p.media) { a, _ in a }
                        m.fileName += "、" + p.fileName
                        merged = m
                    } else {
                        merged = p
                    }
                }
                guard let preview = merged, preview.result.highlightCount > 0 else { throw LiquidTextError.empty }
                outcome = .success(preview)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                store.importProgress = nil
                switch outcome {
                case .success(let p): store.pendingImport = p
                case .failure(let e): store.report(e)
                }
            }
        }
    }

    /// 从剪贴板导入：在 LiquidText 里选中笔记 ⌘C 后使用
    static func importLiquidTextFromClipboard(store: LibraryStore) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            store.report(ImportFileError("剪贴板里没有文字。请先在 LiquidText 里选中笔记，按 ⌘C 复制。"))
            return
        }
        let parsed = LiquidTextImporter.parse(LiquidTextImporter.blocks(plainText: text))
        let result = LiquidTextImporter.result(parsed, fallbackTitle: "LiquidText 剪贴板")
        guard result.highlightCount > 0 else { store.report(LiquidTextError.empty); return }
        store.pendingImport = ImportPreview(fileName: "剪贴板", result: result, origin: .liquidText)
    }

    nonisolated static func readLiquidText(_ url: URL) throws -> ImportPreview {
        let name = url.lastPathComponent
        // 文件名一般是“文档名 Notes.docx”，没有出处行时用它作标题
        var fallback = url.deletingPathExtension().lastPathComponent
        if fallback.hasSuffix(" Notes") { fallback = String(fallback.dropLast(6)) }
        fallback = fallback.trimmingCharacters(in: .whitespaces)

        guard url.pathExtension.lowercased() == "docx" else {
            let data = try Data(contentsOf: url)
            let text: String
            if url.pathExtension.lowercased() == "rtf",
               let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                  documentAttributes: nil) {
                text = attr.string
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
        // .docx 就是 zip 包；用系统自带的 ditto 解压
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
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

    struct ImportFileError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func backupNow(store: LibraryStore) {
        do {
            let url = try BackupService.backupNow(db: store.db)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            store.reload()
        } catch {
            store.report(error)
        }
    }

    static func exportAll(store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此文件夹"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            for source in store.sources {
                let hs = try store.db.highlights(sourceId: source.id)
                guard !hs.isEmpty else { continue }
                let md = MarkdownExporter.export(source: source, highlights: hs.reversed(), style: CitationSettings.style)
                try md.write(to: dir.appendingPathComponent(MarkdownExporter.fileName(for: source)),
                             atomically: true, encoding: .utf8)
            }
            let unsorted = try store.db.highlights(unsortedOnly: true)
            if !unsorted.isEmpty {
                let md = MarkdownExporter.export(source: Source(title: "未归类"), highlights: unsorted.reversed(), style: CitationSettings.style)
                try md.write(to: dir.appendingPathComponent("未归类.md"), atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            store.report(error)
        }
    }

    // MARK: Anki 导入

    /// 选择 .apkg 或 Anki“纯文本笔记”导出的 .txt，解析后交给预览面板确认
    static func importAnki(store: LibraryStore) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .tabSeparatedText, .commaSeparatedText]
        if let apkg = UTType(filenameExtension: "apkg") { types.insert(apkg, at: 0) }
        if let colpkg = UTType(filenameExtension: "colpkg") { types.insert(colpkg, at: 1) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择 Anki 导出的牌组包 .apkg、集合包 .colpkg，或“纯文本笔记”.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importProgress = "正在读取 \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let outcome: Swift.Result<CardImportPreview, Error>
            do {
                outcome = .success(try ExportService.readAnki(url))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                store.importProgress = nil
                switch outcome {
                case .success(let p): store.cardImport = p
                case .failure(let e): store.report(e)
                }
            }
        }
    }

    nonisolated static func readAnki(_ url: URL) throws -> CardImportPreview {
        let ext = url.pathExtension.lowercased()
        if ext == "apkg" || ext == "colpkg" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-anki-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            // .apkg 就是 zip 包；用系统自带的 ditto 解压
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, tmp.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ImportFileError("解压失败：这个文件可能不是有效的 Anki 牌组。") }
            let r = try AnkiCollectionReader.read(folder: tmp)
            guard !r.notes.isEmpty else { throw ImportFileError("牌组里没有笔记。") }
            return CardImportPreview(fileName: url.lastPathComponent, notes: r.notes, media: r.media)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ImportFileError("无法读取文件编码（应为 UTF-8）。")
        }
        let parsed = try AnkiTextImporter.parse(text)
        let notes = AnkiNote.from(parsed, defaultDeck: url.deletingPathExtension().lastPathComponent)
        guard !notes.isEmpty else { throw ImportFileError("文件里没有可导入的笔记。") }
        return CardImportPreview(fileName: url.lastPathComponent, notes: notes, media: [:])
    }

    // MARK: 导出到 Anki（.apkg）

    static func exportApkg(_ request: ApkgExportRequest, store: LibraryStore) {
        let panel = NSSavePanel()
        let name = request.decks.count == 1 ? (request.decks.first ?? "KongReview") : "KongReview记忆卡"
        panel.nameFieldStringValue = name.replacingOccurrences(of: "::", with: "-") + ".apkg"
        if let apkg = UTType(filenameExtension: "apkg") { panel.allowedContentTypes = [apkg] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.apkgExport = nil
        store.maintenanceProgress = "正在导出 Anki 牌组包…"
        let db = store.db
        let params = CardSettings.fsrsParameters
        let defaults = CardSettings.defaults
        Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-apkg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let r = try db.exportApkg(decks: request.decks, includeScheduling: request.includeScheduling,
                                          fsrsParameters: params, defaults: defaults, to: tmp)
                try ApkgWriter.zip(folder: tmp, to: url)
                await MainActor.run {
                    store.maintenanceProgress = nil
                    var lines = ["已导出 \(r.cards) 张卡片到 \(url.lastPathComponent)。"]
                    if r.media > 0 { lines.append("图片 \(r.media) 个。") }
                    if r.revlog > 0 { lines.append("复习记录 \(r.revlog) 条。") }
                    lines.append("把这个文件发到手机（隔空投送、iCloud 云盘等），在 AnkiMobile / AnkiDroid 里打开即可导入。")
                    store.infoMessage = lines.joined(separator: "\n")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run { store.maintenanceProgress = nil; store.report(error) }
            }
        }
    }

    // MARK: 诊断信息

    static func exportDiagnostics(store: LibraryStore) {
        let d = UserDefaults.standard
        let settings: [(String, String)] = [
            ("快速录入快捷键", HotKeyPreset.current.label),
            ("引文速查快捷键", HotKeyPreset.lookup.label),
            ("每日回顾条数", String(d.object(forKey: SettingsKeys.dailyCount) as? Int ?? 10)),
            ("每日提醒", d.bool(forKey: SettingsKeys.reminderEnabled) ? "开" : "关"),
            ("引文体例", CitationSettings.style.rawValue),
            ("FSRS 参数", CardSettings.fsrsIsDefault ? "默认" : "已优化"),
            ("Obsidian 同步", ObsidianSync.isEnabled ? "开" : "关"),
            ("备份位置", BackupService.location.label),
            ("菜单栏数字", CardSettings.menuBarCounts ? "开" : "关"),
        ]
        let text = Diagnostics.report(db: store.db, settings: settings)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KongReview诊断信息-\(ReminderPlan.dayKey(Date())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.report(error)
        }
    }
}
