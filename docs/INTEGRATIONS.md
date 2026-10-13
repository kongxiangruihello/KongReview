# 与其他工具配合

KongReview 对外只有一个入口：`kongreview://` 链接。凡是能“打开网址”的工具都能用它把文字送进来。
链接会弹出**快速录入浮窗**并预先填好内容，补上页码、标签后按 ⌘↩ 保存。不会自动保存，避免误录。

| 链接 | 作用 |
|---|---|
| `kongreview://add?text=…&title=…&author=…&url=…&location=…&tags=…&note=…` | 打开浮窗并填好内容（`text` 必填） |
| `kongreview://quick` | 打开空白浮窗（同全局快捷键） |
| `kongreview://quick?text=…` | 同 add，但所有参数都可以省略 |
| `kongreview://review` | 打开主窗口的“今日回顾” |
| `kongreview://save?url=…` | 抓取该网页并存入“网页存档”，随即打开阅读器 |

改名前的 `kongglean://` 链接（旧书签小程序、旧 Drafts 动作）仍然有效，不必重做。

参数要做 URL 编码（JavaScript 用 `encodeURIComponent`）。`tags` 用逗号分隔。

---

## Drafts

在 Drafts 里新建一个动作（Action），添加一个“Script”步骤，粘贴下面的代码：

```javascript
// 发送到 KongReview：有选中文字就发选中部分，否则发整篇草稿
const sel = editor.getSelectedText();
const text = (sel && sel.length > 0) ? sel : draft.content;
const params = [
  "text=" + encodeURIComponent(text),
  "tags=" + encodeURIComponent(draft.tags.join(","))
];
app.openURL("kongreview://add?" + params.join("&"), false);
```

建议给这个动作设一个快捷键（例如 ⌃⌥K 以外的组合），或放进键盘栏。

---

## kongfetch

在 kongfetch 里添加以下命令（快捷链接）：

| 名称 | 网址 | 说明 |
|---|---|---|
| 快速摘录 | `kongreview://quick` | 弹出空白浮窗（剪贴板有新内容时自动填入） |
| 摘录这段话 | `kongreview://add?text={query}` | 把在 kongfetch 里输入的文字直接送进浮窗 |
| 今日回顾 | `kongreview://review` | 打开回顾 |

`{query}` 换成 kongfetch 实际使用的“输入内容”占位符写法。

---

## 浏览器书签小程序

见 KongReview →“设置 → 摘录 → 复制书签代码”。选中网页文字后点书签，浮窗里会自动填好正文、网页标题与网址。

---

## 快捷指令（Shortcuts）

“打开 URL”动作，URL 填 `kongreview://add?text=`，后面接上“URL 编码”过的文本变量即可。


## 收件箱：其他应用投递摘录（0.9 起）

供计划中的 PDF 批注应用、脚本、快捷指令等使用。把摘录写成 JSON 文件放进

```
~/Library/Application Support/KongReview/Inbox/
```

KongReview 在启动、回到前台时和每分钟检查一次：导入成功的文件移到 `Inbox/已导入/`，格式不对的移到 `Inbox/出错/` 并附一个说明原因的 `.原因.txt`。设置 → 数据 → 收件箱 可以打开这个文件夹或立即检查。

格式（version 1，UTF-8）：

```json
{
  "version": 1,
  "app": "KongPDF",
  "source": {
    "title": "严复集", "author": "严复", "kind": "pdf",
    "url": "file:///Users/me/Books/严复集.pdf",
    "publisher": "中华书局", "year": "1986", "isbn": "9787101000000"
  },
  "highlights": [
    { "id": "批注在来源应用里的唯一 id", "text": "原文", "note": "按语", "translation": "译文",
      "page": 12, "location": "卷一", "tags": ["严复"], "createdAt": "2026-10-13T08:00:00Z" }
  ]
}
```

- `source.kind`：book / article / web / pdf（默认）/ ai / other。
- 出处按“标题 + 作者”合并到已有出处；已有出处缺网址或 ISBN 时会补上。
- 摘录按“app + id”去重（没有 id 时按原文），同一文件重复投递不会产生重复摘录。
- `location` 优先；没有时用 `page` 生成“第 N 页”。`createdAt` 可用 ISO 8601 字符串或 Unix 秒 / 毫秒。
- 出处的 `url` 是本地文件时，摘录右键菜单里有“打开原文件”。
