// KongReview 阅读器脚本：在存档的文章里划线、显示已有摘录。
// 与 Swift 的通信：window.webkit.messageHandlers.kg.postMessage({...})
//   {type: "highlight", text}  选中文字后按 H 或点浮动按钮
//   {type: "open", id}         点击已有摘录
// Swift 调用：kgApply([{id, text}, ...]) 重新标注全部摘录
(function () {
  "use strict";

  function post(msg) {
    try { window.webkit.messageHandlers.kg.postMessage(msg); } catch (e) { /* 测试环境无 webkit */ }
  }

  function contentRoot() {
    return document.getElementById("kg-content") || document.body;
  }

  // ---------- 标注已有摘录 ----------

  function clearMarks(root) {
    var marks = root.querySelectorAll("mark.kg");
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i], p = m.parentNode;
      while (m.firstChild) p.insertBefore(m.firstChild, m);
      p.removeChild(m);
    }
    root.normalize();
  }

  // 去掉所有空白后匹配：网页段落之间的换行、空格与选中文字里的不一致，忽略空白最稳妥
  function isSpace(c) { return /\s/.test(c); }

  function markText(root, needle, id) {
    var target = "";
    for (var k = 0; k < needle.length; k++) if (!isSpace(needle[k])) target += needle[k];
    if (!target) return false;

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var nodes = [], full = "", map = [], n;
    while ((n = walker.nextNode())) {
      if (n.parentNode && /^(SCRIPT|STYLE)$/.test(n.parentNode.nodeName)) continue;
      nodes.push(n);
      var t = n.nodeValue;
      for (var i = 0; i < t.length; i++) {
        if (isSpace(t[i])) continue;
        full += t[i];
        map.push([nodes.length - 1, i]);
      }
    }
    var at = full.indexOf(target);
    if (at < 0) return false;
    var start = map[at], end = map[at + target.length - 1];

    // 从后往前包裹，前面节点的偏移量不受影响
    for (var ni = end[0]; ni >= start[0]; ni--) {
      var node = nodes[ni];
      var a = ni === start[0] ? start[1] : 0;
      var b = ni === end[0] ? end[1] + 1 : node.nodeValue.length;
      if (b <= a) continue;
      var segment = node.nodeValue.slice(a, b);
      if (!segment.trim()) continue;   // 纯空白片段不包
      var range = document.createRange();
      range.setStart(node, a);
      range.setEnd(node, b);
      var mark = document.createElement("mark");
      mark.className = "kg";
      mark.setAttribute("data-id", String(id));
      range.surroundContents(mark);
    }
    return true;
  }

  window.kgApply = function (list) {
    var root = contentRoot();
    clearMarks(root);
    var found = 0;
    for (var i = 0; i < list.length; i++) {
      if (markText(root, list[i].text, list[i].id)) found++;
    }
    return found;
  };

  // ---------- 划线 ----------

  function selectedText() {
    var sel = window.getSelection();
    return sel ? sel.toString() : "";
  }

  function sendSelection() {
    var s = selectedText();
    if (!s.trim()) return false;
    post({ type: "highlight", text: s });
    window.getSelection().removeAllRanges();
    hideButton();
    return true;
  }
  window.kgSendSelection = sendSelection;

  var button = null;
  function ensureButton() {
    if (button) return button;
    button = document.createElement("button");
    button.id = "kg-float";
    button.textContent = "摘录 (H)";
    button.addEventListener("mousedown", function (e) { e.preventDefault(); });
    button.addEventListener("click", function (e) { e.preventDefault(); sendSelection(); });
    document.body.appendChild(button);
    return button;
  }
  function hideButton() { if (button) button.style.display = "none"; }

  document.addEventListener("mouseup", function () {
    setTimeout(function () {
      var sel = window.getSelection();
      if (!sel || sel.isCollapsed || !sel.toString().trim()) { hideButton(); return; }
      var rect = sel.getRangeAt(0).getBoundingClientRect();
      var b = ensureButton();
      b.style.display = "block";
      b.style.top = (window.scrollY + rect.top - 38) + "px";
      b.style.left = (window.scrollX + rect.left + rect.width / 2 - 40) + "px";
    }, 0);
  });

  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "h" || e.key === "H") {
      if (sendSelection()) e.preventDefault();
    } else if (e.key === "Escape") {
      hideButton();
    }
  });

  document.addEventListener("click", function (e) {
    var m = e.target.closest ? e.target.closest("mark.kg") : null;
    if (m && !selectedText().trim()) post({ type: "open", id: Number(m.getAttribute("data-id")) });
  });
})();
