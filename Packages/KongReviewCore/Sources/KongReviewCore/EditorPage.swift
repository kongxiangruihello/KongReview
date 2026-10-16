import Foundation

// MARK: - 所见即所得编辑器（1.2）

/// 编辑器保存的格式
public enum RichEditorMode: String, Sendable {
    /// 摘录原文、译文、按语：一律存为 Markdown（与显示用的 Markdown.richHTML 对应）
    case markdown
    /// 记忆卡：能用 Markdown 表达时存 Markdown；原来就是 HTML（如从 Anki 导入）或用到下划线、上下标、表格时存 HTML
    case card
}

/// 编辑器的字体样式
public enum RichEditorFont: String, Sendable {
    case highlight   // 摘录原文：宋体大字
    case body        // 一般正文
    case note        // 按语：小一号
}

/// 编辑器网页：contenteditable + 工具条 + 快捷键 + 粘贴清理 + DOM → Markdown。
///
/// 应用里由 WKWebView 载入（见 RichEditor.swift），与 Swift 通过 `krEditor` 消息通道交互：
/// `{type: "change", value}` 内容变化（已转成要保存的文本）、`{type: "height", value}` 内容高度、
/// `{type: "submit"}` ⌘↩、`{type: "cancel"}` Esc。Swift 调用 `krSetContent(html, originalHTML)`、`krFocus()`、`krGetValue()`。
///
/// 快捷键：⌘B 粗体、⌘I 斜体、⇧⌘X 删除线、⌘E 行内代码、⌘K 链接、⌘1/⌘2/⌘3 标题、⌘0 正文、
/// ⇧⌘8 项目符号列表、⇧⌘7 编号列表、⇧⌘. 引用、⌘↩ 保存、Esc 取消。
/// 也可以直接敲 Markdown：行首“# ”“## ”“- ”“1. ”“> ”自动变成标题、列表、引用，“**粗体**”“*斜体*”“`代码`”“~~删除~~”敲完即变；
/// 单独一行“---”回车得到分隔线。
/// 粘贴：保留粗体、斜体、删除线、标题、列表、引用、链接、网络图片；字体、字号、颜色等其余样式去掉。
public enum EditorPage {

    /// 编辑器初始显示用的 HTML，以及原文是否本来就是 HTML
    public static func displayHTML(for text: String, mode: RichEditorMode) -> (html: String, originalHTML: Bool) {
        let isHTML = Markdown.looksLikeHTML(text)
        let html: String
        switch mode {
        case .markdown: html = Markdown.richHTML(text)
        case .card: html = Markdown.html(text)
        }
        return (rewriteImages(html), isHTML)
    }

