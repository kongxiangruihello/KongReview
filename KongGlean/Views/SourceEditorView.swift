import SwiftUI
import KongGleanCore

struct SourceEditorView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 直接读写 store.editingSource（不用 @State，见 ViewState.swift）
    private var sourceBinding: Binding<Source> {
        Binding(
            get: { store.editingSource ?? Source(title: "") },
            set: { store.editingSource = $0 }
        )
    }
    private var source: Source { sourceBinding.wrappedValue }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本信息") {
                    TextField("标题", text: sourceBinding.title)
                    TextField("作者 / 译者", text: sourceBinding.author)
                    Picker("类型", selection: sourceBinding.kind) {
                        ForEach(SourceKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("版本信息（用于生成引文）") {
                    TextField("出版地（如：北京）", text: optional(sourceBinding.place))
                    TextField("出版者", text: optional(sourceBinding.publisher))
                    TextField("版本（如：点校本、修订版）", text: optional(sourceBinding.edition))
                    TextField("年份", text: optional(sourceBinding.year))
                    TextField("网址", text: optional(sourceBinding.url))
                    if source.kind == .article || source.kind == .web {
                        TextField(source.kind == .article ? "期刊 / 文集名" : "网站名", text: optional(sourceBinding.container))
                    }
                    if source.kind == .article {
                        TextField("卷期（如：55(34) 或 第3期）", text: optional(sourceBinding.issue))
                    }
                }
                Section("每日回顾") {
                    Picker("出现频率", selection: sourceBinding.reviewWeight) {
                        Text("不再出现").tag(0.0)
                        Text("较少").tag(0.5)
                        Text("正常").tag(1.0)
                        Text("较多").tag(2.0)
                        Text("很多").tag(4.0)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.save(source)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(source.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
    }

    private func close() {
        store.editingSource = nil
        dismiss()
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
