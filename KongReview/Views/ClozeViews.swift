import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 填空卡制作

/// 让按钮能拿到文本框里当前选中的范围
@MainActor
final class ClozeTextController {
    static let shared = ClozeTextController()
    weak var textView: NSTextView?

    var selectedRange: NSRange? {
        guard let r = textView?.selectedRange(), r.length > 0 else { return nil }
        return r
    }
}

/// 可取得选区的纯文本编辑框（SwiftUI 的 TextEditor 在 macOS 14 上拿不到选区）
struct ClozeTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont(name: "Songti SC", size: 18) ?? .systemFont(ofSize: 18)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = context.coordinator
        tv.string = text
        ClozeTextController.shared.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        ClozeTextController.shared.textView = tv
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        context.coordinator.highlight(tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            highlight(tv)
        }

        /// 把 {{c1::…}} 染成蓝色，一眼看出挖了哪些地方
        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.foregroundColor, range: full)
            storage.removeAttribute(.backgroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            guard let re = try? NSRegularExpression(pattern: #"\{\{c\d+::.*?\}\}"#, options: [.dotMatchesLineSeparators]) else { return }
            for m in re.matches(in: storage.string, range: full) {
                storage.addAttribute(.foregroundColor, value: NSColor(hex: 0x3B73EF), range: m.range)
                storage.addAttribute(.backgroundColor, value: NSColor(hex: 0x3B73EF, alpha: 0.10), range: m.range)
            }
        }
    }
}

struct ClozeEditorView: View {
    @Environment(LibraryStore.self) private var store

    private var text: Binding<String> {
        Binding(get: { store.clozeDraft?.text ?? "" }, set: { store.clozeDraft?.text = $0 })
    }

    var body: some View {
        let d = store.clozeDraft
        let numbers = d?.numbers ?? []
        let decks = (try? store.db.deckNames()) ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("做成填空卡").font(.title2.bold())
                if let p = d?.progress {
                    Text("逐条制作 · \(p)").font(.callout).foregroundStyle(ReviewPalette.accent)
                }
            }
            Text("在下面选中要背的字词，点“挖空”。每个编号（c1、c2…）生成一张卡，只遮住这一处；想在同一张卡里遮住几处，用“同卡再挖”。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    ClozeTextView(text: text)
                        .frame(minHeight: 200)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ReviewPalette.hair))
                    HStack {
                        Button {
                            wrap(sameNumber: false)
                        } label: { Label("挖空", systemImage: "rectangle.dashed") }
                            .keyboardShortcut("d", modifiers: .command)
                            .help("选中文字后按 ⌘D：新编号，单独成一张卡")
                        Button("同卡再挖") { wrap(sameNumber: true) }
                            .keyboardShortcut("d", modifiers: [.command, .shift])
                            .help("⇧⌘D：用最大的编号，和上一处在同一张卡里遮住")
                        Button("清除全部挖空") { text.wrappedValue = AnkiContent.unwrapCloze(text.wrappedValue) }
                            .disabled(numbers.isEmpty)
                        Spacer()
                        Text(numbers.isEmpty ? "还没有挖空" : "将生成 \(numbers.count) 张卡")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("牌组")
                        TextField("牌组", text: Binding(get: { store.clozeDraft?.deck ?? "" }, set: { store.clozeDraft?.deck = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Menu("选择") {
                            ForEach(decks, id: \.self) { name in Button(name) { store.clozeDraft?.deck = name } }
                        }
                        .fixedSize()
                    }
                    Text("背面附加").font(.headline)
                    RichEditor(text: Binding(get: { store.clozeDraft?.extra ?? "" }, set: { store.clozeDraft?.extra = $0 }),
                               mode: .card, placeholder: "（可选）释义、出处等", toolbar: false, minHeight: 80, slot: "cloze-extra")
                        .frame(height: 90)
                        .richEditorFrame()
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text(numbers.isEmpty ? "预览" : "预览（第 1 张，答案面）").font(.headline)
                    if let d, let n = numbers.first {
                        let c = AnkiContent.cloze(Markdown.html(d.text), number: n)
                        CardWebView(front: c.front, back: c.back + (d.extra.isEmpty ? "" : "<hr>" + Markdown.html(d.extra)), store: store)
                            .background(ReviewPalette.card)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ReviewPalette.hair))
                    } else {
                        Text("选中文字并点“挖空”后，这里显示卡片的样子。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                if d?.progress != nil {
                    Button("结束逐条制作") { store.endClozeQueue() }
                        .keyboardShortcut(.cancelAction)
                    Button("跳过这条") { store.skipCloze() }
                        .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("取消", role: .cancel) { store.clozeDraft = nil }
                        .keyboardShortcut(.cancelAction)
                }
                Button(d?.progress != nil ? "生成 \(max(numbers.count, 1)) 张卡，下一条" : "生成 \(max(numbers.count, 1)) 张卡") { store.commitCloze() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .handCursor()
                    .disabled(numbers.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 600)
    }

    private func wrap(sameNumber: Bool) {
        guard let r = ClozeTextController.shared.selectedRange else {
            store.infoMessage = "先在文本框里选中要挖空的字词。"
            return
        }
        text.wrappedValue = AnkiContent.wrapCloze(text.wrappedValue, range: r, sameNumber: sameNumber)
    }
}
