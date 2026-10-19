import AppKit
import WebKit
import SwiftUI
import KongReviewCore

struct EditorFindRefresh: Hashable {
    var query: String
    var sensitive: Bool
    var text: String
    var source: Bool
    var visible: Bool
}
enum EditorToolMode: String, Identifiable { case cleanup, resources; var id: String { rawValue } }

extension RichEditorHandle {
    func refreshFind(step: Int = 0) {
        guard showsFind else { return }
        if let view = textView {
            let matches = EditorTextMatch.find(view.string,query:findQuery,caseSensitive:findCaseSensitive)
            findCount = matches.ranges.count; findTruncated = matches.truncated
            if matches.ranges.isEmpty { findIndex = 0 } else { findIndex = (findIndex + step + matches.ranges.count) % matches.ranges.count }
            let full = NSRange(location:0,length:(view.string as NSString).length)
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor,forCharacterRange:full)
            for range in matches.ranges { view.layoutManager?.addTemporaryAttribute(.backgroundColor,value:NSColor.systemYellow.withAlphaComponent(0.45),forCharacterRange:range) }
            if matches.ranges.indices.contains(findIndex) { view.setSelectedRange(matches.ranges[findIndex]); view.scrollRangeToVisible(matches.ranges[findIndex]); EditorViewport.revealSelection(in:view) }
        } else if let webView, coordinator?.ready == true {
            let token = UUID(); findRequest = token
            webView.evaluateJavaScript("krEditorFind(\(EditorPage.jsonString(findQuery)),\(findCaseSensitive),\(step))") { [weak self] result, error in
                guard let self, self.findRequest == token else { return }
                if let value = result as? [String:Any] {
                    self.findCount = value["count"] as? Int ?? 0; self.findIndex = value["index"] as? Int ?? 0; self.findTruncated = value["truncated"] as? Bool ?? false
                    if let box = value["rect"] as? [String:Double], let x = box["x"], let y = box["y"], let width = box["width"], let height = box["height"], x.isFinite, y.isFinite, height > 0 {
                        let rect = NSRect(x:x,y:webView.isFlipped ? y : webView.bounds.height-y-height,width:width,height:height)
                        EditorViewport.reveal(rect,in:webView)
                    }
                }
                if error != nil { self.findError = "查找尚未就绪，请稍后重试。" }
            }
        }
    }
    func clearFind() {
        findRequest = UUID()
        if let view = textView { view.layoutManager?.removeTemporaryAttribute(.backgroundColor,forCharacterRange:NSRange(location:0,length:(view.string as NSString).length)) }
        webView?.evaluateJavaScript("if(window.krEditorClearFind) krEditorClearFind();",completionHandler:nil)
        findCount = 0; findIndex = 0
    }
    func replaceOne() {
        findError = nil
        if let view = textView {
            guard view.isEditable else { return }
            let result = EditorTextMatch.find(view.string,query:findQuery,caseSensitive:findCaseSensitive)
            guard !result.ranges.isEmpty else { return }
            let index = min(findIndex,result.ranges.count-1)
            view.insertText(findReplacement,replacementRange:result.ranges[index]); refreshFind()
        } else if let webView {
            webView.evaluateJavaScript("krEditorReplaceOne(\(EditorPage.jsonString(findQuery)),\(findCaseSensitive),\(EditorPage.jsonString(findReplacement)))") { [weak self] _, error in
                if error != nil { self?.findError = "替换未完成，请重新查找。" }; self?.refreshFind()
            }
        }
    }
    func prepareReplacement() {
        findError = nil
        if let view = textView {
            let matches = EditorTextMatch.find(view.string,query:findQuery,caseSensitive:findCaseSensitive)
            guard !matches.truncated else { findError = "匹配超过 5000 处，请缩小查找范围。"; return }
            presentMutation(.init(title:"全部替换预览",original:view.string,proposed:matches.replacing(view.string,with:findReplacement),count:matches.ranges.count,source:true,storedBaseline:valueReader?()))
        } else if let webView {
            webView.evaluateJavaScript("krEditorReplacementPreview(\(EditorPage.jsonString(findQuery)),\(findCaseSensitive),\(EditorPage.jsonString(findReplacement)))") { [weak self] result, error in
                guard let self else { return }
                guard error == nil, let data = result as? [String:Any] else { self.findError = "无法生成替换预览。"; return }
                if data["truncated"] as? Bool == true { self.findError = "匹配超过 5000 处，请缩小查找范围。"; return }
                self.presentMutation(.init(title:"全部替换预览",original:data["original"] as? String ?? "",proposed:data["proposed"] as? String ?? "",count:data["count"] as? Int ?? 0,source:false,storedBaseline:self.valueReader?()))
            }
        }
    }
    private func presentMutation(_ value: EditorMutation) {
        showsFind = false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.mutation = value }
    }
    func revealSourceSelection(_ range: NSRange,in expected: String) {
        // Wait for the inspection sheet to dismiss and the source view to join its window.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
            guard let view = self?.textView, view.string == expected, NSMaxRange(range) <= (view.string as NSString).length else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(range); view.scrollRangeToVisible(range); EditorViewport.revealSelection(in:view)
        }
    }
    func snapshot(_ completion: @escaping (String?,Bool)->Void) {
        if let view = textView { completion(view.string,true) }
        else if let webView { webView.evaluateJavaScript("krEditorSnapshot()") { value,_ in completion(value as? String,false) } }
        else { completion(nil,false) }
    }
    func apply(_ mutation: EditorMutation, completion: @escaping (Bool)->Void) {
        if let baseline = mutation.storedBaseline, valueReader?() != baseline { completion(false); return }
        if mutation.source, let view = textView, view.string == mutation.original, view.isEditable {
            view.insertText(mutation.proposed,replacementRange:NSRange(location:0,length:(view.string as NSString).length)); completion(true)
            DispatchQueue.main.async { [weak self] in self?.focus(); self?.refreshFind() }
        } else if !mutation.source, let webView {
            webView.evaluateJavaScript("krEditorApply(\(EditorPage.jsonString(mutation.proposed)),\(EditorPage.jsonString(mutation.original)))") { result,error in completion(error == nil && (result as? Bool) == true) }
        } else { completion(false) }
    }
}

