import SwiftUI
import AppKit
import KongReviewCore

/// All body editors expose literal HTML source. Legacy Markdown is converted for display only;
/// opening/cancelling an editor never rewrites the stored content.
struct RichEditor: View {
    @Binding var text: String
    var mode: RichEditorMode = .markdown
    var font: RichEditorFont = .body
    var placeholder: String = ""
    var toolbar = true
    var autoHeight = false
    var minHeight: CGFloat = 70
    var focus = false
    var slot = "editor"
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onTab: ((Bool) -> Void)? = nil
    var handle: RichEditorHandle? = nil
    var formatting: CardFormattingState? = nil
    var fieldName = ""
    @State private var localHandle = RichEditorHandle()
    @State private var measuredHeight: CGFloat = 70
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if toolbar {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:6) {
                        Text("HTML 源码").font(.caption).foregroundStyle(.secondary)
                        ForEach(["p","strong","em","h2","ul","blockquote","a","br"],id:\.self) { tag in
                            Button("<\(tag)>") { (handle ?? localHandle).textView?.applyHTML(tag) }.help("插入 \(tag) 标签")
                        }
                    }.controlSize(.small).padding(5)
                }.fixedSize(horizontal:false,vertical:true)
            }
            HTMLSourceEditorRep(text:$text,measuredHeight:$measuredHeight,autoHeight:autoHeight,minHeight:minHeight,
                focus:focus,placeholder:placeholder,slot:slot,handle:handle ?? localHandle,formatting:formatting,fieldName:fieldName,
                onSubmit:onSubmit,onCancel:onCancel,onTab:onTab)
                .frame(minHeight:minHeight)
                .frame(height:autoHeight ? max(minHeight,measuredHeight) : nil)
        }
    }
}

struct RichEditorFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.background(ReviewPalette.card,in:RoundedRectangle(cornerRadius:8))
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(ReviewPalette.hair))
    }
}
extension View { func richEditorFrame() -> some View { modifier(RichEditorFrame()) } }

@MainActor @Observable final class RichEditorHandle {
    weak var textView: HTMLSourceTextView?
    func focus(selectAll: Bool = false) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if selectAll { textView.selectAll(nil) }
    }
}

