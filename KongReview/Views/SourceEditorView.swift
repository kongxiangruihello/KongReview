import SwiftUI
import KongReviewCore

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
                if source.kind == .book || source.kind == .pdf || source.kind == .other {
                    Section {
                        Toggle("按古籍篇章体例引用", isOn: Binding(
                            get: { source.classicTitle != nil },
                            set: { on in
                                store.editingSource?.classicTitle = on ? ClassicCitation.guessClassicTitle(source.title) : nil
                            }
                        ))
                        if source.classicTitle != nil {
                            HStack {
                                TextField("原典书名（如：论语、史记）", text: Binding(
                                    get: { source.classicTitle ?? "" },
                                    set: { store.editingSource?.classicTitle = $0 }
                                ))
                                // 1.8：常用古籍；出处就是原典本身且作者空着时，顺带填上习惯标注的朝代与作者
                                Menu("常用古籍") {
                                    ForEach(ClassicCitation.presets, id: \.title) { p in
                                        Button(p.author.isEmpty ? p.title : "\(p.title)　\(p.author)") {
                                            store.editingSource?.classicTitle = p.title
                                            if let a = ClassicCitation.presetAuthor(p.title),
                                               (store.editingSource?.author ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                                               (store.editingSource?.title ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "《》 　")) == p.title {
                                                store.editingSource?.author = a
                                            }
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                            let sample = CitationFormatter.citation(
                                for: Highlight(sourceId: source.id, text: "", location: "学而第一 · 第3页"), source: source)
                            let sample2 = CitationFormatter.citation(
                                for: Highlight(sourceId: source.id, text: "", location: "卷七 项羽本纪 · 第300页"), source: source)
                            Text("示例（位置“学而第一 · 第3页”）：\(sample)\n示例（位置“卷七 项羽本纪 · 第300页”）：\(sample2)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("古籍")
                    } footer: {
                        Text("脚注写成“《书名·篇名》”；篇名取摘录的“位置”（去掉页码部分，“学而第一”记作“学而”）；位置里有“卷七”这样的卷次时写成“《史记》卷七《项羽本纪》”。原典书名与标题不同（注本、整理本）时，后面再接整理本的作者、书名、出版信息与页码。GB/T 7714 格式不受影响。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                .handCursor()
                .disabled(source.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 600)
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
