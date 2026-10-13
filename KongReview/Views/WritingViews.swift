import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 1.2：参考文献表

/// 参考文献表的选项（不用 @State，见 ViewState.swift 的说明）
@MainActor
@Observable
final class BibliographyOptions {
    static let shared = BibliographyOptions()
    var order: Bibliography.Order = Bibliography.Order(rawValue: UserDefaults.standard.string(forKey: "bib.order") ?? "") ?? .numbered {
        didSet { UserDefaults.standard.set(order.rawValue, forKey: "bib.order") }
    }
}

/// 按 GB/T 7714—2015 列出参考文献，可复制或存为文本
struct BibliographyView: View {
    @Environment(LibraryStore.self) private var store
    private var options: BibliographyOptions { BibliographyOptions.shared }

    var body: some View {
        let req = store.bibliographyRequest
        let entries = req.map { Bibliography.entries($0.sources, order: options.order) } ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text("参考文献表").font(.title2.bold())
            if let req {
                Text("\(req.title) · \(entries.count) 种文献").foregroundStyle(.secondary)
            }
            Picker("排列", selection: Bindable(options).order) {
                ForEach(Bibliography.Order.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        Text(e)
                            .font(.system(size: 13.5, design: .serif))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ReviewPalette.hair))
            Text("按 GB/T 7714—2015：整部文献不列页码；网页附引用日期。出版地、出版者、年份等取自“编辑出处”，缺的项会略去，可在出处里补全后再生成。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.joined(separator: "\n"), forType: .string)
                    store.bibliographyRequest = nil
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .handCursor()
                .disabled(entries.isEmpty)
                Button("存为文本…") { save(entries, title: req?.title ?? "参考文献") }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("关闭", role: .cancel) { store.bibliographyRequest = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    private func save(_ entries: [String], title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(title)-参考文献.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (entries.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            store.bibliographyRequest = nil
        } catch {
            store.report(error)
        }
    }
}

struct WritingSheets: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content
            .sheet(item: $store.bibliographyRequest) { _ in BibliographyView() }
    }
}

extension LibraryStore {
    /// 为一组摘录的出处生成参考文献表（出处按首次出现的顺序）
    func showBibliography(for highlights: [Highlight], title: String) {
        var ids: [Int64] = []
        for h in highlights {
            if let id = h.sourceId, !ids.contains(id) { ids.append(id) }
        }
        showBibliography(sourceIDs: ids, title: title)
    }

    func showBibliography(sourceIDs: [Int64], title: String) {
        let byID = Dictionary(sources.compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let list = sourceIDs.compactMap { byID[$0] }
        guard !list.isEmpty else {
            infoMessage = "这些摘录没有出处，无法生成参考文献表。"
            return
        }
        bibliographyRequest = BibliographyRequest(title: title, sources: list)
    }
}