struct EditorFindBar: View {
    @Bindable var handle: RichEditorHandle
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                TextField("查找当前正文",text:$handle.findQuery).focused($focused).onSubmit { handle.refreshFind(step:1) }
                Toggle("区分大小写",isOn:$handle.findCaseSensitive).toggleStyle(.checkbox)
                Text(handle.findCount == 0 ? "0 处" : "\(handle.findIndex+1)/\(handle.findCount)\(handle.findTruncated ? "+" : "")").font(.caption).monospacedDigit()
                Button("上一处") { handle.refreshFind(step:-1) }.disabled(handle.findCount == 0)
                Button("下一处") { handle.refreshFind(step:1) }.disabled(handle.findCount == 0)
                Button { handle.showsFind = false; handle.clearFind() } label: { Image(systemName:"xmark") }.help("关闭查找")
            }
            HStack {
                TextField("替换为（可留空）",text:$handle.findReplacement)
                Button("替换此处") { handle.replaceOne() }.disabled(handle.findCount == 0)
                Button("全部替换预览…") { handle.prepareReplacement() }.disabled(handle.findCount == 0 || handle.findTruncated)
            }
            Text("仅当前字段；文字模式查找正文，源码模式也会匹配标签和属性。替换可撤销。").font(.caption).foregroundStyle(.secondary)
            if let error = handle.findError { Text(error).font(.caption).foregroundStyle(.red) }
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(6)
        .onAppear { focused = true }
        .onChange(of:handle.findQuery) { _,_ in handle.findIndex = 0 }
    }
}

struct EditorMutationPreview: View {
    @Environment(\.dismiss) private var dismiss
    let mutation: EditorMutation
    let handle: RichEditorHandle
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(mutation.title).font(.title2.bold())
            Text("影响 \(mutation.count) 处，仅修改当前字段；采用后可在编辑器中撤销。").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    Text("修改前").font(.headline)
                    preview(mutation.original)
                    Divider(); Text("修改后").font(.headline); preview(mutation.proposed)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("确认采用") {
                handle.apply(mutation) { success in if success { dismiss() } else { error = "原内容或编辑模式已变化，请重新生成预览。" } }
            }.disabled(mutation.original == mutation.proposed || mutation.count == 0) }
        }.padding(20).frame(minWidth:640,minHeight:430)
    }
    private func preview(_ text: String) -> some View {
        Group { if mutation.source { Text(text).font(.system(.body,design:.monospaced)) } else { Text(RichText.attributed(text)) } }.textSelection(.enabled)
    }
}

