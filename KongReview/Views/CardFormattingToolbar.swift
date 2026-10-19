import SwiftUI
import WebKit
import Observation
import KongReviewCore

/// 记忆卡面板固定工具栏与当前获得焦点的编辑区之间的连接。
@MainActor
@Observable
final class CardFormattingState {
    struct Target {
        weak var webView: WKWebView?
        var name: String
    }
    struct SourceTarget { weak var textView: HTMLSourceTextView?; var name: String }
    @ObservationIgnored private var sources: [String:SourceTarget] = [:]
    @ObservationIgnored private var targets: [String: Target] = [:]
    var activeSlot: String?
    var activeName = "先点击要编辑的字段"
    var showsLink = false
    var linkURL = ""
    var linkError: String?
    var hasTarget: Bool { activeSlot.flatMap { sources[$0]?.textView } != nil || activeSlot.flatMap { targets[$0]?.webView } != nil }

    func attach(slot: String, name: String, webView: WKWebView) {
        targets[slot] = Target(webView: webView, name: name)
    }
    func detach(slot: String, webView: WKWebView) {
        guard targets[slot]?.webView === webView else { return }
        targets[slot] = nil
        if activeSlot == slot { activeSlot = nil; activeName = "先点击要编辑的字段"; showsLink = false }
    }
    func attach(slot: String, name: String, textView: HTMLSourceTextView) { sources[slot] = .init(textView:textView,name:name) }
    func detach(slot: String, textView: HTMLSourceTextView) {
        guard sources[slot]?.textView === textView else { return }; sources[slot] = nil
        if activeSlot == slot { activeSlot = nil; activeName = "先点击要编辑的字段"; showsLink = false }
    }
    func activate(_ slot: String) {
        if let target = sources[slot], target.textView != nil { activeSlot = slot; activeName = "HTML 源码：" + target.name; return }
        guard let target = targets[slot], target.webView != nil else { return }
        activeSlot = slot
        activeName = "正在编辑：" + target.name
    }
    /// Deliver input changes before preserving the draft or opening a comparison.
    func flushEditors(_ completion: @escaping (Bool)->Void) {
        let views = targets.values.compactMap(\.webView)
        guard !views.isEmpty else { completion(true); return }
        var remaining = views.count,success = true
        for view in views {
            view.evaluateJavaScript("typeof krFlush === 'function' ? (krFlush(),true) : false") { value,error in
                if error != nil || value as? Bool != true { success = false }
                remaining -= 1
                if remaining == 0 { completion(success) }
            }
        }
    }
    func command(_ command: String) {
        if let view = activeSlot.flatMap({ sources[$0]?.textView }) { view.applyHTML(command); return }
        guard let view = activeSlot.flatMap({ targets[$0]?.webView }) else { return }
        view.window?.makeFirstResponder(view)
        view.evaluateJavaScript("window.krExternalCommand(\(EditorPage.jsonString(command)));", completionHandler: nil)
    }
    func applyLink() {
        let text = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = text.isEmpty || text.hasPrefix("#") || text.contains(":") ? text : "https://" + text
        if !url.isEmpty && !url.hasPrefix("#") {
            guard let scheme = URL(string: url)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else {
                linkError = "请输入网页地址或邮件地址。"; return
            }
        }
        if let view = activeSlot.flatMap({ sources[$0]?.textView }) { view.insertHTMLLink(url); showsLink = false; linkError = nil; return }
        guard let view = activeSlot.flatMap({ targets[$0]?.webView }) else { return }
        view.window?.makeFirstResponder(view)
        view.evaluateJavaScript("window.krExternalLink(\(EditorPage.jsonString(url)));", completionHandler: nil)
        showsLink = false
        linkError = nil
    }
}

struct CardFormattingToolbar: View {
    let state: CardFormattingState
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.activeName).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    command("B", "bold", help: "插入 <strong> 标签 ⌘B")
                    command("I", "italic", help: "插入 <em> 标签 ⌘I")
                    command("删除线", "strike", help: "删除线 ⇧⌘X")
                    command("代码", "code", help: "行内代码 ⌘E")
                    Divider().frame(height: 18)
                    command("H1", "h1", help: "一级标题")
                    command("H2", "h2", help: "二级标题")
                    command("正文", "p", help: "正文段落")
                    command("• 列表", "ul", help: "项目列表")
                    command("1. 列表", "ol", help: "编号列表")
                    command("引用", "quote", help: "引用")
                    Button("链接") { state.linkURL = ""; state.linkError = nil; state.showsLink = true }
                    command("分隔线", "hr", help: "插入分隔线")
                    command("清除格式", "clear", help: "清除所选文字格式")
                }
                .controlSize(.small)
                .disabled(!state.hasTarget)
            }
            if state.showsLink {
                HStack {
                    TextField("链接地址；留空可移除链接", text: Bindable(state).linkURL)
                        .textFieldStyle(.roundedBorder).onSubmit { state.applyLink() }
                    Button("应用") { state.applyLink() }
                    Button("取消") { state.showsLink = false }
                }
                if let error = state.linkError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
    }
    private func command(_ title: String, _ value: String, help: String) -> some View {
        Button(title) { state.command(value) }.help(help)
    }
}

/// 原生工具栏夺走焦点时保留网页里的选区；命令始终作用于当前字段。
enum CardFormattingScript {
    static let source = #"""
    (function () {
      var ed = document.getElementById('ed'); if (!ed) return;
      var saved = null;
      function remember() {
        var s = window.getSelection();
        if (s && s.rangeCount && ed.contains(s.getRangeAt(0).commonAncestorContainer)) saved = s.getRangeAt(0).cloneRange();
      }
      function restore() {
        ed.focus();
        var s = window.getSelection(); if (!s) return;
        if (saved && ed.contains(saved.commonAncestorContainer)) { s.removeAllRanges(); s.addRange(saved.cloneRange()); }
      }
      document.addEventListener('selectionchange', remember);
      ed.addEventListener('keyup', remember);
      ed.addEventListener('mouseup', remember);
      ed.addEventListener('blur', remember);
      ed.addEventListener('keydown', function (e) {
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && (e.key || '').toLowerCase() === 'k') {
          e.preventDefault(); e.stopImmediatePropagation(); remember();
          try { window.webkit.messageHandlers.krEditor.postMessage({type:'external-link'}); } catch (_) {}
        }
      }, true);
      ed.addEventListener('focus', function () {
        try { window.webkit.messageHandlers.krEditor.postMessage({type:'focus'}); } catch (_) {}
      });
      window.krExternalCommand = function (cmd) { restore(); window.krCommand(cmd); remember(); };
      window.krExternalLink = function (url) {
        restore();
        if (!url) document.execCommand('unlink', false, null);
        else if (/^(https?:|mailto:|#)/i.test(url)) {
          if (window.getSelection().isCollapsed) {
            var a = document.createElement('a'); a.href = url; a.textContent = url;
            document.execCommand('insertHTML', false, a.outerHTML);
          } else document.execCommand('createLink', false, url);
        }
        ed.dispatchEvent(new Event('input', {bubbles:true})); remember();
      };
    })();
    """#
}
