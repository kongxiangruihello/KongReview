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
        VStack(spacing: 0) {
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
                    Button {
                        store.reviewSource(sourceId)
                    } label: {
                        Label("回顾这本书", systemImage: "sun.max")
                    }
                    .buttonStyle(.borderless)
                    .handCursor()
                    .disabled(stats.total == 0)
                    .help("在“今日回顾”里按页码顺序把这本书的摘录从头过一遍")
                    // 2.0：按篇（摘录位置里有篇名或卷次时出现）
                    // 2.1：每篇显示进度（回顾过几条、做成记忆卡几条）
                    let chapters = (try? store.db.chapterProgress(sourceId)) ?? []
                    if !chapters.isEmpty {
                        Menu {
                            Button("篇目进度…") { store.chapterProgressRequest = ChapterProgressRequest(sourceId: sourceId) }
                            Divider()
                            Text("共 \(chapters.count) 篇（按书中顺序）")
                            ForEach(chapters) { ch in
                                Menu((ch.reviewed == ch.total ? "✓ " : "") + "《\(ch.name)》\(ch.summary)") {
                                    Button("回顾这一篇") { store.reviewChapter(sourceId, ch.name) }
                                    Button("做成记忆卡（牌组“\(store.chapterBookTitle(sourceId))::\(ch.name)”）") {
                                        store.makeCardsForChapter(sourceId, ch.name)
                                    }
                                }
                            }
                        } label: {
                            Label("按篇", systemImage: "list.bullet.indent")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .handCursor()
                        .fixedSize()
                        .help("按摘录位置里的篇名（如“学而第一”）分篇：回顾一篇，或把一篇做成记忆卡")
                    }
                    // 2.2：这部古籍还有别的版本时，可从对照表导入各条在那个版本里的页码
                    if !store.editions(for: sourceId).isEmpty {
                        Button {
                            store.openEditionImport(sourceId)
                        } label: {
                            Label("导入版本页码…", systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .handCursor()
                        .help("从页码对照表（Excel、CSV，或在 Excel 里复制的几列）一次填好各条摘录在另一个版本里的页码")
                    }
                    Button {
                        store.openPageRange(sourceId)
                    } label: {
                        Label("按页码…", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .buttonStyle(.borderless)
                    .handCursor()
                    .disabled(stats.withPage == 0)
                    .help("选一个页码范围：回顾这一段、做成记忆卡、导出，或选中后批量加标签等")
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
        // 5.1：精简提要
        BookSummaryStrip(sourceId: sourceId)
        }
        .sheet(item: Bindable(store).pageRange) { draft in
            PageRangeSheet(draft: draft)
        }
        .sheet(item: Bindable(store).chapterProgressRequest) { req in
            ChapterProgressSheet(sourceId: req.sourceId)
        }
        .sheet(item: Bindable(store).editionImport) { d in
            EditionImportSheet(draft: d)
        }
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

    static func export(store: LibraryStore, sourceId: Int64, format: Format, pages: ClosedRange<Int>? = nil) {
        guard let source = store.sources.first(where: { $0.id == sourceId }) else { return }
        let hs = (try? store.db.sourceHighlights(sourceId, pages: pages)) ?? []
        guard !hs.isEmpty else { store.infoMessage = pages == nil ? "这个出处下还没有摘录。" : "这个页码范围内没有摘录。"; return }
        let bib = Bibliography.entries([source], order: .authorYear).first ?? ""
        let pieces = ReadingNotes.pieces(bibliography: bib, highlights: hs)
        let title = "《\(source.title)》读书笔记" + (pages.map { "（\(LibraryStore.pageLabel($0))）" } ?? "")
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

// MARK: - 1.7：按页码范围批量

struct PageRangeSheet: View {
    @Environment(LibraryStore.self) private var store
    let draft: PageRangeDraft

    var body: some View {
        let _ = store.revision
        let source = store.sources.first { $0.id == draft.sourceId }
        let range = draft.range
        let hits = range.flatMap { try? store.db.sourceHighlights(draft.sourceId, pages: $0) } ?? []
        let stats = (try? store.db.sourcePageStats(draft.sourceId)) ?? SourcePageStats()
        VStack(alignment: .leading, spacing: 14) {
            Text("按页码范围").font(.title2.bold())
            if let source {
                Text("《\(source.title)》" + ((stats.firstPage != nil && stats.lastPage != nil) ? "：摘录分布在第 \(stats.firstPage!)–\(stats.lastPage!) 页" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("第")
                TextField("起", text: Bindable(draft).fromText).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("页 至 第")
                TextField("止", text: Bindable(draft).toText).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("页")
                Spacer()
                Text(range == nil ? "请输入页码" : "\(hits.count) 条摘录")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(hits.isEmpty ? Color.secondary : ReviewPalette.accent)
            }
            Text("只填一头表示另一头不限；没有页码的摘录不在范围内。页码取摘录“位置”里的第一个数字。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                action("回顾这一段", "sun.max", "在“今日回顾”里按页码顺序过一遍") {
                    if let r = range { store.pageRange = nil; store.reviewSource(draft.sourceId, pages: r) }
                }
                action("做成记忆卡", "rectangle.on.rectangle.angled", "放进以书名命名的牌组“\(source?.title ?? "")”；已有卡片的不重复做") {
                    if let r = range { store.makeCardsForPageRange(draft.sourceId, r) }
                }
                action("导出这一段的读书笔记（Word）", "doc.richtext", "按页码排列，附位置与按语") {
                    if let r = range {
                        store.pageRange = nil
                        ReadingNotesExport.export(store: store, sourceId: draft.sourceId, format: .docx, pages: r)
                    }
                }
                action("在列表中选中", "checklist", "选中后用工具栏的“批量操作”：加标签、移到出处、加入笔记本、弃置……") {
                    if let r = range { store.selectPageRange(draft.sourceId, r) }
                }
            }
            .disabled(hits.isEmpty)
            HStack {
                Spacer()
                Button("关闭", role: .cancel) { store.pageRange = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func action(_ title: String, _ icon: String, _ detail: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(ReviewPalette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    Text(detail).font(.caption).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ReviewPalette.sub)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(ReviewPalette.page))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - 2.1：篇目进度

/// 一本书各篇：条数、回顾过几成（进度条用书脊色）、做成记忆卡几条；每篇可回顾、做卡
struct ChapterProgressSheet: View {
    @Environment(LibraryStore.self) private var store
    let sourceId: Int64

    var body: some View {
        let _ = store.revision
        let rows = (try? store.db.chapterProgress(sourceId)) ?? []
        let book = store.chapterBookTitle(sourceId)
        let tint = DeckColors.color(for: book)
        let total = rows.reduce(0) { $0 + $1.total }
        let reviewed = rows.reduce(0) { $0 + $1.reviewed }
        let done = rows.filter { $0.total > 0 && $0.reviewed == $0.total }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("《\(book)》篇目进度").font(.system(size: 22, weight: .semibold, design: .serif))
                Spacer()
                Text("\(rows.count) 篇 · \(done) 篇已全部回顾 · 共回顾 \(reviewed)/\(total) 条")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            }
            Text("“回顾过”指在今日回顾里出现过。条形图越满，这一篇过得越全；还没开始的篇排在原位、条形图为空。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { r in
                        HStack(spacing: 12) {
                            Text(r.name)
                                .font(.system(size: 15, weight: .medium, design: .serif))
                                .foregroundStyle(ReviewPalette.ink)
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(ReviewPalette.hair)
                                    Capsule().fill(tint).frame(width: max(0, geo.size.width * r.reviewedRatio))
                                }
                            }
                            .frame(height: 6)
                            Text("\(r.reviewed)/\(r.total)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(ReviewPalette.sub)
                                .frame(width: 52, alignment: .trailing)
                            Text(r.withCards > 0 ? "卡 \(r.withCards)" : "—")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(r.withCards > 0 ? DeckColors.reviewColor : ReviewPalette.sub)
                                .frame(width: 44, alignment: .trailing)
                            Button("回顾") {
                                store.chapterProgressRequest = nil
                                store.reviewChapter(sourceId, r.name)
                            }
                            .controlSize(.small)
                            .handCursor()
                            Button("做卡") { store.makeCardsForChapter(sourceId, r.name) }
                                .controlSize(.small)
                                .handCursor()
                                .disabled(r.withCards == r.total)
                                .help(r.withCards == r.total ? "这一篇的摘录都已有记忆卡" : "做成记忆卡，牌组“\(book)::\(r.name)”")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(ReviewPalette.soft))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 460)
            HStack {
                Spacer()
                Button("关闭", role: .cancel) { store.chapterProgressRequest = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}

// MARK: - 2.2：从对照表导入版本页码

enum EditionImportFile {
    /// 读 .xlsx（第一张表）、.csv、.tsv、.txt；CSV 不是 UTF-8 时按 GB18030（中文 Windows 版 Excel 存的 CSV）读
    static func read(_ url: URL) throws -> [[String]] {
        if url.pathExtension.lowercased() == "xlsx" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kr-xlsx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, tmp.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ImportFileError("解压失败：这个文件可能不是有效的 Excel（.xlsx）文件。") }
            let sheet = tmp.appendingPathComponent("xl/worksheets/sheet1.xml")
            guard let sheetData = try? Data(contentsOf: sheet) else {
                throw ImportFileError("没找到第一张工作表（xl/worksheets/sheet1.xml）。")
            }
            let shared = try? Data(contentsOf: tmp.appendingPathComponent("xl/sharedStrings.xml"))
            return EditionPageImport.cells(sheetXML: sheetData, sharedStringsXML: shared)
        }
        let data = try Data(contentsOf: url)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) ?? String(data: data, encoding: .utf16) else {
            throw ImportFileError("无法读取文件编码（应为 UTF-8 或 GB18030）。")
        }
        return EditionPageImport.cells(fromText: text)
    }
}

struct EditionImportSheet: View {
    @Environment(LibraryStore.self) private var store
    let draft: EditionImportDraft

    var body: some View {
        let source = store.sources.first { $0.id == draft.sourceId }
        let eds = store.editions(for: draft.sourceId)
        let rows = draft.rows
        let hs = (try? store.db.sourceHighlightsByPage(draft.sourceId)) ?? []
        let preview = EditionPageImport.match(hs, rows: rows)
        let byId: [Int64: Highlight] = Dictionary(hs.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 12) {
            Text("导入版本页码").font(.system(size: 22, weight: .semibold, design: .serif))
            Text("把《\(source?.title ?? "")》各条摘录在另一个版本里的页码一次填好。对照表每行写“原页码 → 该版页码”，可在前面加一列篇名（同一页码在不同篇时用来区分）；原页码可写范围，如 3-5。第一行是表头也没关系。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("对照的版本", selection: Bindable(draft).editionId) {
                ForEach(eds) { e in Text(NotebookExport.editionName(e)).tag(e.id) }
            }
            HStack(spacing: 10) {
                Button("选择文件（Excel / CSV）…") { chooseFile() }
                    .handCursor()
                Button("从剪贴板粘贴") { paste() }
                    .handCursor()
                    .help("在 Excel、Numbers 里选中两三列复制，再点这里")
                Spacer()
                if !draft.origin.isEmpty {
                    Text("\(draft.origin)：读到 \(rows.count) 行对照").font(.callout).foregroundStyle(ReviewPalette.sub)
                }
            }
            if let e = draft.error { Text(e).font(.callout).foregroundStyle(ReviewPalette.again) }
            if !rows.isEmpty {
                HStack(spacing: 18) {
                    Label("能对上 \(preview.matches.count) 条", systemImage: "checkmark.circle").foregroundStyle(DeckColors.reviewColor)
                    if !preview.unmatched.isEmpty {
                        Label("对照表里没有 \(preview.unmatched.count) 条", systemImage: "questionmark.circle").foregroundStyle(ReviewPalette.hard)
                    }
                    if !preview.noPage.isEmpty {
                        Label("没有页码 \(preview.noPage.count) 条", systemImage: "minus.circle").foregroundStyle(ReviewPalette.sub)
                    }
                }
                .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(preview.matches.prefix(60).enumerated()), id: \.offset) { _, m in
                            if let h = byId[m.highlightId] {
                                HStack(spacing: 10) {
                                    Text(h.location ?? "").font(.system(size: 11.5).monospacedDigit())
                                        .foregroundStyle(ReviewPalette.sub).frame(width: 150, alignment: .leading).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(ReviewPalette.sub)
                                    Text(m.page).font(.system(size: 12, weight: .medium).monospacedDigit()).frame(width: 60, alignment: .leading)
                                    Text(h.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 12.5, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
                Toggle("覆盖已经填过的该版页码", isOn: Bindable(draft).overwrite)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.editionImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(preview.matches.count) 条") { store.commitEditionImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(preview.matches.isEmpty || draft.editionId == nil)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["xlsx", "csv", "tsv", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft.cells = try EditionImportFile.read(url)
            draft.origin = url.lastPathComponent
            draft.error = draft.rows.isEmpty ? "没有读到对照行：请确认有“原页码、该版页码”两列（可另加篇名列）。" : nil
        } catch {
            draft.error = error.localizedDescription
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            draft.error = "剪贴板里没有文字。"
            return
        }
        draft.cells = EditionPageImport.cells(fromText: text)
        draft.origin = "剪贴板"
        draft.error = draft.rows.isEmpty ? "剪贴板里没有读到对照行：请在表格里选中“原页码、该版页码”两列（可另加篇名列）再复制。" : nil
    }
}