/// Auto-height editors have no internal scroll offset; reveal the match in outer scroll views too.
enum EditorViewport {
    static func revealSelection(in view: NSTextView) {
        guard let layout = view.layoutManager,let container = view.textContainer,view.selectedRange().location != NSNotFound else { return }
        var selection = view.selectedRange()
        let length = (view.string as NSString).length
        if selection.length == 0,length > 0 { selection = NSRange(location:min(selection.location,length-1),length:1) }
        let glyphs = layout.glyphRange(forCharacterRange:selection,actualCharacterRange:nil)
        let box = layout.boundingRect(forGlyphRange:glyphs,in:container).offsetBy(dx:view.textContainerOrigin.x,dy:view.textContainerOrigin.y)
        reveal(box,in:view)
    }
    static func reveal(_ rect: NSRect,in view: NSView) {
        var ancestor = view.superview
        while let node = ancestor {
            if let scroll = node as? NSScrollView {
                let clip = scroll.contentView
                let target = clip.convert(rect,from:view).insetBy(dx:0,dy:-8)
                var proposed = clip.bounds
                if target.minY < proposed.minY { proposed.origin.y = target.minY }
                else if target.maxY > proposed.maxY { proposed.origin.y = target.height > proposed.height ? target.minY : target.maxY-proposed.height }
                let constrained = clip.constrainBoundsRect(proposed)
                if constrained.origin != clip.bounds.origin { clip.scroll(to:constrained.origin); scroll.reflectScrolledClipView(clip) }
            }
            ancestor = node.superview
        }
    }
}


/// A child panel stays reachable when an auto-height field scrolls out of the viewport.
struct EditorFindPresenter: NSViewRepresentable {
    let handle: RichEditorHandle
    let fieldName: String
    func makeCoordinator() -> Coordinator { Coordinator(handle:handle) }
    func makeNSView(context: Context) -> NSView { NSView(frame:.zero) }
    func updateNSView(_ view: NSView,context: Context) {
        let visible = handle.showsFind
        DispatchQueue.main.async { [weak view,weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            if visible && coordinator.handle.showsFind,let window = view?.window { coordinator.present(in:window,fieldName:fieldName) }
            else if !coordinator.handle.showsFind { coordinator.close() }
        }
    }
    static func dismantleNSView(_ view: NSView,coordinator: Coordinator) { coordinator.close(); coordinator.handle.showsFind = false }
    final class Coordinator: NSObject, NSWindowDelegate {
        let handle: RichEditorHandle
        var panel: EditorFindPanel?
        init(handle: RichEditorHandle) { self.handle = handle }
        func present(in parent: NSWindow,fieldName: String) {
            guard panel == nil else { return }
            let panel = EditorFindPanel(contentRect:NSRect(x:0,y:0,width:584,height:110),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
            panel.title = "查找与替换 · " + fieldName
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.delegate = self
            let content = NSHostingView(rootView:EditorFindBar(handle:handle).frame(width:560).padding(6))
            panel.contentView = content
            panel.setContentSize(NSSize(width:584,height:max(120,content.fittingSize.height)))
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x:frame.midX-panel.frame.width/2,y:frame.maxY-panel.frame.height-95))
            self.panel = panel
            parent.addChildWindow(panel,ordered:.above)
            panel.makeKeyAndOrderFront(nil)
        }
        func close() {
            guard let current = panel else { return }; panel = nil
            current.delegate = nil; current.parent?.removeChildWindow(current); current.close()
        }
        func windowWillClose(_ notification: Notification) { panel = nil; handle.showsFind = false; handle.clearFind() }
    }
}
final class EditorFindPanel: NSPanel { override var canBecomeKey: Bool { true } }
