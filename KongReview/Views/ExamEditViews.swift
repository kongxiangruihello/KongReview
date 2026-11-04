import SwiftUI
import KongReviewCore

/// 6.2：答题时编辑试题——各栏 HTML 源码（左）与即时预览（右）；⌘↩ 保存，Esc 取消
struct ExamEditSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ExamEditRequest
    let onSaved: (ExamQuestion) -> Void
    @State private var fields: [ExamEditField]
    @State private var inserters: [String: TemplateCodeInserter] = [:]

    init(request: ExamEditRequest, onSaved: @escaping (ExamQuestion) -> Void) {
        self.request = request
        self.onSaved = onSaved
        _fields = State(initialValue: request.fields)
        _inserters = State(initialValue: Dictionary(uniqueKeysWithValues: request.fields.map { ($0.id, TemplateCodeInserter()) }))
    }

    private static let snippets: [(String, String)] = [
        ("粗体", "<b></b>"), ("标记", "<mark></mark>"), ("斜体", "<i></i>"), ("换行", "<br>"),
        ("段落", "<p></p>"), ("列表", "<ul>\n  <li></li>\n</ul>"), ("引文", "<blockquote></blockquote>"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("编辑这道题").font(.title2.bold())
                Text(request.question.kind.title).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Text("直接改 HTML 源码，右边即时预览；也可写 Markdown。只改内容，不改排程与作答记录；存后回到日课，展开与否、“我的回答”都不动。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($fields) { $field in fieldEditor($field) }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text("加粗、标记（<b>、<mark>）的片段是“要点对照”的要点。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let q = store.examSaveEdit(request, fields: fields) { onSaved(q); dismiss() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.fullBackupBusy || fields == request.fields)
            }
        }
        .padding(22)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
    }

    @ViewBuilder
    private func fieldEditor(_ field: Binding<ExamEditField>) -> some View {
        let f = field.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(f.label + (f.required ? "（必填）" : "")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if f.html, let inserter = inserters[f.id] {
                    Text("插入").font(.caption).foregroundStyle(.secondary)
                    ForEach(Self.snippets, id: \.0) { name, code in
                        Button(name) { inserter.insert(code) }.controlSize(.small).handCursor()
                    }
                }
            }
            if f.html, let inserter = inserters[f.id] {
                HStack(alignment: .top, spacing: 10) {
                    TemplateCodeEditor(text: field.text, inserter: inserter)
                        .frame(minHeight: 130)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    EditorHTMLPreview(html: f.text, store: store)
                        .frame(minHeight: 130)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                .frame(height: f.id == "text" || f.id == "front" || f.id == "f0" || f.id == "body" || f.id == "answer" ? 170 : 130)
            } else {
                TextField(f.label, text: field.text).textFieldStyle(.roundedBorder)
            }
        }
    }
}
