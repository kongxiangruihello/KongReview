import AppKit
import UniformTypeIdentifiers
import KongGleanCore

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
}
