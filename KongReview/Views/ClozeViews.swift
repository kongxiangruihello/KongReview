import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 填空卡制作

struct ClozeEditorView: View {
    @Environment(LibraryStore.self) private var store
    @State private var sourceHandle = RichEditorHandle()

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
                    RichEditor(text:text,mode:.card,placeholder:"选中正文中的字词挖空",minHeight:200,slot:"cloze-source",handle:sourceHandle)
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
        if let web = sourceHandle.webView {
            let largest = store.clozeDraft?.numbers.max() ?? 0
            let number = sameNumber ? max(1,largest) : largest + 1
            web.evaluateJavaScript(VisualClozeScript.wrap(number:number)) { result, error in
                if error != nil || (result as? Bool) != true { store.infoMessage = "先在文本框里选中要挖空的字词。" }
            }
            return
        }
        guard let view = sourceHandle.textView, view.selectedRange().length > 0 else {
            store.infoMessage = "先在文本框里选中要挖空的字词。"
            return
        }
        let r = view.selectedRange()
        guard HTMLSourceCodec.canWrapCloze(view.string,range:r) else { store.infoMessage = "请选择标签外的完整正文，不要选中 HTML 标签或截断实体。"; return }
        let updated = AnkiContent.wrapCloze(view.string,range:r,sameNumber:sameNumber)
        view.insertText(updated,replacementRange:NSRange(location:0,length:(view.string as NSString).length))
    }
}

/// Use the browser editing command so a visual cloze remains undoable and keeps inline markup.
enum VisualClozeScript {
    static func wrap(number: Int) -> String {
        """
        (function(){
          var ed=document.getElementById('ed'), s=window.getSelection();
          if(!ed || !s || !s.rangeCount || s.isCollapsed) return false;
          var r=s.getRangeAt(0);
          if(!ed.contains(r.commonAncestorContainer)) return false;
          var box=document.createElement('div'); box.appendChild(r.cloneContents());
          ed.focus();
          document.execCommand('insertHTML',false,'{{c\(number)::'+box.innerHTML+'}}');
          ed.dispatchEvent(new Event('input',{bubbles:true})); krFlush(); return true;
        })();
        """
    }
}
