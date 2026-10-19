import SwiftUI
import AppKit
import KongReviewCore

struct EditorPasteView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(EditorPasteStyle.defaultsKey) private var selected = EditorPasteStyle.keep.rawValue
    let proposal: EditorPasteProposal
    let handle: RichEditorHandle
    let store: LibraryStore?
    var didAdopt: (() -> Void)?
    @State private var error: String?
    var body: some View {
        let style = EditorPasteStyle(rawValue:selected) ?? .keep
        VStack(alignment:.leading,spacing:12) {
            Text("选择粘贴方式").font(.title2.bold())
            Picker("粘贴方式",selection:$selected) { ForEach(EditorPasteStyle.allCases) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.segmented)
            Text("记住本次选择，下次作为默认选项。只插入当前字段的选区，采用后可撤销。").font(.caption).foregroundStyle(.secondary)
            EditorHTMLPreview(html:proposal.fragment(style),store:store).frame(minHeight:200)
            if proposal.source { DisclosureGroup("查看将插入的源码") { ScrollView { Text(proposal.fragment(style)).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }.frame(height:100) } }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("粘贴") {
                handle.applyPaste(proposal,style:style) { success in
                    if success { dismiss(); DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { didAdopt?() } }
                    else { error = "当前正文或编辑模式已变化，请重新粘贴。" }
                }
            }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(minWidth:580,minHeight:360)
    }
}

struct SourceAttributionView: View {
    @Environment(\.dismiss) private var dismiss
    let candidate: SourceAttribution
    var cancel: (() -> Void)? = nil
    let adopt: (String,String,String,Bool)->String?
    @State private var title = ""
    @State private var author = ""
    @State private var location = ""
    @State private var remove = true
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("核对识别出的出处").font(.title2.bold())
            Text(candidate.citation).textSelection(.enabled).foregroundStyle(.secondary)
            TextField("书名／篇名",text:$title); TextField("作者（可留空）",text:$author); TextField("页码／位置（可留空）",text:$location)
            if candidate.canRemove { Toggle("从正文移除末尾出处文字",isOn:$remove) }
            else { Text("引用带有复杂格式，正文保留原样；这里只填出处信息。").font(.caption).foregroundStyle(.secondary) }
            ScrollView { Text(KongReviewCore.Markdown.plainText(fromHTML:remove && candidate.canRemove ? candidate.body : candidate.original)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:120)
            Text("确认后填入当前录入表单，点击表单的保存才写入正式资料。现有出处和页码会按上方内容更新。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { if let cancel { cancel() } else { dismiss() } }; Button("采用出处信息") {
                error = adopt(title.trimmingCharacters(in:.whitespacesAndNewlines),author.trimmingCharacters(in:.whitespacesAndNewlines),location.trimmingCharacters(in:.whitespacesAndNewlines),remove && candidate.canRemove)
                if error == nil { dismiss() }
            }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).buttonStyle(.borderedProminent) }
        }.padding(20).frame(minWidth:560,minHeight:400)
        .onAppear { title = candidate.title; author = candidate.author; location = candidate.location; remove = candidate.canRemove }
    }
}

struct EditorOutlineView: View {
    @Bindable var handle: RichEditorHandle
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Button("返回顶部") { handle.navigateOutline(-1) }
                Button("打开目录前的位置") { handle.navigateOutline(-2) }
                Spacer(); Button("刷新") { handle.openOutline() }
                Button { handle.showsOutline = false } label: { Image(systemName:"xmark") }.help("收起目录")
            }
            Text("当前字段目录 · 点击标题跳转；正文变化后请刷新。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:6) {
                    ForEach(handle.outlineEntries) { entry in
                        Button { handle.navigateOutline(entry.id) } label: {
                            Text(entry.title.isEmpty ? "（空标题）" : entry.title).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).padding(.leading,CGFloat(entry.level-1)*10)
                        }.buttonStyle(.plain).handCursor()
                    }
                    if handle.outlineEntries.isEmpty { Text("正文还没有标题，可用 H1／H2 设置标题后刷新。仍可使用上方定位按钮。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(12).frame(width:440,height:250)
    }
}
struct EditorOutlinePresenter: NSViewRepresentable {
    let handle: RichEditorHandle
    let fieldName: String
    func makeCoordinator() -> Coordinator { Coordinator(handle) }
    func makeNSView(context: Context) -> NSView { NSView(frame:.zero) }
    func updateNSView(_ view: NSView,context: Context) {
        let visible = handle.showsOutline
        DispatchQueue.main.async { [weak view,weak c = context.coordinator] in
            guard let c else { return }
            if visible && c.handle.showsOutline,let parent = view?.window { c.present(parent,fieldName) }
            else if !c.handle.showsOutline { c.close() }
        }
    }
    static func dismantleNSView(_ view: NSView,coordinator: Coordinator) { coordinator.close(); coordinator.handle.showsOutline = false }
    final class Coordinator: NSObject,NSWindowDelegate {
        let handle: RichEditorHandle
        var panel: EditorFindPanel?
        init(_ handle: RichEditorHandle) { self.handle = handle }
        func present(_ parent: NSWindow,_ name: String) {
            guard panel == nil else { return }
            let p = EditorFindPanel(contentRect:NSRect(x:0,y:0,width:464,height:274),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
            p.title = "目录与定位 · " + name; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false; p.delegate = self
            p.contentView = NSHostingView(rootView:EditorOutlineView(handle:handle))
            p.setFrameOrigin(NSPoint(x:parent.frame.midX-p.frame.width/2,y:parent.frame.maxY-p.frame.height-65))
            panel = p; parent.addChildWindow(p,ordered:.above); p.makeKeyAndOrderFront(nil)
        }
        func close() { guard let p = panel else { return }; panel = nil; p.delegate = nil; p.parent?.removeChildWindow(p); p.close() }
        func windowWillClose(_ notification: Notification) { panel = nil; handle.showsOutline = false }
    }
}
