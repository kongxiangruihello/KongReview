import SwiftUI
import KongReviewCore

// MARK: - 5.1：精简提要

/// 书页头下方的一条：一句话、读完日期与重温进度
struct BookSummaryStrip: View {
    @Environment(LibraryStore.self) private var store
    let sourceId: Int64
    @State private var summary: BookSummary?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("提要", systemImage: "text.book.closed").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
            if let s = summary, !s.oneLine.isEmpty {
                Text(s.oneLine).font(.system(size: 13.5, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
            } else {
                Text("还没写。读完一本书，用一句话说它讲了什么，再写几段要点。").font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 8)
            if let f = summary?.finishedAt {
                Text("读完于 \(Self.day(f)) · 重温 \(min(3, summary?.stage ?? 0))/3").font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                    .fixedSize()
                    .help("读完后 1 个月、半年、一年各在“重温”里回来一次")
            } else {
                Button("标为读完…") { store.editBookSummary(sourceId, markFinished: true) }
                    .buttonStyle(.borderless).font(.system(size: 12.5)).handCursor()
            }
            Button(summary?.isEmpty == false ? "编辑提要…" : "写提要…") { store.editBookSummary(sourceId) }
                .buttonStyle(.borderless).font(.system(size: 12.5)).handCursor()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(ReviewPalette.soft)
        .task(id: "\(sourceId)|\(store.bookSummaryRevision)") { summary = try? store.db.bookSummary(sourceId: sourceId) }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        return f.string(from: d)
    }
}

/// 提要面板
struct BookSummarySheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: BookSummaryEditorRequest
    @State private var oneLine = ""
    @State private var bodyText = ""
    @State private var finished = false
    @State private var finishedAt = Date()
    @State private var loaded = false

    var body: some View {
        let source = store.sources.first { $0.id == request.sourceId }
        VStack(alignment: .leading, spacing: 14) {
            Text("《\(source?.title ?? "")》提要").font(.title2.bold())
            Text("只写两样：一句话说这本书讲了什么；再用一栏写要点、自己的判断与可疑之处。读完后 1 个月、半年、一年，它会在“重温”里回来，问这句话还成立吗。")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("一句话：这本书讲了什么", text: $oneLine).textFieldStyle(.roundedBorder).font(.system(size: 15))
            RichEditor(text: $bodyText, placeholder: "要点、自己的判断与可疑之处（可不填）", autoHeight: true, minHeight: 140, slot: "book-summary")
                .richEditorFrame()
            HStack(spacing: 12) {
                Toggle("已读完", isOn: $finished)
                if finished {
                    DatePicker("读完日期", selection: $finishedAt, in: ...Date(), displayedComponents: .date).labelsHidden().fixedSize()
                }
                Spacer()
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if store.saveBookSummary(sourceId: request.sourceId, oneLine: oneLine, body: bodyText, finishedAt: finished ? finishedAt : nil) { dismiss() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            if let s = try? store.db.bookSummary(sourceId: request.sourceId) {
                oneLine = s.oneLine; bodyText = s.body
                if let f = s.finishedAt { finished = true; finishedAt = f }
            }
            if request.markFinished && !finished { finished = true; finishedAt = Date() }
            loaded = true
        }
    }
}

/// 重温里的一本书：先只见书名，想一想这本书讲了什么，再展开提要对照
struct RevisitBookCard: View {
    @Environment(LibraryStore.self) private var store
    let book: RevisitBookItem
    @Binding var revealed: Bool
    let key: (KeyEquivalent) -> KeyboardShortcut?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewCardContainer(padding: 30) {
                HStack(spacing: 8) {
                    Label("读完的书", systemImage: "books.vertical").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                    Text("读完于 \(BookSummaryStrip.day(book.finishedAt)) · 第 \(book.stage + 1) 次重温（共 3 次）").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    Spacer()
                }
                Text("《\(book.title)》" + (book.author.isEmpty ? "" : "　\(book.author)"))
                    .font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    .padding(.top, 14)
                if revealed {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(book.oneLine.isEmpty ? "（还没写一句话）" : book.oneLine)
                            .font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(ReviewPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !Markdown.plainText(fromHTML: book.body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            RichWebText(text: book.body, style: .preview, slot: "revisit-book")
                        }
                        Text("这本书有 \(book.highlightCount) 条摘录。").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                    }
                    .padding(.top, 14)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb").foregroundStyle(ReviewPalette.sub)
                        Text("先想一想：这本书讲了什么？用一句话说。想好了再展开当时写的提要对照。")
                            .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 18)
                    PillButton(icon: "chevron.down", title: "展开提要", key: "空格") { revealed = true }
                        .keyboardShortcut(key(.space))
                        .padding(.top, 14)
                }
            }
            HStack(spacing: 10) {
                choice("1", "仍然成立", "checkmark", style: .primary) { store.revisitBook(book.id, .agree) }
                choice("2", "要修订", "pencil") { store.revisitBook(book.id, .revise) }
                choice("3", "以后再说", "clock") { store.revisitBook(book.id, .later) }
                Spacer()
            }
            HStack(spacing: 6) {
                Button("打开书页") { store.selection = .source(book.id) }.buttonStyle(.link).keyboardShortcut(key("e")).handCursor()
                KeyCap(text: "E")
            }
            .font(.system(size: 12))
        }
    }

    private func choice(_ k: String, _ title: String, _ icon: String, style: PillButton.Style = .normal, _ action: @escaping () -> Void) -> some View {
        PillButton(icon: icon, title: title, key: k, style: style, action: action)
            .keyboardShortcut(key(KeyEquivalent(Character(k))))
    }
}
