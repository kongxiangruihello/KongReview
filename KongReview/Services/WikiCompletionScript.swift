import Foundation

/// 4.1.2：札记编辑器里输入 [[ （或中文输入法下的【【）后，在正文下方列出札记题目供选择。
/// 列表放在编辑区之后、随网页高度一起撑开（自动高度的编辑器里浮层会被裁掉）。
/// 候选由应用按繁简归一匹配后送回（krWikiShow）；↑↓ 选择，回车或 Tab 确认，Esc 取消。
struct WikiSuggestion: Encodable, Equatable, Sendable {
    /// 题目
    var t: String
    /// 附注（如“新题目”）
    var h: String = ""
}

enum WikiCompletionScript {
    static let source = #"""
    (function () {
      var ed = document.getElementById('ed');
      if (!ed || window.krWikiInstalled) return;
      window.krWikiInstalled = true;
      var style = document.createElement('style');
      style.textContent = '#kr-wiki{display:none;margin:4px 8px 8px;border:1px solid var(--hair);border-radius:8px;overflow:hidden;'
        + 'font:13px -apple-system,"PingFang SC",sans-serif;background:var(--bar)}'
        + '#kr-wiki .hd{padding:4px 10px;font-size:11px;color:var(--sub)}'
        + '#kr-wiki .it{padding:5px 10px;cursor:pointer;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}'
        + '#kr-wiki .it .h{color:var(--sub);font-size:11px;margin-left:6px}'
        + '#kr-wiki .it.on{background:var(--accent);color:#fff}#kr-wiki .it.on .h{color:rgba(255,255,255,.8)}';
      document.head.appendChild(style);
      var box = document.createElement('div');
      box.id = 'kr-wiki';
      box.setAttribute('contenteditable', 'false');
      ed.parentNode.insertBefore(box, ed.nextSibling);
      var items = [], index = 0, seq = 0, dismissed = null;
      function post(m) { try { window.webkit.messageHandlers.krEditor.postMessage(m); } catch (_) {} }
      function context() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || !sel.isCollapsed) return null;
        var node = sel.anchorNode, off = sel.anchorOffset;
        if (!node || node.nodeType !== 3 || !ed.contains(node)) return null;
        var m = node.textContent.slice(0, off).match(/(\[\[|【【)([^\[\]【】\n|]{0,60})$/);
        if (!m) return null;
        return { node: node, open: off - m[0].length, end: off, query: m[2] };
      }
      function hide() { box.style.display = 'none'; box.innerHTML = ''; items = []; }
      function visible() { return box.style.display === 'block' && items.length > 0; }
      function render() {
        box.innerHTML = '';
        var hd = document.createElement('div');
        hd.className = 'hd';
        hd.textContent = '链接札记：↑↓ 选择，回车确认，Esc 取消';
        box.appendChild(hd);
        items.forEach(function (it, i) {
          var d = document.createElement('div');
          d.className = 'it' + (i === index ? ' on' : '');
          d.setAttribute('data-i', i);
          d.textContent = it.t;
          if (it.h) { var s = document.createElement('span'); s.className = 'h'; s.textContent = it.h; d.appendChild(s); }
          box.appendChild(d);
        });
        box.style.display = items.length ? 'block' : 'none';
      }
      window.krWikiShow = function (list, n) {
        if (n !== seq) return;
        if (!context()) { hide(); return; }
        items = list || []; index = 0; render();
      };
      function check() {
        var c = context();
        if (!c) { dismissed = null; hide(); return; }
        // Esc 关掉后，同一处 [[ 里继续打字不再弹出
        if (dismissed && dismissed.node === c.node && dismissed.open === c.open) { hide(); return; }
        seq += 1;
        post({ type: 'wiki-query', value: c.query, seq: seq });
      }
      function accept() {
        var c = context(), it = items[index];
        if (!c || !it) { hide(); return; }
        var text = c.node.textContent, after = text.slice(c.end);
        var close = after.indexOf(']]') === 0 ? '' : ']]';
        c.node.textContent = text.slice(0, c.open) + '[[' + it.t + close + after;
        var r = document.createRange();
        r.setStart(c.node, Math.min(c.open + 4 + it.t.length, c.node.textContent.length));
        r.collapse(true);
        var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
        hide();
        ed.dispatchEvent(new Event('input', { bubbles: true }));
        if (window.krFlush) krFlush();
      }
      document.addEventListener('keydown', function (e) {
        if (!visible() || e.isComposing || e.keyCode === 229) return;
        var handled = true;
        if (e.key === 'ArrowDown') { index = (index + 1) % items.length; render(); }
        else if (e.key === 'ArrowUp') { index = (index - 1 + items.length) % items.length; render(); }
        else if ((e.key === 'Enter' && !e.metaKey && !e.ctrlKey && !e.shiftKey) || e.key === 'Tab') { accept(); }
        else if (e.key === 'Escape') { var c = context(); if (c) dismissed = { node: c.node, open: c.open }; hide(); }
        else handled = false;
        if (handled) { e.preventDefault(); e.stopImmediatePropagation(); }
      }, true);
      ed.addEventListener('input', function (e) { if (!e.isComposing) check(); });
      ed.addEventListener('compositionend', function () { setTimeout(check, 0); });
      document.addEventListener('selectionchange', function () { if (visible() && !context()) hide(); });
      box.addEventListener('mousedown', function (e) {
        e.preventDefault();
        var el = e.target.closest && e.target.closest('[data-i]');
        if (el) { index = +el.getAttribute('data-i'); accept(); }
      });
      ed.addEventListener('blur', function () { setTimeout(function () { if (document.activeElement !== ed) hide(); }, 150); });
    })();
    """#
}
