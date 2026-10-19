import SwiftUI
import KongReviewCore
import WebKit
import GRDB

struct EditorCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    let sourceMode: Bool
    let handle: RichEditorHandle
    let store: LibraryStore?
    let storedBaseline: String
    @State private var options = EditorCleanupOptions()
    @State private var error: String?
    var body: some View {
        let result = EditorFormattingCleanup.clean(original,options:options)
        VStack(alignment:.leading,spacing:12) {
            Text("格式清理预览").font(.title2.bold())
            Text("仅清理当前字段。粗体标签、列表、链接和媒体保留；代码块与脚本内容不自动清理。采用后可撤销。").font(.caption).foregroundStyle(.secondary)
            HStack { Toggle("清除内联字体／字号",isOn:$options.fonts); Toggle("清除内联颜色",isOn:$options.colors) }
            HStack { Toggle("清除空段落",isOn:$options.emptyLines); Toggle("清除空 span／Word 标记",isOn:$options.redundantTags) }
            Text("预计清理 \(result.changes) 处").font(.callout)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text("清理前").font(.headline); EditorHTMLPreview(html:original,store:store).frame(height:160)
                    Divider(); Text("清理后").font(.headline); EditorHTMLPreview(html:result.text,store:store).frame(height:160)
                    DisclosureGroup("查看清理后的源码") { Text(result.text).font(.system(.body,design:.monospaced)).textSelection(.enabled) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("采用清理结果") {
                handle.apply(.init(title:"格式清理",original:original,proposed:result.text,count:result.changes,source:sourceMode,storedBaseline:storedBaseline)) { success in
                    if success { dismiss() } else { error = "原内容或编辑模式已变化，请重新预览。" }
                }
            }.disabled(result.text == original) }
        }.padding(20).frame(minWidth:640,minHeight:480).toggleStyle(.checkbox)
    }
}

struct EditorResourcesView: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    let fieldName: String
    let store: LibraryStore?
    let locate: (NSRange)->Void
    @State private var references: [EditorResourceReference] = []
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("链接与媒体检查").font(.title2.bold())
            Text("字段：" + (fieldName.isEmpty ? "当前正文" : fieldName)).font(.headline)
            Text("检查地址写法和本地图片／音频是否存在；远程网站及媒体不联网测试。定位会选中源码里的地址，方便保留周围内容后修改。").font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView() }
            Text("共 \(references.count) 项，\(references.filter(\.problem).count) 项需核对").font(.callout)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(references) { item in
                        VStack(alignment:.leading,spacing:5) {
                            Label(item.kind + " · " + item.message,systemImage:item.problem ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(item.problem ? Color.red : Color.secondary)
                            Text(item.value).font(.system(.caption,design:.monospaced)).textSelection(.enabled).lineLimit(4)
                            Button("定位到源码地址") { locate(item.range); dismiss() }.controlSize(.small)
                        }.padding(8).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
                    }
                    if references.isEmpty && !loading { Text("未找到可识别的链接或媒体引用。HTML 写法不完整时，可先使用“检查 HTML”。").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("关闭") { dismiss() } }
        }.padding(20).frame(minWidth:620,minHeight:450)
        .task {
            do {
                guard let store else { throw CocoaError(.fileReadUnknown) }
                let names = try await store.db.editorMediaNames()
                references = EditorResourceCheck.references(original) { names.contains($0) }
            } catch { self.error = "部分媒体无法检查：" + error.localizedDescription }
            loading = false
        }
    }
}

struct ParagraphDifferenceView: View {
    let rows: [ParagraphDifference.Row]
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:6) {
                ForEach(rows) { row in
                    HStack(alignment:.top,spacing:6) {
                        if row.kind != .unchanged { Text(label(row.kind)).font(.caption.bold()).foregroundStyle(color(row.kind)) }
                        Text(row.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(6).frame(maxWidth:.infinity,alignment:.leading)
                        .background(color(row.kind).opacity(row.kind == .unchanged ? 0 : 0.12),in:RoundedRectangle(cornerRadius:5))
                }
                if rows.isEmpty { Text("（无正文文字）").foregroundStyle(.secondary) }
            }
        }
    }
    private func label(_ kind: ParagraphDifference.Kind) -> String { switch kind { case .added:"新增"; case .removed:"删除"; case .modified:"改动"; case .unchanged:"" } }
    private func color(_ kind: ParagraphDifference.Kind) -> Color { switch kind { case .added:.green; case .removed:.red; case .modified:.orange; case .unchanged:.clear } }
}

/// Render inline formatting without running content scripts or loading remote resources.
struct EditorHTMLPreview: NSViewRepresentable {
    let html: String
    let store: LibraryStore?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        LocalSchemeHandler.register(on:config,store:store)
        let view = WKWebView(frame:.zero,configuration:config); view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView,context: Context) {
        guard context.coordinator.loaded != html else { return }; context.coordinator.loaded = html
        view.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: kr-media:; media-src kr-media: data:">
        <style>:root{color-scheme:light dark}body{font:15px/1.6 -apple-system;margin:8px;overflow-wrap:anywhere}img{max-width:100%}p{margin:0 0 .6em}</style></head><body>\(Markdown.html(html))</body></html>
        """,baseURL:nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}
extension AppDatabase {
    func editorMediaNames() async throws -> Set<String> {
        try await writer.read { db in Set(try String.fetchAll(db,sql:"SELECT name FROM card_media WHERE length(data)>0")) }
    }
}