    /// 图片地址改成编辑器里能显示的地址，原地址存在 data-kr-src 里，保存时还原：
    /// 网络图片 → kr-img://（本地缓存代理），Anki 媒体文件名 → kr-media://media/文件名
    public static func rewriteImages(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc\s*=\s*)"([^"]*)""#, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let prefix = ns.substring(with: m.range(at: 1))
            let raw = ns.substring(with: m.range(at: 2))
            let src = raw.replacingOccurrences(of: "&amp;", with: "&")
            let lower = src.lowercased()
            let display: String
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                display = ArticleImages.proxied(src, referer: "")
            } else if src.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) == nil && !src.isEmpty {
                display = "kr-media://media/" + (src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src)
            } else {
                display = raw
            }
            if display == raw {
                out += ns.substring(with: m.range)
            } else {
                out += prefix + "\"" + display + "\" data-kr-src=\"" + attributeEscape(src) + "\""
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func attributeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// JSON 字符串字面量（应用调用 krSetContent 时用）
    public static func jsonString(_ s: String) -> String { jsString(s) }

    /// JSON 字符串字面量（嵌进页面脚本用）
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        var t = String(decoding: data, as: UTF8.self)
        t.removeFirst(); t.removeLast()
        // 防止正文里的 </script> 提前结束脚本
        return t.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// 完整页面
    public static func page(text: String, mode: RichEditorMode, font: RichEditorFont = .body,
                            placeholder: String = "", toolbar: Bool = true, autoHeight: Bool = false,
                            tabOut: Bool = false) -> String {
        let (html, isHTML) = displayHTML(for: text, mode: mode)
        let fontCSS: String
        switch font {
        case .highlight: fontCSS = #"font: 20px/1.75 "Songti SC", "STSong", serif;"#
        case .body: fontCSS = #"font: 15px/1.7 -apple-system, "PingFang SC", sans-serif;"#
        case .note: fontCSS = #"font: 14px/1.7 -apple-system, "PingFang SC", sans-serif;"#
        }
        let config = """
        {"mode": \(jsString(mode.rawValue)), "originalHTML": \(isHTML), "placeholder": \(jsString(placeholder)),
         "toolbar": \(toolbar), "autoHeight": \(autoHeight), "tabOut": \(tabOut)}
        """
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
            + css.replacingOccurrences(of: "/*FONT*/", with: fontCSS)
            + (autoHeight ? "html, body { overflow: hidden; }" : "")
            + "</style></head><body" + (autoHeight ? "" : " class=\"bounded\"") + ">"
            + toolbarHTML(toolbar)
            + "<div id=\"ed\" contenteditable=\"true\" spellcheck=\"false\"></div>"
            + "<div id=\"linkbox\" hidden><input id=\"linkurl\" placeholder=\"链接地址（https://…），回车确定，Esc 取消\"></div>"
            + "<script>window.__krCfg = \(config); window.__krInitial = \(jsString(html));</script>"
            + "<script>" + script + "</script></body></html>"
    }

    static func toolbarHTML(_ show: Bool) -> String {
        guard show else { return "" }
        // data-cmd 由脚本处理；mousedown 时阻止默认动作，选区不会丢
        let buttons: [(String, String, String)] = [
            ("bold", "<b>B</b>", "粗体 ⌘B"),
            ("italic", "<i>I</i>", "斜体 ⌘I"),
            ("strike", "<s>S</s>", "删除线 ⇧⌘X"),
            ("code", "<span class=\"mono\">&lt;/&gt;</span>", "行内代码 ⌘E"),
            ("|", "", ""),
            ("h1", "H1", "一级标题 ⌘1"),
            ("h2", "H2", "二级标题 ⌘2"),
            ("h3", "H3", "三级标题 ⌘3"),
            ("p", "正文", "正文 ⌘0"),
            ("|", "", ""),
            ("ul", "• 列表", "项目符号列表 ⇧⌘8"),
            ("ol", "1. 列表", "编号列表 ⇧⌘7"),
            ("quote", "❝ 引用", "引用 ⇧⌘."),
            ("link", "链接", "链接 ⌘K"),
            ("hr", "分隔线", "分隔线"),
            ("|", "", ""),
            ("clear", "清除格式", "清除所选文字的格式"),
        ]
        var s = "<div id=\"tb\">"
        for (cmd, label, tip) in buttons {
            if cmd == "|" { s += "<span class=\"sep\"></span>"; continue }
            s += "<button type=\"button\" tabindex=\"-1\" data-cmd=\"\(cmd)\" title=\"\(tip)\">\(label)</button>"
        }
        return s + "</div>"
    }

    static let css = #"""
    :root { color-scheme: light dark; --text: #1F1E1C; --sub: #8A857C; --accent: #3B73EF; --hair: rgba(0,0,0,.09);
            --bar: rgba(246,244,239,.92); --btn: rgba(0,0,0,.05); --code: rgba(128,128,128,.14); }
    @media (prefers-color-scheme: dark) {
      :root { --text: #EDEBE6; --sub: #9C978E; --accent: #5B8CF5; --hair: rgba(255,255,255,.10);
              --bar: rgba(41,40,38,.92); --btn: rgba(255,255,255,.07); }
    }
    html, body { margin: 0; padding: 0; background: transparent; }
    body { color: var(--text); -webkit-font-smoothing: antialiased; }
    html:has(body.bounded), body.bounded { height: 100%; overflow: hidden; }
    body.bounded { display: flex; flex-direction: column; }
    body.bounded #tb { flex: 0 0 auto; }
    body.bounded #ed { flex: 1 1 auto; min-height: 0; overflow: auto; overscroll-behavior: contain; }
    #tb { position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; align-items: center; gap: 2px;
          padding: 4px 6px; background: var(--bar); border-bottom: 1px solid var(--hair);
          -webkit-backdrop-filter: blur(8px); font: 12px -apple-system, "PingFang SC", sans-serif; }
    #tb button { border: none; background: transparent; color: var(--text); font: inherit; padding: 3px 7px;
                 border-radius: 5px; cursor: pointer; line-height: 16px; min-width: 24px; }
    #tb button:hover { background: var(--btn); }
    #tb button.on { background: var(--btn); color: var(--accent); }
    #tb .mono { font: 11px ui-monospace, Menlo, monospace; }
    #tb .sep { width: 1px; height: 14px; background: var(--hair); margin: 0 4px; }
    #ed { /*FONT*/ position: relative; outline: none; padding: 8px 10px 10px; min-height: 1.7em; word-wrap: break-word; caret-color: var(--accent); }
    #ed.empty::before { content: attr(data-placeholder); color: var(--sub); position: absolute; pointer-events: none; }
    #ed p { margin: 0 0 .55em; } #ed p:last-child { margin-bottom: 0; }
    #ed h1 { font-size: 1.55em; margin: .3em 0 .35em; } #ed h2 { font-size: 1.3em; margin: .3em 0 .35em; }
    #ed h3, #ed h4, #ed h5, #ed h6 { font-size: 1.12em; margin: .3em 0 .3em; }
    #ed ul, #ed ol { margin: .2em 0 .55em; padding-left: 1.5em; }
    #ed blockquote { margin: .3em 0; padding-left: .8em; border-left: 3px solid rgba(128,128,128,.45); color: var(--sub); }
    #ed code { font: .86em ui-monospace, Menlo, monospace; background: var(--code); padding: 0 .2em; border-radius: 3px; }
    #ed pre { background: var(--code); padding: 8px 10px; border-radius: 6px; white-space: pre-wrap; }
    #ed pre code { background: none; padding: 0; }
    #ed img { max-width: 100%; height: auto; border-radius: 4px; }
    #ed a { color: var(--accent); cursor: text; }
    #ed hr { border: none; border-top: 1px solid rgba(128,128,128,.35); margin: .8em 0; }
    #ed table { border-collapse: collapse; } #ed td, #ed th { border: 1px solid rgba(128,128,128,.35); padding: 3px 6px; }
    #linkbox { position: fixed; left: 8px; right: 8px; top: 34px; z-index: 3; }
    #linkbox input { width: 100%; box-sizing: border-box; font: 13px -apple-system, sans-serif; padding: 6px 8px;
                     border-radius: 6px; border: 1px solid var(--accent); background: Canvas; color: CanvasText; outline: none; }
    """#

    // 页面脚本（纯 JavaScript，不依赖外部库；在 Chromium 里有自动化测试）
    static let script = #"""
    (function () {
      'use strict';
      var cfg = window.__krCfg || { mode: 'markdown' };
      var ed = document.getElementById('ed');
      var tb = document.getElementById('tb');
      var linkbox = document.getElementById('linkbox');
      var linkurl = document.getElementById('linkurl');
      var originalHTML = !!cfg.originalHTML;

      function post(m) {
        try { window.webkit.messageHandlers.krEditor.postMessage(m); }
        catch (e) { (window.__krLog = window.__krLog || []).push(m); }
      }

      try { document.execCommand('defaultParagraphSeparator', false, 'p'); } catch (e) {}
      try { document.execCommand('styleWithCSS', false, false); } catch (e) {}

      // ---------------- 清理（粘贴、拖入之后） ----------------

      var DROP = { SCRIPT:1, STYLE:1, META:1, LINK:1, TITLE:1, HEAD:1, NOSCRIPT:1, IFRAME:1, OBJECT:1, EMBED:1,
                   SVG:1, CANVAS:1, VIDEO:1, AUDIO:1, BUTTON:1, INPUT:1, SELECT:1, TEXTAREA:1, FORM:1, TEMPLATE:1 };
      var CONTAINER = { DIV:1, SECTION:1, ARTICLE:1, HEADER:1, FOOTER:1, MAIN:1, ASIDE:1, NAV:1, FIGURE:1,
                        FIGCAPTION:1, ADDRESS:1, DL:1, DD:1, DT:1, CENTER:1 };
      var BLOCK = { P:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, UL:1, OL:1, LI:1, BLOCKQUOTE:1, PRE:1, HR:1,
                    TABLE:1, THEAD:1, TBODY:1, TR:1, TD:1, TH:1, DIV:1, SECTION:1, ARTICLE:1, HEADER:1, FOOTER:1,
                    MAIN:1, ASIDE:1, NAV:1, FIGURE:1, FIGCAPTION:1, ADDRESS:1, DL:1, DD:1, DT:1, CENTER:1 };
      var KEEP = { P:[], H1:[], H2:[], H3:[], H4:[], H5:[], H6:[], UL:[], OL:[], LI:[], BLOCKQUOTE:[], PRE:[], HR:[],
                   BR:[], B:[], STRONG:[], I:[], EM:[], S:[], DEL:[], STRIKE:[], CODE:[],
                   A:['href'], IMG:['src', 'alt', 'data-kr-src'] };
      // 记忆卡另外保留（存成 HTML）
      var KEEP_CARD = { U:[], SUB:[], SUP:[], TABLE:[], THEAD:[], TBODY:[], TR:[], TD:['colspan','rowspan'],
                        TH:['colspan','rowspan'] };

      function keepAttrs(tag) {
        if (KEEP[tag]) return KEEP[tag];
        if (cfg.mode === 'card' && KEEP_CARD[tag]) return KEEP_CARD[tag];
        return null;
      }
      function remove(n) { if (n.parentNode) n.parentNode.removeChild(n); }
      function unwrap(n) {
        var p = n.parentNode; if (!p) return;
        while (n.firstChild) p.insertBefore(n.firstChild, n);
        p.removeChild(n);
      }
      function rename(n, tag) {
        var e = document.createElement(tag);
        while (n.firstChild) e.appendChild(n.firstChild);
        n.parentNode.replaceChild(e, n);
        return e;
      }
      function hasBlockChild(n) {
        for (var c = n.firstChild; c; c = c.nextSibling) if (c.nodeType === 1 && BLOCK[c.tagName]) return true;
        return false;
      }
      function prop(style, name) {
        var m = new RegExp('(?:^|;)\\s*' + name + '\\s*:\\s*([^;]+)', 'i').exec(style || '');
        return m ? m[1].trim().toLowerCase() : '';
      }
      function okURL(u) { return /^(https?:|mailto:)/i.test(u || ''); }
      function okImage(img) {
        var s = img.getAttribute('data-kr-src') || img.getAttribute('src') || '';
        return /^(https?:|kr-media:|kr-img:)/i.test(s) || (!!img.getAttribute('data-kr-src'));
      }

      function cleanNode(n) {
        if (n.nodeType === 3) return;
        if (n.nodeType !== 1) { remove(n); return; }
        var tag = n.tagName.toUpperCase();
        if (DROP[tag]) { remove(n); return; }
        var style = n.getAttribute('style') || '';
        if (/mso-list\s*:\s*ignore/i.test(style)) { remove(n); return; }
        if (tag === 'TABLE' && cfg.mode !== 'card') { tableToParagraphs(n); return; }
        var kids = Array.prototype.slice.call(n.childNodes);
        for (var i = 0; i < kids.length; i++) cleanNode(kids[i]);
        if (!n.parentNode) return;
        if (tag.indexOf(':') >= 0) { unwrap(n); return; }      // Word 的 <o:p> 等
        if (CONTAINER[tag]) {
          if (hasBlockChild(n) || n.parentNode !== ed && !isRootish(n.parentNode)) { unwrap(n); }
          else { finish(rename(n, 'P'), 'P'); }
          return;
        }
        // 用样式表达的格式（网页、Word、WebKit 粘贴时生成的 span）
        var fw = prop(style, 'font-weight'), fs = prop(style, 'font-style');
        var td = prop(style, 'text-decoration') + ' ' + prop(style, 'text-decoration-line');
        var bold = /bold|^[6-9]00/.test(fw), notBold = /normal|^[1-4]00/.test(fw);
        var italic = /italic|oblique/.test(fs), strike = /line-through/.test(td);
        if ((tag === 'B' || tag === 'STRONG') && notBold) { n = rename(n, 'SPAN'); tag = 'SPAN'; }
        if (tag === 'SPAN' || tag === 'FONT' || tag === 'MARK' || tag === 'SMALL' || tag === 'BIG' || tag === 'LABEL' ||
            (tag === 'U' && cfg.mode !== 'card') || ((tag === 'SUB' || tag === 'SUP') && cfg.mode !== 'card')) {
          // 原本就是 HTML 的记忆卡（如 Anki 的彩色字）保留文字颜色
          if (cfg.mode === 'card' && originalHTML && (tag === 'SPAN' || tag === 'FONT')) {
            var color = prop(style, 'color') || (n.getAttribute('color') || '');
            var bg = prop(style, 'background-color');
            if (color || bg || bold || italic || strike) {
              var keep = (color ? 'color: ' + color + ';' : '') + (bg ? ' background-color: ' + bg + ';' : '') +
                         (bold ? ' font-weight: bold;' : '') + (italic ? ' font-style: italic;' : '') +
                         (strike ? ' text-decoration: line-through;' : '');
              var sp = tag === 'SPAN' ? n : rename(n, 'SPAN');
              Array.prototype.slice.call(sp.attributes).forEach(function (a) { sp.removeAttribute(a.name); });
              sp.setAttribute('style', keep.trim());
              return;
            }
          }
          var wraps = [];
          if (bold) wraps.push('B');
          if (italic) wraps.push('I');
          if (strike) wraps.push('S');
          if (!wraps.length) { unwrap(n); return; }
          var outer = document.createElement(wraps[0]), inner = outer;
          for (var w = 1; w < wraps.length; w++) { var e = document.createElement(wraps[w]); inner.appendChild(e); inner = e; }
          while (n.firstChild) inner.appendChild(n.firstChild);
          n.parentNode.replaceChild(outer, n);
          return;
        }
        if (tag === 'A' && !okURL(n.getAttribute('href'))) { unwrap(n); return; }
        if (tag === 'IMG' && !okImage(n)) { remove(n); return; }
        var allowed = keepAttrs(tag);
        if (!allowed) {
          if (BLOCK[tag] && !hasBlockChild(n) && (n.parentNode === ed || isRootish(n.parentNode))) finish(rename(n, 'P'), 'P');
          else unwrap(n);
          return;
        }
        finish(n, tag);
      }
      var cleanRoot = null;   // 正在清理的根（编辑区或粘贴内容的临时容器）
      function isRootish(p) { return p && (p.nodeType === 11 || p === cleanRoot); }
      function finish(n, tag) {
        var allowed = keepAttrs(tag) || [];
        Array.prototype.slice.call(n.attributes).forEach(function (a) {
          if (allowed.indexOf(a.name.toLowerCase()) < 0) n.removeAttribute(a.name);
        });
        // 空的格式标签去掉
        if ({B:1, STRONG:1, I:1, EM:1, S:1, DEL:1, STRIKE:1, CODE:1, A:1, U:1, SUB:1, SUP:1}[tag] &&
            !n.textContent && !n.querySelector('img')) remove(n);
      }
      function tableToParagraphs(t) {
        var frag = document.createDocumentFragment(), made = [];
        Array.prototype.slice.call(t.querySelectorAll('tr')).forEach(function (tr) {
          var p = document.createElement('p');
          var cells = Array.prototype.slice.call(tr.children);
          cells.forEach(function (c, i) {
            if (i) p.appendChild(document.createTextNode(' '));
            while (c.firstChild) p.appendChild(c.firstChild);
          });
          frag.appendChild(p); made.push(p);
        });
        t.parentNode.replaceChild(frag, t);
        made.forEach(function (p) { Array.prototype.slice.call(p.childNodes).forEach(cleanNode); });
      }
      // Word 的列表段落（class 含 MsoListParagraph）→ 真正的列表
      function wordLists(root) {
        var ps = Array.prototype.slice.call(root.querySelectorAll('p'));
        ps.forEach(function (p) {
          if (!/MsoListParagraph/i.test(p.className || '') || !p.parentNode) return;
          var marker = (p.textContent || '').trim();
          var ordered = /^\(?\d+[.)、]/.test(marker);
          var prev = p.previousElementSibling;
          var list;
          if (prev && prev.getAttribute && prev.getAttribute('data-kr-wordlist') === (ordered ? 'ol' : 'ul')) list = prev;
          else {
            list = document.createElement(ordered ? 'ol' : 'ul');
            list.setAttribute('data-kr-wordlist', ordered ? 'ol' : 'ul');
            p.parentNode.insertBefore(list, p);
          }
          var li = document.createElement('li');
          while (p.firstChild) li.appendChild(p.firstChild);
          list.appendChild(li);
          remove(p);
        });
        Array.prototype.slice.call(root.querySelectorAll('[data-kr-wordlist]')).forEach(function (l) {
          l.removeAttribute('data-kr-wordlist');
        });
      }
      // 根上的零散行内内容包进段落
      function normalizeRoot(root) {
        var run = null;
        Array.prototype.slice.call(root.childNodes).forEach(function (c) {
          var block = c.nodeType === 1 && BLOCK[c.tagName];
          if (block) { run = null; return; }
          if (c.nodeType === 3 && !c.data.trim() && !run) { remove(c); return; }
          if (c.nodeType === 1 && c.tagName === 'BR' && !run) { remove(c); return; }
          if (!run) { run = document.createElement('p'); root.insertBefore(run, c); }
          run.appendChild(c);
        });
      }
      function cleanAll() {
        cleanRoot = ed;
        wordLists(ed);
        Array.prototype.slice.call(ed.childNodes).forEach(cleanNode);
        normalizeRoot(ed);
        cleanRoot = null;
        if (!ed.firstChild) ed.innerHTML = '<p><br></p>';
      }
      // 剪贴板里的 HTML 先在临时容器里清理，再插入（Word 的列表标记、样式表等在插入前处理掉）
      function cleanPastedHTML(html) {
        var doc = new DOMParser().parseFromString(html, 'text/html');
        var box = doc.body || doc.documentElement;
        cleanRoot = box;
        wordLists(box);
        Array.prototype.slice.call(box.childNodes).forEach(cleanNode);
        cleanRoot = null;
        return box.innerHTML;
      }
      function pasteHTML(html) {
        var clean = cleanPastedHTML(html);
        if (clean.trim()) exec('insertHTML', clean);
        cleanAll();
        changed();
      }

      // ---------------- DOM → Markdown ----------------

      var lossy = false;
      function srcOf(img) {
        return img.getAttribute('data-kr-src') || img.getAttribute('src') || '';
      }
      function wrapInline(s, mark) {
        var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(s);
        if (!m[2]) return s;
        return m[1] + mark + m[2] + mark + m[3];
      }
      function inline(n) {
        if (n.nodeType === 3) return n.data.replace(/ /g, ' ').replace(/​/g, '');
        if (n.nodeType !== 1) return '';
        var tag = n.tagName, inner = '';
        if (tag === 'BR') return '\n';
        if (tag === 'IMG') return '![' + (n.getAttribute('alt') || '') + '](' + srcOf(n) + ')';
        if (tag === 'CODE' && n.parentNode && n.parentNode.tagName !== 'PRE') return '`' + n.textContent + '`';
        for (var c = n.firstChild; c; c = c.nextSibling) inner += inline(c);
        switch (tag) {
          case 'B': case 'STRONG': return wrapInline(inner, '**');
          case 'I': case 'EM': return wrapInline(inner, '*');
          case 'S': case 'DEL': case 'STRIKE': return wrapInline(inner, '~~');
          case 'A':
            var href = n.getAttribute('href') || '';
            return /^https?:/i.test(href) && inner.trim() ? '[' + inner + '](' + href + ')' : inner;
          case 'U': case 'SUB': case 'SUP': case 'SPAN': case 'FONT': lossy = true; return inner;
          default:
            if (BLOCK[tag]) { lossy = true; return inner + '\n'; }
            return inner;
        }
      }
      function trimLines(s) { return s.replace(/[ \t]+\n/g, '\n').replace(/\n+$/, '').replace(/^\n+/, '').replace(/[ \t]+$/, ''); }
      function inlineOf(el) {
        var s = '';
        for (var c = el.firstChild; c; c = c.nextSibling) s += inline(c);
        return trimLines(s);
      }
      function blocks(el, out) {
        var run = '';
        function flushRun() { var t = trimLines(run); if (t.trim()) out.push(t); run = ''; }
        for (var c = el.firstChild; c; c = c.nextSibling) {
          if (c.nodeType === 1 && BLOCK[c.tagName]) { flushRun(); block(c, out); }
          else run += inline(c);
        }
        flushRun();
      }
      function listItems(list, ordered, out, depth) {
        var i = 1, lines = [];
        for (var li = list.firstChild; li; li = li.nextSibling) {
          if (li.nodeType !== 1) continue;
          if (li.tagName === 'UL' || li.tagName === 'OL') { lossy = true; var sub = []; listItems(li, li.tagName === 'OL', sub, depth + 1); lines = lines.concat(sub); continue; }
          var parts = [], nested = [];
          for (var c = li.firstChild; c; c = c.nextSibling) {
            if (c.nodeType === 1 && (c.tagName === 'UL' || c.tagName === 'OL')) { lossy = true; listItems(c, c.tagName === 'OL', nested, depth + 1); }
            else if (c.nodeType === 1 && BLOCK[c.tagName]) { parts.push(inlineOf(c)); }
            else parts.push(inline(c));
          }
          var text = parts.join(' ').replace(/\s*\n\s*/g, ' ').trim();
          if (text) lines.push((ordered ? (i++) + '. ' : '- ') + text);
          lines = lines.concat(nested);
        }
        if (lines.length) out.push(lines.join('\n'));
      }
      function block(el, out) {
        var tag = el.tagName, t;
        if (/^H[1-6]$/.test(tag)) {
          t = inlineOf(el).replace(/\n+/g, ' ').trim();
          if (t) out.push(new Array(+tag[1] + 1).join('#') + ' ' + t);
          return;
        }
        switch (tag) {
          case 'P': case 'DIV': case 'TD': case 'TH': case 'DD': case 'DT': case 'FIGCAPTION':
            if (hasBlockChild(el)) { blocks(el, out); return; }
            t = inlineOf(el); if (t.trim()) out.push(t); return;
          case 'UL': case 'OL': listItems(el, tag === 'OL', out, 0); return;
          case 'LI': t = inlineOf(el).replace(/\n+/g, ' ').trim(); if (t) out.push('- ' + t); return;
          case 'BLOCKQUOTE':
            var inner = [];
            if (hasBlockChild(el)) blocks(el, inner); else { t = inlineOf(el); if (t.trim()) inner.push(t); }
            var lines = [];
            inner.forEach(function (b) { b.split('\n').forEach(function (l) { lines.push('> ' + l.replace(/^#+\s+/, '').replace(/^(- |\d+\. )/, '')); }); });
            if (lines.length) out.push(lines.join('\n'));
            return;
          case 'PRE': out.push('```\n' + el.textContent.replace(/\n$/, '') + '\n```'); return;
          case 'HR': out.push('---'); return;
          case 'TABLE': case 'THEAD': case 'TBODY': case 'TR':
            lossy = true; blocks(el, out); return;
          default: blocks(el, out); return;
        }
      }
      function toMarkdown(root) {
        lossy = false;
        var out = [];
        blocks(root, out);
        return out.join('\n\n');
      }
      function cleanHTML(root) {
        var c = root.cloneNode(true);
        Array.prototype.slice.call(c.querySelectorAll('img')).forEach(function (img) {
          var s = img.getAttribute('data-kr-src');
          if (s) { img.setAttribute('src', s); img.removeAttribute('data-kr-src'); }
        });
        // 去掉末尾的空段落
        while (c.lastChild && (c.lastChild.nodeType === 3 && !c.lastChild.data.trim() ||
               c.lastChild.nodeType === 1 && c.lastChild.tagName === 'P' && !c.lastChild.textContent.trim() && !c.lastChild.querySelector('img'))) {
          c.removeChild(c.lastChild);
        }
        return c.innerHTML;
      }
      function value() {
        var md = toMarkdown(ed);
        if (cfg.mode === 'card' && (originalHTML || lossy)) return cleanHTML(ed);
        return md;
      }

      // ---------------- 变化、高度、占位 ----------------

      var timer = null, lastSent = null;
      function updateEmpty() {
        var empty = !ed.textContent.trim() && !ed.querySelector('img,hr');
        ed.classList.toggle('empty', empty);
        if (empty && cfg.placeholder) ed.setAttribute('data-placeholder', cfg.placeholder);
      }
      function sendNow() {
        clearTimeout(timer); timer = null;
        var v = value();
        if (v !== lastSent) { lastSent = v; post({ type: 'change', value: v }); }
      }
      // 每次改动立即把结果交给应用（摘录都不长，转换很快；这样按 ⌘↩ 保存时不会丢掉最后几个字）
      function changed() {
        updateEmpty(); updateToolbar();
        sendNow();
      }
      function reportHeight() {
        if (!cfg.autoHeight) return;
        // 1.8：量内容本身（工具栏 + 编辑区）的高度。以前取 documentElement.scrollHeight，
        // 它不会小于网页视图当前的高度，所以编辑器只会变高、删了内容也缩不回去
        var h = Math.ceil(document.body.getBoundingClientRect().height);
        if (h !== lastHeight) { lastHeight = h; post({ type: 'height', value: h }); }
      }
      var lastHeight = -1;
      if (window.ResizeObserver) { var ro = new ResizeObserver(reportHeight); ro.observe(document.body); ro.observe(ed); }

      // ---------------- 命令 ----------------

      function inBlock(tag) {
        var s = window.getSelection(); if (!s.rangeCount) return null;
        var n = s.anchorNode;
        while (n && n !== ed) { if (n.nodeType === 1 && n.tagName === tag) return n; n = n.parentNode; }
        return null;
      }
      function currentBlock() {
        var s = window.getSelection(); if (!s.rangeCount) return null;
        var n = s.anchorNode;
        while (n && n !== ed) { if (n.nodeType === 1 && BLOCK[n.tagName] && n.tagName !== 'UL' && n.tagName !== 'OL') return n; n = n.parentNode; }
        return null;
      }
      function escapeHTML(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
      function exec(cmd, arg) { document.execCommand(cmd, false, arg); }
      function block_(tag) {
        var b = currentBlock();
        if (b && b.tagName === tag.toUpperCase()) exec('formatBlock', '<p>');
        else exec('formatBlock', '<' + tag + '>');
      }
      var savedRange = null;
      function command(cmd) {
        ed.focus();
        switch (cmd) {
          case 'bold': exec('bold'); break;
          case 'italic': exec('italic'); break;
          case 'strike': exec('strikeThrough'); break;
          case 'code':
            var s = window.getSelection();
            var c = inBlock('CODE');
            if (c) { var t = document.createTextNode(c.textContent); c.parentNode.replaceChild(t, c); }
            else if (s.rangeCount && !s.isCollapsed) exec('insertHTML', '<code>' + escapeHTML(s.toString()) + '</code>');
            break;
          case 'h1': case 'h2': case 'h3': block_(cmd); break;
          case 'p': exec('formatBlock', '<p>'); break;
          case 'ul': exec('insertUnorderedList'); break;
          case 'ol': exec('insertOrderedList'); break;
          case 'quote':
            if (inBlock('BLOCKQUOTE')) exec('formatBlock', '<p>'); else exec('formatBlock', '<blockquote>');
            break;
          case 'hr': exec('insertHorizontalRule'); break;
          case 'clear':
            exec('removeFormat');
            var a = inBlock('A'); if (a) exec('unlink');
            break;
          case 'link': openLink(); return;
        }
        changed();
      }
      function openLink() {
        var s = window.getSelection();
        if (!s.rangeCount) return;
        savedRange = s.getRangeAt(0).cloneRange();
        var a = inBlock('A');
        linkurl.value = a ? (a.getAttribute('href') || '') : '';
        linkbox.hidden = false;
        linkurl.focus(); linkurl.select();
      }
      function closeLink(apply) {
        var url = linkurl.value.trim();
        linkbox.hidden = true;
        ed.focus();
        if (savedRange) { var s = window.getSelection(); s.removeAllRanges(); s.addRange(savedRange); }
        if (apply) {
          if (!url) { exec('unlink'); }
          else {
            if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) url = 'https://' + url;
            if (window.getSelection().isCollapsed) exec('insertHTML', '<a href="' + escapeHTML(url).replace(/"/g, '&quot;') + '">' + escapeHTML(url) + '</a>');
            else exec('createLink', url);
          }
          changed();
        }
        savedRange = null;
      }
      linkurl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); closeLink(true); }
        else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeLink(false); }
      });

      function updateToolbar() {
        if (!tb) return;
        var states = { bold: 'bold', italic: 'italic', strike: 'strikeThrough' };
        Array.prototype.slice.call(tb.querySelectorAll('button')).forEach(function (b) {
          var c = b.getAttribute('data-cmd'), on = false;
          try {
            if (states[c]) on = document.queryCommandState(states[c]);
            else if (/^h[1-3]$/.test(c)) { var bl = currentBlock(); on = !!bl && bl.tagName === c.toUpperCase(); }
            else if (c === 'ul') on = !!inBlock('UL');
            else if (c === 'ol') on = !!inBlock('OL');
            else if (c === 'quote') on = !!inBlock('BLOCKQUOTE');
            else if (c === 'code') on = !!inBlock('CODE');
            else if (c === 'link') on = !!inBlock('A');
          } catch (e) {}
          b.classList.toggle('on', on);
        });
      }
      if (tb) {
        tb.addEventListener('mousedown', function (e) {
          var b = e.target.closest('button'); if (!b) return;
          e.preventDefault();
          command(b.getAttribute('data-cmd'));
        });
      }
      document.addEventListener('selectionchange', function () { if (document.activeElement === ed) updateToolbar(); });

      // ---------------- 快捷键 ----------------

      ed.addEventListener('keydown', function (e) {
        // 中文输入法选字过程中的按键（空格选词、回车上屏）不处理
        if (e.isComposing || e.keyCode === 229) return;
        var meta = e.metaKey || e.ctrlKey;
        if (e.key === 'Escape') { e.preventDefault(); sendNow(); post({ type: 'cancel' }); return; }
        if (meta && e.key === 'Enter') { e.preventDefault(); sendNow(); post({ type: 'submit' }); return; }
        // 1.3：快速录入浮窗里 Tab 跳到下一栏
        if (cfg.tabOut && e.key === 'Tab' && !meta && !e.altKey) {
          e.preventDefault(); sendNow(); post({ type: e.shiftKey ? 'backtab' : 'tab' }); return;
        }
        if (meta && !e.altKey) {
          var k = (e.key || '').toLowerCase(), code = e.code || '';
          var cmd = null;
          if (!e.shiftKey) {
            if (k === 'b') cmd = 'bold';
            else if (k === 'i') cmd = 'italic';
            else if (k === 'e') cmd = 'code';
            else if (k === 'k') cmd = 'link';
            else if (k === '1' || code === 'Digit1') cmd = 'h1';
            else if (k === '2' || code === 'Digit2') cmd = 'h2';
            else if (k === '3' || code === 'Digit3') cmd = 'h3';
            else if (k === '0' || code === 'Digit0') cmd = 'p';
            else if (k === 'u' && cfg.mode !== 'card') { e.preventDefault(); return; }   // Markdown 没有下划线
          } else {
            if (k === 'x') cmd = 'strike';
            else if (code === 'Digit8' || k === '*') cmd = 'ul';
            else if (code === 'Digit7' || k === '&') cmd = 'ol';
            else if (code === 'Period' || k === '>') cmd = 'quote';
          }
          if (cmd) { e.preventDefault(); command(cmd); return; }
        }
        if (!meta && !e.altKey && e.key === ' ' && blockShortcut()) { e.preventDefault(); return; }
        if (!meta && e.key === 'Enter' && !e.shiftKey) {
          if (hrShortcut()) { e.preventDefault(); return; }
          // 引用里的空行回车：退出引用
          var bq = inBlock('BLOCKQUOTE'), cb = currentBlock();
          if (bq && cb && !cb.textContent.replace(/\u200b/g, '').trim() && !cb.querySelector('img')) {
            e.preventDefault(); exec('formatBlock', '<p>'); changed(); return;
          }
        }
      });

      // 行首 Markdown：# ## ### - * + 1. >
      function textBeforeCaret(b) {
        var s = window.getSelection(); if (!s.rangeCount || !s.isCollapsed) return null;
        var r = document.createRange();
        r.selectNodeContents(b);
        r.setEnd(s.anchorNode, s.anchorOffset);
        return { text: r.toString(), range: r };
      }
      function deleteRange(r) {
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        exec('delete');
      }
      function blockShortcut() {
        var b = currentBlock(); if (!b || b.tagName === 'PRE') return false;
        var t = textBeforeCaret(b); if (!t) return false;
        var m = t.text, cmd = null;
        if (b.tagName === 'LI' || inBlock('BLOCKQUOTE')) { if (!/^#{1,3}$/.test(m)) return false; }
        if (/^#{1,3}$/.test(m)) cmd = 'h' + m.length;
        else if (/^[-*+•]$/.test(m)) cmd = 'ul';
        else if (/^\d+[.、]$/.test(m)) cmd = 'ol';
        else if (m === '>' || m === '》') cmd = 'quote';
        if (!cmd) return false;
        deleteRange(t.range);
        if (cmd[0] === 'h') exec('formatBlock', '<' + cmd + '>');
        else command(cmd);
        changed();
        return true;
      }
      function hrShortcut() {
        var b = currentBlock(); if (!b || b.tagName !== 'P') return false;
        if (!/^(-{3,}|\*{3,}|_{3,})$/.test((b.textContent || '').trim())) return false;
        var r = document.createRange(); r.selectNodeContents(b);
        deleteRange(r);
        exec('insertHorizontalRule');
        changed();
        return true;
      }

      // 行内 Markdown：**粗体** *斜体* `代码` ~~删除~~（敲完收尾符号即转换）
      var INLINE = [
        { re: /\*\*([^*\s](?:[^*]*[^*\s])?)\*\*$/, tag: 'strong' },
        { re: /(?:^|[^*])\*([^*\s](?:[^*]*[^*\s])?)\*$/, tag: 'em' },
        { re: /`([^`]+)`$/, tag: 'code' },
        { re: /~~([^~]+)~~$/, tag: 'del' },
      ];
      function inlineShortcut() {
        var s = window.getSelection(); if (!s.rangeCount || !s.isCollapsed) return;
        var node = s.anchorNode, off = s.anchorOffset;
        if (!node || node.nodeType !== 3 || inBlock('CODE') || inBlock('PRE')) return;
        var before = node.data.slice(0, off);
        for (var i = 0; i < INLINE.length; i++) {
          var m = INLINE[i].re.exec(before);
          if (!m) continue;
          var inner = m[1];
          var markLen = (INLINE[i].tag === 'strong' || INLINE[i].tag === 'del') ? 2 : 1;
          var start = off - (inner.length + markLen * 2);
          var r = document.createRange();
          r.setStart(node, start); r.setEnd(node, off);
          s.removeAllRanges(); s.addRange(r);
          exec('insertHTML', '<' + INLINE[i].tag + '>' + escapeHTML(inner) + '</' + INLINE[i].tag + '>​');
          // 接着输入的文字不再带格式
          var s2 = window.getSelection();
          if (s2.anchorNode && s2.anchorNode.nodeType === 3 && s2.anchorNode.data === '​') {
            var parent = s2.anchorNode.parentNode;
            if (parent && parent.tagName && parent.tagName.toLowerCase() === INLINE[i].tag) {
              var zw = s2.anchorNode; parent.removeChild(zw);
              parent.parentNode.insertBefore(zw, parent.nextSibling);
              var r2 = document.createRange(); r2.setStart(zw, 1); r2.collapse(true);
              s2.removeAllRanges(); s2.addRange(r2);
            }
          }
          return;
        }
      }

      ed.addEventListener('input', function (e) {
        if (e.inputType === 'insertText' && /[*`~]/.test(e.data || '')) inlineShortcut();
        changed();
      });
      ed.addEventListener('paste', function (e) {
        var dt = e.clipboardData, html = dt ? dt.getData('text/html') : '';
        if (html) { e.preventDefault(); pasteHTML(html); return; }
        // 纯文本、RTF 等交给系统粘贴，再清理一遍
        setTimeout(function () { cleanAll(); changed(); }, 0);
      });
      ed.addEventListener('drop', function () { setTimeout(function () { cleanAll(); changed(); }, 0); });
      ed.addEventListener('blur', function () { sendNow(); });
      ed.addEventListener('click', function (e) {
        // ⌘ 点链接在浏览器里打开
        var a = e.target.closest && e.target.closest('a');
        if (a && (e.metaKey || e.ctrlKey) && /^https?:/i.test(a.getAttribute('href') || '')) {
          e.preventDefault(); post({ type: 'open', value: a.getAttribute('href') });
        }
      });

      // ---------------- 对 Swift 的接口 ----------------

      window.krSetContent = function (html, isHTML) {
        originalHTML = !!isHTML;
        ed.innerHTML = html || '';
        normalizeRoot(ed);
        if (!ed.firstChild) ed.innerHTML = '<p><br></p>';
        lastSent = value();
        updateEmpty(); reportHeight();
      };
      window.krFocus = function () {
        ed.focus();
        var r = document.createRange(); r.selectNodeContents(ed); r.collapse(false);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      };
      window.krSelectAll = function () {
        ed.focus();
        var r = document.createRange(); r.selectNodeContents(ed);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      };
      window.krGetValue = function () { return value(); };
      window.krFlush = function () { sendNow(); return lastSent; };
      // 测试用
      window.krTestPasteHTML = function (html) { pasteHTML(html); return value(); };
      window.krCommand = command;

      window.krSetContent(window.__krInitial || '', originalHTML);
      // 正文与接口就绪即通知应用，不必等待正文里的远程图片下载完毕。
      post({ type: 'ready' });
    })();
    """#
}
