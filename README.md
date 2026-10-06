# KongGlean

个人用的 macOS 摘录与回顾工具。思路参照 Readwise：把读书、读网页时的摘录集中起来，每天随机推送几条，让旧摘录重新出现在眼前。

**glean**，意为拾穗、搜集。属于 kong 系列应用（kongflow · kongbabel · kongvox · kongfetch）。

## 0.2 新增

- **快速录入浮窗**：在任何应用里按 ⌃⌥K（可在设置里改），弹出小窗；剪贴板有新内容时自动填入，出处默认沿用上一次。⌘↩ 保存，Esc 取消，焦点自动回到原来的应用。
- **菜单栏图标**、**登录时启动**：关掉主窗口后仍在后台运行。
- **每日自动备份**：每天第一次启动时备份一次，保留 30 份，可选存到 iCloud 云盘；也可以手动“立即备份”。
- **最近删除**：删除改为移入“最近删除”，30 天内可恢复；删除出处、清空最近删除前都会确认。
- **链接直达浮窗**：`kongglean://add`、`kongglean://quick`、`kongglean://review`；Drafts、kongfetch 的配置方法见 [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md)。
- **构建不覆盖旧包**：DMG 生成在仓库同级目录，上一次的产物自动移到“KongGlean旧构建/时间”。

## 基本功能

| 模块 | 说明 |
|---|---|
| 摘录 | 原文、译文 / 白话、按语、位置（页码、卷次）、标签 |
| 出处 | 书籍、论文、网页、PDF；作者、出版者、版本、年份、网址；可单独调整回顾频率 |
| 每日回顾 | 按概率抽取，摘录多的书出现得多；刚出现过的摘录降权；同一天内重开应用看到的是同一组 |
| 记忆卡 | 半衰期 1 / 7 / 14 / 28 天，回忆概率降到 50% 时排进当日回顾 |
| 主题回顾 | 按标签限定回顾范围 |
| 搜索 | SQLite FTS5 trigram 全文检索，可搜中文任意子串；不足 3 字时自动改用模糊匹配 |
| 网页摘录 | 浏览器书签小程序 + `kongglean://add?...` 链接 |
| 导出 | Markdown（带 YAML 头，适合 Obsidian）；复制时附带中文引文 |
| 提醒 | 每日定时本地通知 |

快捷键：⌃⌥K 快速录入（全局），⌘N 新建摘录，⌥⌘N 快速录入浮窗，⇧⌘N 新建出处，⇧⌘R 今日回顾，⇧⌘E 全部导出。
回顾时：空格 = 下一条，← = 上一条，F = 收藏，M = 加入记忆卡，Delete = 弃置，E = 编辑，1–4 = 给记忆卡打分。

## 构建

### 方式一：只打包 DMG（不需要安装 Xcode）

只需要 Apple 命令行工具（`xcode-select --install`）：

```bash
./Tools/build-dmg.sh        # 产物在仓库同级目录：../KongGlean-<版本>.dmg
```

用的是本机 ad-hoc 签名，没有公证。第一次打开时，如果系统提示“无法验证开发者”，在访达中右键点 KongGlean →“打开”即可；或者到“系统设置 → 隐私与安全性”里点“仍要打开”。

### 方式二：用 Xcode 开发

需要 Xcode 16 或更新版本，系统要求 macOS 14 以上。

```bash
brew install xcodegen          # 首次使用时安装
cd KongGlean
xcodegen generate              # 根据 project.yml 生成 KongGlean.xcodeproj
open KongGlean.xcodeproj
```

在 Xcode 中选 KongGlean 目标 → Signing & Capabilities → Team 选自己的 Apple ID，然后按 ⌘R 运行。

`.xcodeproj` 不进版本库，每次改了 `project.yml` 或新增了文件，重新执行 `xcodegen generate` 即可。

核心逻辑（回顾算法、链接解析、导出）放在独立的 Swift 包里，可以脱离 Xcode 单独测试：

```bash
cd Packages/KongGleanCore && swift test
```

数据库层（表结构、全文检索、标签查询、捕获入库）和 `LibraryStore` 的测试在 `KongGleanTests/` 里，在 Xcode 中按 ⌘U 运行。

> 开发状态：`KongGleanCore`、`AppDatabase`、`LibraryStore` 已用 Swift 6.0.3 + GRDB 7.8 编译，测试全部通过（Linux 环境）。SwiftUI 界面部分尚未在 Xcode 中编译过，第一次构建时可能需要修正少量编译问题。

## 目录结构

```
KongGlean/
├── project.yml                     XcodeGen 配置
├── KongGlean/                      App（SwiftUI + GRDB）
│   ├── App/                        入口、全局状态 LibraryStore
│   ├── Database/AppDatabase.swift  表结构、迁移、全文检索、查询
│   ├── Views/                      侧边栏、列表、编辑器、每日回顾、设置
│   ├── Services/                   通知提醒、Markdown 导出
│   └── Resources/Assets.xcassets   图标（占位，可用 Tools/generate_icon.py 重新生成）
├── Packages/KongGleanCore/         纯逻辑层，带单元测试
│   ├── Models.swift                Source / Highlight / 标签解析
│   ├── ReviewScheduler.swift       每日回顾与记忆卡算法
│   ├── CaptureRequest.swift        kongglean:// 链接解析 + 书签小程序
│   └── Exporters.swift             引文格式、Markdown、搜索辅助
├── docs/ROADMAP.md                 后续计划
└── Tools/generate_icon.py
```

## 网页摘录

**书签小程序**：打开“设置 → 摘录 → 复制书签代码”，在浏览器里新建一个书签，把代码粘贴到网址栏。阅读网页时选中文字，点这个书签，KongGlean 就会弹出新建面板，标题和网址已经填好，补上标签后保存。

> 如果在 Safari 中点书签没有反应：先在 Safari 设置 → 高级 中勾选“显示网页开发者功能”，再到“开发”菜单启用“允许来自智能搜索栏的 JavaScript”。第一次跳转时浏览器会询问是否允许打开 KongGlean，选允许即可。

**链接格式**，可供快捷指令、kongfetch、Alfred 等工具调用：

```
kongglean://add?text=学而时习之&title=论语&author=&url=&location=学而第一&tags=论语,学
```

参数需要做 URL 编码。`text` 为必填项。

## 数据

全部数据保存在一个 SQLite 文件中：

```
~/Library/Application Support/KongGlean/glean.sqlite
```

在“设置 → 数据”里可以直接在访达中打开这个位置。备份时复制整个文件夹即可。

## 致谢与参考

- 回顾机制参照 Readwise 的公开说明：<https://docs.readwise.io/readwise/docs/faqs/reviewing-highlights>
- 数据库：[GRDB.swift](https://github.com/groue/GRDB.swift)（MIT 许可证）
- 全文检索：SQLite FTS5 trigram 分词器 <https://www.sqlite.org/fts5.html>
