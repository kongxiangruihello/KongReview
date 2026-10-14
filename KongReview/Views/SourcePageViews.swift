import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 1.6：出处书页

/// 点侧边栏的出处时，列表上方的书页头：封面、书目、统计、排序、导出读书笔记
struct SourcePageHeader: View {
    @Environment(LibraryStore.self) private var store
    let sourceId: Int64

    var body: some View {
        let _ = store.revision
        let source = store.sources.first { $0.id == sourceId }
        let stats = (try? store.db.sourcePageStats(sourceId)) ?? SourcePageStats()
        HStack(alignment: .top, spacing: 16) {
            SourceThumb(source: source, size: CGSize(width: 52, height: 70))
            VStack(alignment: .leading, spacing: 5) {
                Text(source?.title ?? "出处")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(ReviewPalette.ink)
                    .lineLimit(2)
                let byline = [source?.author ?? "", source?.publisher ?? "", source?.year ?? ""].filter { !$0.isEmpty }
                if !byline.isEmpty {
                    Text(byline.joined(separator: " · ")).font(.callout).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                }
                HStack(spacing: 14) {
                    stat("\(stats.total)", "条摘录")
                    if let lo = stats.firstPage, let hi = stats.lastPage, stats.withPage > 0 {
                        stat(lo == hi ? "第 \(lo) 页" : "第 \(lo)–\(hi) 页", "")
                    }
                    stat("\(stats.reviewed)", "条回顾过")
                    if stats.withNote > 0 { stat("\(stats.withNote)", "条有按语") }
                    if stats.cards > 0 { stat("\(stats.cards)", "条做成记忆卡") }
                    if stats.favorites > 0 { stat("\(stats.favorites)", "条收藏") }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Picker("排序", selection: Bindable(store.list).sourceByPage) {
                    Text("按页码").tag(true)
                    Text("按录入时间").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("按页码：没有页码的摘录排在最后")
                HStack(spacing: 8) {
                    Menu {
                        Button("Word 文档…") { ReadingNotesExport.export(store: store, sourceId: sourceId, format: .docx) }
                        Button("Markdown…") { ReadingNotesExport.export(store: store, sourceId: sourceId, format: .markdown) }
                    } label: {
                        Label("导出读书笔记", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .handCursor()
                    .fixedSize()
                    .help("这本书的全部摘录按页码排列，附位置与按语")
                    if let source {
                        Button("编辑出处…") { store.editingSource = source }
                            .buttonStyle(.link)
                            .handCursor()
                    }
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(ReviewPalette.card)
    }

    private func stat(_ number: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(number).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
            if !label.isEmpty { Text(label).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub) }
        }
    }
}

@MainActor
enum ReadingNotesExport {
    enum Format { case docx, markdown }

    static func export(store: LibraryStore, sourceId: Int64, format: Format) {
        guard let source = store.sources.first(where: { $0.id == sourceId }) else { return }
        let hs = (try? store.db.sourceHighlightsByPage(sourceId)) ?? []
        guard !hs.isEmpty else { store.infoMessage = "这个出处下还没有摘录。"; return }
        let bib = Bibliography.entries([source], order: .authorYear).first ?? ""
        let pieces = ReadingNotes.pieces(bibliography: bib, highlights: hs)
        let title = "《\(source.title)》读书笔记"
        let options = NotebookExportOptions(footnotes: false, bibliography: [], toc: false)
        switch format {
        case .docx:
            guard let url = NotebookExport.savePanel(title + ".docx", type: UTType(filenameExtension: "docx") ?? .data) else { return }
            NotebookExport.writePackage(NotebookDocx.files(title: title, pieces: pieces, options: options), to: url, store: store, what: "读书笔记")
        case .markdown:
            guard let url = NotebookExport.savePanel(title + ".md", type: UTType(filenameExtension: "md") ?? .plainText) else { return }
            do {
                try NotebookExporter.markdown(title: title, pieces: pieces, options: options).write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                store.report(error)
            }
        }
    }
}
