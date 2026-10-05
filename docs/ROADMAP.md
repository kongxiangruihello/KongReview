# 路线图

## v0.1 — 骨架（当前）
- [x] 摘录 / 出处的增删改，标签，全文检索
- [x] 每日回顾（加权抽样 + 降权 + 按日固定）、记忆卡、主题回顾
- [x] 书签小程序与 `kongglean://` 链接
- [x] Markdown 导出、复制时附带引文
- [x] 每日提醒
- [ ] 在 Xcode 中首次编译并修正编译问题
- [ ] 统一 kong 系列图标（以 kongfetch 为准）

## v0.2 — 录入体验
- [ ] 全局快捷键快速录入（小浮窗，类似 Spotlight），或者由 kongfetch 调用 `kongglean://add`
- [ ] 粘贴时自动识别“正文 + 出处”格式
- [ ] 从剪贴板中的网址抓取标题与作者（URLSession + `<meta>` 解析）
- [ ] 批量导入：Markdown / CSV / Readwise 导出的 CSV

## v0.3 — 网页存档
- [ ] 整页正文存档：在 WKWebView 中注入 Defuddle（MIT 许可证）或 Readability.js（Apache 2.0 许可证），把正文保存为 Markdown
- [ ] Safari Web Extension：选中文字后在右键菜单中“发送到 KongGlean”
- [ ] 文章阅读视图：在存档的正文里直接划线

## v0.4 — 记忆与学术
- [ ] 记忆卡改用 FSRS 算法（Swift 实现可选 swift-fsrs），用于需要背诵的章句
- [ ] 完形填空卡（挖空关键词）
- [ ] 更规范的引文体例（GB/T 7714、芝加哥格式）可切换
- [ ] 与计划中的 PDF 批注应用共享数据库，PDF 里的划线直接进入 KongGlean

## 以后再说
- [ ] iCloud 同步 + iPhone 版（CloudKit；数据层已与界面分离，可以复用 KongGleanCore）
- [ ] 每日回顾邮件 / 小组件