struct HTMLSourceEditorRep: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let autoHeight: Bool
    let minHeight: CGFloat
    let focus: Bool
    let placeholder: String
    let slot: String
    let handle: RichEditorHandle
    let formatting: CardFormattingState?
    let fieldName: String
    let onSubmit: (() -> Void)?
    let onCancel: (() -> Void)?
    let onTab: ((Bool) -> Void)?
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SourceScrollView {
        let scroll = SourceScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = !autoHeight; scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder; scroll.passScroll = autoHeight
        let view = HTMLSourceTextView(frame:NSRect(x:0,y:0,width:400,height:minHeight))
        view.isRichText = false; view.isEditable = enabled; view.isSelectable = true; view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular); view.textColor = .textColor; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width:10,height:10)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
        view.minSize = NSSize(width:0,height:minHeight); view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel((fieldName.isEmpty ? placeholder : fieldName) + " HTML 源码")
        view.setAccessibilityHelp("直接编辑 HTML 标签和正文，命令回车保存；粘贴保留源码。")
        context.coordinator.lastStored = text
        view.string = HTMLSourceCodec.editable(text)
        scroll.documentView = view
        handle.textView = view
        formatting?.attach(slot:slot,name:fieldName,textView:view)
        let c = context.coordinator
        view.changed = { [weak c, weak view] value in
            guard let c, let view else { return }; c.lastStored = value; c.parent.text = value; c.measure(view)
        }
        view.resized = { [weak c,weak view] in if let view { c?.measure(view) } }
        view.focused = { [weak c] in guard let c else { return }; c.parent.formatting?.activate(c.parent.slot) }
        configure(view)
        DispatchQueue.main.async { [weak c,weak view] in
            guard let view else { return }; c?.measure(view)
            if c?.parent.focus == true { view.window?.makeFirstResponder(view) }
        }
        return scroll
    }
    func updateNSView(_ scroll: SourceScrollView, context: Context) {
        let c = context.coordinator; c.parent = self
        guard let view = scroll.documentView as? HTMLSourceTextView else { return }
        view.isEditable = enabled; configure(view)
        if text != c.lastStored {
            c.lastStored = text; view.string = HTMLSourceCodec.editable(text); view.undoManager?.removeAllActions()
        }
        handle.textView = view; formatting?.attach(slot:slot,name:fieldName,textView:view)
        c.measure(view)
    }
    private func configure(_ view: HTMLSourceTextView) { view.submit = onSubmit; view.cancel = onCancel; view.tabOut = onTab }
    static func dismantleNSView(_ scroll: SourceScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? HTMLSourceTextView else { return }
        coordinator.parent.formatting?.detach(slot:coordinator.parent.slot,textView:view)
        view.changed = nil; view.resized = nil; view.focused = nil
    }
    @MainActor final class Coordinator {
        var parent: HTMLSourceEditorRep
        var lastStored = ""
        init(_ parent: HTMLSourceEditorRep) { self.parent = parent }
        func measure(_ view: NSTextView) {
            guard parent.autoHeight,let layout = view.layoutManager,let container = view.textContainer else { return }
            layout.ensureLayout(for:container)
            let height = max(parent.minHeight,ceil(layout.usedRect(for:container).height + view.textContainerInset.height*2 + 4))
            guard abs(parent.measuredHeight-height)>1 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.measuredHeight = height }
        }
    }
}
final class SourceScrollView: NSScrollView {
    var passScroll = false
    override func scrollWheel(with event: NSEvent) { if passScroll { nextResponder?.scrollWheel(with:event) } else { super.scrollWheel(with:event) } }
}
final class HTMLSourceTextView: NSTextView {
    var changed: ((String)->Void)?
    var resized: (()->Void)?
    var focused: (()->Void)?
    var submit: (()->Void)?
    var cancel: (()->Void)?
    var tabOut: ((Bool)->Void)?
    override func didChangeText() { super.didChangeText(); changed?(string) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resized?() }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { focused?() }; return ok }
    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType:.string) ?? NSPasteboard.general.string(forType:.html) { insertText(value,replacementRange:selectedRange()) }
    }
    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "\r", let submit { submit(); return }
            let tags = ["b":"strong","i":"em","u":"u","1":"h1","2":"h2","3":"h3","e":"code","k":"a"]
            if let tag = tags[key] { applyHTML(tag); return }
        }
        if event.keyCode == 53, let cancel { cancel(); return }
        if event.keyCode == 48,let tabOut { tabOut(event.modifierFlags.contains(.shift)); return }
        super.keyDown(with:event)
    }
    func applyHTML(_ command: String) {
        guard isEditable else { return }
        let map = ["bold":"strong","italic":"em","strike":"s","quote":"blockquote","code":"code"]
        let tag = map[command] ?? command
        let range = selectedRange(), ns = string as NSString
        guard range.location != NSNotFound, NSMaxRange(range)<=ns.length else { return }
        let selected = ns.substring(with:range)
        let prefix: String, suffix: String
        switch tag {
        case "br","hr": prefix = "<\(tag)>"; suffix = ""
        case "ul","ol": prefix = "<\(tag)>\n<li>"; suffix = "</li>\n</\(tag)>"
        case "a": prefix = "<a href=\"https://\">"; suffix = "</a>"
        case "clear":
            insertText(Markdown.plainText(fromHTML:selected),replacementRange:range); return
        default: prefix = "<\(tag)>"; suffix = "</\(tag)>"
        }
        window?.makeFirstResponder(self)
        insertText(prefix+selected+suffix,replacementRange:range)
        setSelectedRange(NSRange(location:range.location+(prefix as NSString).length,length:(selected as NSString).length))
    }
    func insertHTMLLink(_ url: String) {
        guard isEditable else { return }
        let range = selectedRange(), selected = (string as NSString).substring(with:range)
        let value = url.isEmpty ? Markdown.plainText(fromHTML:selected) : "<a href=\"" + HTMLSourceCodec.attribute(url) + "\">" + (selected.isEmpty ? HTMLSourceCodec.attribute(url) : selected) + "</a>"
        window?.makeFirstResponder(self); insertText(value,replacementRange:range)
    }
}

enum HTMLSourceCodec {
    static func hasContent(_ text: String) -> Bool {
        !Markdown.plainText(fromHTML:text).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
        text.range(of:#"<(?:img|audio|video)\b"#,options:[.regularExpression,.caseInsensitive]) != nil
    }
    static func editable(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if Markdown.looksLikeHTML(text) || Markdown.containsHTMLTag(text) { return text }
        return Markdown.html(text)
    }
    static func canWrapCloze(_ source: String, range: NSRange) -> Bool {
        let ns = source as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range)<=ns.length else { return false }
        let pattern = #"<[^>]*>|&(?:#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z]+);"#
        let matches = (try? NSRegularExpression(pattern:pattern))?.matches(in:source,range:NSRange(location:0,length:ns.length)) ?? []
        for match in matches where NSIntersectionRange(range,match.range).length > 0 {
            if ns.substring(with:match.range).hasPrefix("<") { return false }
            if NSIntersectionRange(range,match.range) != match.range { return false }
        }
        return true
    }
    static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
    }
}
