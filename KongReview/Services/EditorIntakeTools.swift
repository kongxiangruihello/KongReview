import Foundation
import AppKit
import KongReviewCore

/// Clipboard choices affect the pasted fragment, never the surrounding field.
enum EditorPasteStyle: String, CaseIterable, Identifiable {
    case keep, clean, plain
    var id: String { rawValue }
    var label: String { switch self { case .keep:"保留格式"; case .clean:"清理格式"; case .plain:"纯文字" } }
    static let defaultsKey = "editor.pasteStyle"
    /// 5.2.2：粘贴带格式的内容时是否先弹出“选择粘贴方式”（默认否：直接保留原格式粘贴）
    static let askKey = "editor.askPasteStyle"
    static var asksEveryTime: Bool { UserDefaults.standard.bool(forKey: askKey) }
}
struct EditorPasteProposal: Identifiable {
    let id = UUID()
    let original: String
    let html: String
    let plain: String
    let source: Bool
    let selection: NSRange?
    let baseline: String?
    func fragment(_ style: EditorPasteStyle) -> String {
        switch style {
        case .keep: return html
        case .clean: return EditorFormattingCleanup.clean(html,options:.init()).text
        case .plain: return plain.components(separatedBy:"\n").map { "<p>"+HTMLSourceCodec.attribute($0)+"</p>" }.joined()
        }
    }
}
struct EditorOutlineEntry: Identifiable, Equatable {
    var id: Int
    var title: String
    var level: Int
    var range: NSRange
}
enum EditorOutline {
    static func entries(_ source: String) -> [EditorOutlineEntry] {
        let ns = source as NSString
        let re = try! NSRegularExpression(pattern:#"(?is)<h([1-6])\b(?:[^>"']|"[^"]*"|'[^']*')*>(.*?)</h\1\s*>"#)
        let protected = HTMLContentTokens.protectedRanges(source)
        return re.matches(in:source,range:NSRange(location:0,length:ns.length)).filter { m in !protected.contains { NSIntersectionRange($0,m.range).length>0 } }.enumerated().map { i,m in
            .init(id:i,title:Markdown.plainText(fromHTML:ns.substring(with:m.range(at:2))).trimmingCharacters(in:.whitespacesAndNewlines),level:Int(ns.substring(with:m.range(at:1))) ?? 1,range:m.range(at:2))
        }
    }
}
struct SourceAttribution: Identifiable {
    let id = UUID()
    let original: String
    let body: String
    let citation: String
    var title: String
    var author: String
    var location: String
    var canRemove: Bool { original != body }
}
enum SourceAttributionRecognition {
    static func recognize(_ source: String) -> SourceAttribution? {
        let plain = (Markdown.looksLikeHTML(source) || Markdown.containsHTMLTag(source) ? Markdown.plainText(fromHTML:source) : source).trimmingCharacters(in:.whitespacesAndNewlines)
        let re = try! NSRegularExpression(pattern:#"(?s)(?:——|—|--)[ \t]*([^《》\n]{0,60}?)《([^《》\n]{1,160})》[ \t]*(?:[,，、]?[ \t]*((?:第?[ \t]*[0-9０-９一二三四五六七八九十百千]+(?:[ \t]*[-–—～至][ \t]*[0-9０-９一二三四五六七八九十百千]+)?[ \t]*页)|(?:[pPｐＰ][pP]?[.．]?[ \t]*[0-9０-９]+(?:[ \t]*[-––][ \t]*[0-9０-９]+)?)))?[ \t]*$"#)
        let ns = plain as NSString
        guard let m = re.firstMatch(in:plain,range:NSRange(location:0,length:ns.length)),m.range.location>0,!ns.substring(to:m.range.location).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
        let citation = ns.substring(with:m.range)
        var body = source
        let raw = source as NSString, location = raw.range(of:citation,options:.backwards)
        if location.location != NSNotFound {
            let suffix = raw.substring(from:NSMaxRange(location))
            if suffix.replacingOccurrences(of:#"(?is)</[a-z][a-z0-9]*\s*>|\s"#,with:"",options:.regularExpression).isEmpty {
                body = raw.replacingCharacters(in:location,with:"")
            }
        }
        return .init(original:source,body:body,citation:citation,title:ns.substring(with:m.range(at:2)).trimmingCharacters(in:.whitespaces),author:ns.substring(with:m.range(at:1)).trimmingCharacters(in:.whitespaces),location:m.range(at:3).location == NSNotFound ? "" : ns.substring(with:m.range(at:3)))
    }
}

extension RichEditorHandle {
    func receivePaste(html: String,plain: String,original: String,selection: NSRange? = nil,source: Bool = false) {
        let proposal = EditorPasteProposal(original:original,html:html,plain:plain,source:source,selection:selection,baseline:valueReader?())
        // 5.2.2：默认不弹窗，直接按原格式粘贴（随后照常识别末尾出处）；设置里打开“先选择粘贴方式”才弹出选择界面。
        // 直接粘贴没成功（编辑内容在这期间变了）时退回到选择界面，免得内容丢失。
        guard !EditorPasteStyle.asksEveryTime else { pasteProposal = proposal; return }
        applyPaste(proposal,style:.keep) { [weak self] success in
            guard let self else { return }
            if success { self.attributionPulse += 1 } else { self.pasteProposal = proposal }
        }
    }
    func applyPaste(_ proposal: EditorPasteProposal,style: EditorPasteStyle,completion: @escaping (Bool)->Void) {
        guard proposal.baseline == valueReader?() else { completion(false); return }
        let fragment = proposal.fragment(style)
        if proposal.source,let view = textView,view.isEditable,view.string == proposal.original,let range = proposal.selection,NSMaxRange(range)<=(view.string as NSString).length {
            view.insertText(fragment,replacementRange:range); view.window?.makeFirstResponder(view); completion(true)
        } else if !proposal.source,let webView {
            webView.evaluateJavaScript("krEditorPasteApply(\(EditorPage.jsonString(fragment)),\(EditorPage.jsonString(proposal.original)))") { result,error in completion(error == nil && (result as? Bool) == true) }
        } else { completion(false) }
    }
    func openOutline() {
        if let view = textView {
            outlineEntries = EditorOutline.entries(view.string); outlineBaseline = view.string
            outlinePosition = view.selectedRange(); showsOutline = true
        } else if let webView {
            webView.evaluateJavaScript("krEditorOutline()") { [weak self] result,_ in
                guard let self,let data = result as? [String:Any],let rows = data["headings"] as? [[String:Any]] else { return }
                self.outlineEntries = rows.enumerated().map { i,row in .init(id:i,title:row["title"] as? String ?? "",level:row["level"] as? Int ?? 1,range:NSRange(location:0,length:0)) }
                self.outlineBaseline = data["original"] as? String ?? ""; self.showsOutline = true
            }
        }
    }
    func navigateOutline(_ index: Int) {
        if let view = textView {
            guard view.string == outlineBaseline else { openOutline(); return }
            let range: NSRange
            if index == -1 { range = NSRange(location:0,length:0) }
            else if index == -2 { range = outlinePosition ?? NSRange(location:0,length:0) }
            else { guard outlineEntries.indices.contains(index) else { return }; range = outlineEntries[index].range }
            guard NSMaxRange(range)<=(view.string as NSString).length else { return }
            view.setSelectedRange(range); view.scrollRangeToVisible(range); EditorViewport.revealSelection(in:view)
        } else if let webView {
            webView.evaluateJavaScript("krEditorOutlineGo(\(index),\(EditorPage.jsonString(outlineBaseline)))") { [weak self,weak webView] result,_ in
                guard let webView else { return }
                if let box = result as? [String:Double],let y = box["y"],let height = box["height"],y.isFinite,height.isFinite {
                    EditorViewport.reveal(NSRect(x:box["x"] ?? 0,y:webView.isFlipped ? y : webView.bounds.height-y-height,width:box["width"] ?? 1,height:max(1,height)),in:webView)
                } else { self?.openOutline() }
            }
        }
    }
}
