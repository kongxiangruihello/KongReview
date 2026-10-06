import SwiftUI
import KongGleanCore

/// Readwise 导入前的预览与确认
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
            Text("从 Readwise 导入").font(.title2.bold())
            Text(preview.fileName).font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 24) {
                stat("\(result.highlightCount)", "条摘录")
                stat("\(result.sources.count)", "个出处")
                if result.skippedRows > 0 { stat("\(result.skippedRows)", "行无正文，将跳过") }
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

            Toggle("给导入的摘录加上标签 #Readwise", isOn: Binding(
                get: { store.importAddTag },
                set: { store.importAddTag = $0 }
            ))

            Text("导入前会自动备份一次数据库。书名和作者都相同的出处会合并到已有记录；同一出处下正文相同的摘录会跳过，所以重复导入同一文件不会产生重复。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.pendingImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入") { store.confirmImport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
