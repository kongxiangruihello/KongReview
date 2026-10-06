# 与其他工具配合

KongGlean 对外只有一个入口：`kongglean://` 链接。凡是能“打开网址”的工具都能用它把文字送进来。
链接会弹出**快速录入浮窗**并预先填好内容，补上页码、标签后按 ⌘↩ 保存。不会自动保存，避免误录。

| 链接 | 作用 |
|---|---|
| `kongglean://add?text=…&title=…&author=…&url=…&location=…&tags=…&note=…` | 打开浮窗并填好内容（`text` 必填） |
| `kongglean://quick` | 打开空白浮窗（同全局快捷键） |
| `kongglean://quick?text=…` | 同 add，但所有参数都可以省略 |
| `kongglean://review` | 打开主窗口的“今日回顾” |
| `kongglean://save?url=…` | 抓取该网页并存入“网页存档”，随即打开阅读器 |

参数要做 URL 编码（JavaScript 用 `encodeURIComponent`）。`tags` 用逗号分隔。

---

## Drafts

在 Drafts 里新建一个动作（Action），添加一个“Script”步骤，粘贴下面的代码：

```javascript
// 发送到 KongGlean：有选中文字就发选中部分，否则发整篇草稿
const sel = editor.getSelectedText();
const text = (sel && sel.length > 0) ? sel : draft.content;
const params = [
  "text=" + encodeURIComponent(text),
  "tags=" + encodeURIComponent(draft.tags.join(","))
];
app.openURL("kongglean://add?" + params.join("&"), false);
```

建议给这个动作设一个快捷键（例如 ⌃⌥K 以外的组合），或放进键盘栏。

---

## kongfetch

在 kongfetch 里添加以下命令（快捷链接）：

| 名称 | 网址 | 说明 |
|---|---|---|
| 快速摘录 | `kongglean://quick` | 弹出空白浮窗（剪贴板有新内容时自动填入） |
| 摘录这段话 | `kongglean://add?text={query}` | 把在 kongfetch 里输入的文字直接送进浮窗 |
| 今日回顾 | `kongglean://review` | 打开回顾 |

`{query}` 换成 kongfetch 实际使用的“输入内容”占位符写法。

---

## 浏览器书签小程序

见 KongGlean →“设置 → 摘录 → 复制书签代码”。选中网页文字后点书签，浮窗里会自动填好正文、网页标题与网址。

---

## 快捷指令（Shortcuts）

“打开 URL”动作，URL 填 `kongglean://add?text=`，后面接上“URL 编码”过的文本变量即可。
