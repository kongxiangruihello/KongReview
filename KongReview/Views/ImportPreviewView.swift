import SwiftUI
import KongReviewCore

/// 导入前的预览与确认（Readwise CSV、LiquidText 笔记）
struct ImportPreviewView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let preview = store.pendingImport {
            content(preview)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func content(_ preview: ImportPreview) -> some View {
        let result = preview.result
        let top = result.sources.sorted { $0.highlights.count > $1.highlights.count }.prefix(8)
        return VStack(alignment: .leading, spacing: 16) {
            Text(preview.title).font(.title2.bold())
            Text(preview.fileName).font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 24) {
                stat("\(result.highlightCount)", "条摘录")
                stat("\(result.sources.count)", "个出处")
                if !preview.media.isEmpty { stat("\(preview.media.count)", "张图片") }
                if result.skippedRows > 0 {
                    stat("\(result.skippedRows)", preview.origin == .readwise ? "行无正文，将跳过" : "条重复或无内容，将跳过")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("摘录最多的出处").font(.headline)
                ForEach(Array(top.enumerated()), id: \.offset) { pair in
                    HStack {
                        Text(pair.element.title).lineLimit(1)
                        if !pair.element.author.isEmpty {
                            Text(pair.element.author).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(pair.element.highlights.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if result.sources.count > top.count {
                    Text("……另有 \(result.sources.count - top.count) 个出处").font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle("给导入的摘录加上标签 #\(preview.tag)", isOn: Binding(
                get: { store.importAddTag },
                set: { store.importAddTag = $0 }
            ))
            if preview.origin == .liquidText && preview.shortCount > 0 {
                Toggle("跳过 \(preview.shortCount) 条很短的摘录（不足 \(ImportPreview.shortLength) 个字，如只摘了人名）", isOn: Binding(
                    get: { store.importSkipShort },
                    set: { store.importSkipShort = $0 }
                ))
            }
            if preview.origin == .liquidText {
                Text("出处取自每条笔记后的“(文档名 , p.页码)”，括号里的作者会拆出来（如“…(李逊)”）；页码记为“第 N 页”。PDF 换行留下的中文空格已去掉；批注并入上一条摘录的按语，单独的批注加标签 #批注。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("导入前会自动备份一次数据库。书名和作者都相同的出处会合并到已有记录；同一出处下正文和位置都相同的摘录会跳过，所以重复导入同一文件不会产生重复。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let progress = store.importProgress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { store.pendingImport = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.importProgress != nil)
                Button("导入") { store.confirmImport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.importProgress != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(store.importProgress != nil)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
