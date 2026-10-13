import SwiftUI
import KongReviewCore

/// 侧边栏“使用说明”：按使用流程介绍各项功能与快捷键
struct HelpView: View {
    @Environment(LibraryStore.self) private var store

    private struct Topic: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let items: [String]
        var go: SidebarItem? = nil
    }

    private var topics: [Topic] {
        [
            Topic(icon: "square.and.pencil", title: "一、录入摘录", items: [
                "新建摘录：⌘N。原文、译文、按语都是所见即所得的编辑框：⌘B 粗体、⌘I 斜体、⇧⌘X 删除线、⌘K 链接、⌘1/⌘2/⌘3 标题、⌘0 正文、⇧⌘8 列表、⇧⌘7 编号列表、⇧⌘. 引用；也可以直接敲 Markdown（行首“# ”“- ”“> ”，或 **粗体**、*斜体*），敲完即变。⌘↩ 保存，Esc 取消。",
                "粘贴保留格式：从网页、Word、Pages、Anki 复制的标题、粗体、斜体、列表、引用、链接、图片都保留，字体、字号、颜色去掉。快速录入浮窗粘贴时也会把格式转成 Markdown。",
                "系统服务：在任何应用里选中文字，右键 →“服务”→“添加到 KongReview”，打开快速录入浮窗并填好正文与出处；“在 KongReview 中查引文”以选中文字为关键词打开引文速查。（第一次使用前可能要在“系统设置 → 键盘 → 键盘快捷键 → 服务”里勾选。）",
                "快速录入浮窗：在任何应用里按 \(HotKeyPreset.current.label)（可在“设置 → 快速录入”修改）。剪贴板里的新内容自动填入，出处沿用上一次；⌘↩ 保存，Esc 取消。",
                "出处：可新建或选择已有出处；类型有书籍、文章、网页、PDF、人工智能、其他。引文体例（中文脚注 / GB/T 7714）在“设置 → 摘录”选择。",
                "浏览器书签：“设置 → 摘录”里复制两个书签小程序——选中文字后点“摘录选中文字”，或点“整页存档”。",
                "导入 LiquidText：在 LiquidText 里导出笔记为 Word（.docx），再用“文件 → 从 LiquidText 导入笔记…”（⇧⌘I，可多选）。出处取自每条笔记后的“(文档名 , p.页码)”，括号里的作者自动拆出；图片摘录一并导入；PDF 换行留下的中文空格自动去掉；批注并入上一条摘录的按语。也可以在 LiquidText 里选中笔记 ⌘C，再用“从剪贴板导入 LiquidText 笔记”。",
                "导入 Readwise：文件 → 从 Readwise 导入 CSV…（同一文件可重复导入，已有的会跳过）。",
                "导入 LiquidText：文件 → 从 LiquidText 导入笔记…（⇧⌘I），选导出的 Word 笔记。也可在“设置 → 数据”指定一个文件夹，以后在 LiquidText 里把笔记导出到这里就自动导入；同一本书重新导出时只加新摘的，在 KongReview 里改过、删掉的不会被加回来。",
                "收件箱：其他应用（如 PDF 批注应用）把摘录写成 JSON 放进“设置 → 数据 → 收件箱”文件夹，KongReview 自动导入。",
                "出处封面：编辑出处时把封面图拖进封面框，或填 ISBN 后点“按 ISBN 获取”。",
            ]),
            Topic(icon: "sun.max", title: "二、今日回顾", items: [
                "每天按出处权重随机抽一组旧摘录（条数在“设置 → 回顾”设置）；同一天重开应用回到同一位置，跨日自动换新。顶部可按标签做主题回顾。",
                "快捷键：下一条 空格 / → / J；上一条 ← / K；收藏 F；弃置 Delete；就地编辑 E（⌥E 打开编辑面板）；写按语 N（⌘↩ 保存）；做成记忆卡 M；做成填空卡 C；展开相关摘录 R；⌘Z 撤销。编辑、写按语时单键快捷键自动停用。",
                "就地编辑：按 E 或点卡片右下角的铅笔，原文、译文、按语直接在卡片上改，⌘↩ 保存、Esc 取消；要改出处、位置、标签，点“在编辑面板中打开”。",
                "相关摘录：卡片下方“相关摘录”展开后，列出用词相近、同标签或同出处的其他摘录，点一下打开。",
                "卡片右下角：收藏、编辑、记忆卡、填空卡、回顾频率（多出现 / 少出现）、分享（复制文字或生成分享图）。",
                "页首统计条：今日回顾数、连续天数、近 7 天、待学记忆卡；点“全部统计”看完整统计。",
            ], go: .review),
            Topic(icon: "brain", title: "三、记忆卡（仿 Anki）", items: [
                "用途：需要背下来的内容（章句、字词、术语）。先看正面回想，空格显示答案，再按 1 重来、2 困难、3 良好、4 简单；按钮上标出下次出现的时间。显示答案后空格 = 良好；E 编辑；Esc 返回牌组。",
                "来源：摘录右键“做成记忆卡”、批量操作、回顾时按 M；手工新建；导入 Anki（.apkg、.colpkg 或纯文本）。",
                "背面栏目：编辑卡片时点“添加背面栏目”，可加多个（如“释义”“出处”“例句”），每个栏目可改名、排序、删除，也可设为默认折叠（复习时点开才看到）。导出到 Anki 时一并带上。",
                "填空卡：右键“做成填空卡…”或回顾时按 C。选中字词按 ⌘D 挖空，每个编号一张卡；⇧⌘D 在同一张卡里再挖一处。",
                "算法：每个牌组可选 SM-2 或 FSRS（右键牌组 → 牌组选项，可设每日上限与期望保留率）。“设置 → 记忆卡”可用自己的复习记录优化 FSRS 参数。",
                "卡片模板：从 Anki 导入的多字段笔记，可在“记忆卡 → 卡片模板”设置每个字段放正面、背面、背面折叠或不显示。",
                "导出到 Anki：工具栏“导出到 Anki”生成 .apkg，发到手机用 AnkiMobile / AnkiDroid 打开即可复习（单向，不会同步回来）。",
                "摘录改了：会询问是否同步更新对应卡片；卡片上的“原摘录”按钮可回到摘录。",
            ], go: .cards),
            Topic(icon: "globe", title: "四、网页存档", items: [
                "存档网页：⌘L。自动填入浏览器（Safari、Chrome、Edge、Brave、Arc）当前页面的网址，第一次会询问是否允许读取。",
                "在应用里阅读：选中文字按 H 即存为摘录，已摘录的句子标黄；图片经本地缓存，离线也能看。",
                "阅读器工具栏“编辑正文”可改 HTML，或整段换成 Markdown。",
            ], go: .articles),
            Topic(icon: "books.vertical", title: "五、整理与导出", items: [
                "出处管理：排序、查疑似重复、合并（合并前自动备份）、批量改类型。",
                "列表里 ⌘ / ⇧ 多选，右键批量加标签、移到出处、收藏、做成记忆卡、删除。",
                "标签整理：标签可用“/”分层（如 #儒家/孟子），选中父标签时列出其下全部摘录。侧边栏标签右键可改名、合并（改成已有的名字即合并）、删除；“标签”标题旁的按钮打开“整理标签”，还会提示只差大小写、全半角的重复标签。都可 ⌘Z 撤销。",
                "组合筛选：列表工具栏“筛选”，按出处、多个标签、日期、收藏组合；搜索词在结果里标黄；“保存为搜索”存到侧边栏。",
                "繁简通搜：搜“红卫兵”也能找到“紅衛兵”，反之亦然；记忆卡、引文速查、相关摘录同样适用（摘录原文不会被改动）。",
                "导出：单个出处导出 Markdown；任意列表导出专题汇编（Word / Markdown）；⌘⇧E 导出全部为 Markdown；“设置 → 数据”可自动同步到 Obsidian。",
            ], go: .sourceManager),
            Topic(icon: "bell", title: "六、提醒、统计与菜单栏", items: [
                "每日提醒在“设置 → 回顾”开启。当天看过一条摘录或复习过一张卡，就不再提醒；通知里写明当天的摘录条数与记忆卡数。",
                "菜单栏图标旁显示“今日待看摘录·待学卡片”（如 8·23），可在“设置 → 记忆卡”关闭。关掉主窗口后应用仍在后台运行，⌘Q 才完全退出。",
                "回顾统计：侧边栏“回顾统计”，含连续天数、最近 30 天、记忆卡正确率与库存。",
                "每周小结：每周第一次打开今日回顾时，顶部显示上周的回顾数、记忆卡答对率、新增摘录与本周金句，点 × 收起；已允许通知时周一 8 点后推送一条。可在“设置 → 回顾”关闭。",
                "记忆卡负荷与保留率：统计页显示未来 30 天每天到期多少张（过期的计入今天），以及每周的实际保留率与目标线（FSRS 牌组的期望保留率，默认 90%）。实际明显低于目标，可调高期望保留率或在“设置 → 记忆卡”优化参数；明显高于目标，可适当调低以减少复习量。",
            ], go: .stats),
            Topic(icon: "text.magnifyingglass", title: "七、写作：引文速查", items: [
                "在 Word、Pages 等任何应用里按 \(HotKeyPreset.lookup.label)（可在“设置 → 快速录入”修改），弹出搜索框，输入关键词，↑↓ 选择，↩ 把“原文 + 出处”粘到光标处。",
                "⌥↩ 只粘贴出处，⇧↩ 只粘贴原文，⌘↩ 只复制不粘贴；下方可选粘贴格式（“原文”（出处） / 原文 + ——出处 / “原文” + 脚注 / 只要原文 / 只要出处）。",
                "多条一起引：按 Tab（或 ⌘ 点按）把当前条加入“已选”，可以换关键词继续挑，↩ 按挑选顺序一次粘贴。",
                "脚注：选“原文 + 脚注”格式，粘到 Word 或 Pages 里出处成为真正的脚注（自动编号、在页脚）。",
                "参考文献表：摘录列表工具栏“导出 → 参考文献表（GB/T 7714）…”，或在出处管理里选几个出处右键；可选顺序编码制或著者-出版年制，复制或存为文本。",
                "自动粘贴需要在“系统设置 → 隐私与安全性 → 辅助功能”里允许 KongReview；不允许时会复制到剪贴板，自己按 ⌘V。",
            ]),
            Topic(icon: "text.book.closed", title: "八、专题笔记本", items: [
                "新建：侧边栏“专题笔记本”标题旁的“＋”，或“文件 → 新建专题笔记本…”；也可在摘录右键 / 批量操作 / 回顾卡片的分享菜单里选“加入专题笔记本 → 新建笔记本…”。",
                "编排：笔记本由摘录、文字、小标题组成。鼠标移到两块之间出现“＋”，可插入文字、小标题或摘录（可搜索、多选）；拖动左侧把手或点 ↑↓ 调整顺序；删除后 ⌘Z 撤销。摘录块显示该摘录的最新文字，改摘录处处同步。",
                "导出：工具栏“导出”——Word（出处为真脚注，①②编号）、Markdown（[^1] 脚注）、复制到剪贴板后粘进 Word / Pages；可选文末附参考文献表。",
            ]),
            Topic(icon: "externaldrive", title: "九、数据、备份与撤销", items: [
                "全部数据在一个 SQLite 文件中（~/Library/Application Support/KongReview）。每天第一次启动自动备份，保留 30 份，可选存到 iCloud 云盘。",
                "删除的摘录在“最近删除”保留 30 天。",
                "“设置 → 数据 → 整理数据库”：删除没有卡片在用的图片并收回空间（整理前自动备份）。",
                "从备份恢复：“设置 → 数据 → 从备份恢复…”，列出全部备份（日期、摘录数、卡片数），恢复前自动另存当前数据。",
                "撤销：回顾时的弃置、收藏，删除摘录、批量操作、合并或删除出处、删除记忆卡、调整回顾频率，都可以用 ⌘Z 撤销、⇧⌘Z 重做（“编辑”菜单里显示操作名）。",
            ]),
            Topic(icon: "checklist", title: "十、试用一周的检查清单", items: [
                "1.3：建一本专题笔记本，放几条摘录、写两段过渡文字、拖动换序，导出 Word，看脚注是否为 ①② 并在页脚。",
                "1.3：在 Safari、预览或 Word 里选中一段文字，右键“服务 → 添加到 KongReview”，出处是否自动填好；快速录入浮窗里 Tab 能否切到“出处”栏。",
                "1.3：鼠标移到回顾页下方的“弃置 / 按语 / 记忆卡 / 保留”上是否变手形；把窗口拉窄，顶栏是否完整。",
                "回顾页：空格 / J / → 下一条，← / K 上一条，F、E、N、M、C、R 各快捷键是否都灵；点过正文（选中文字）之后快捷键是否仍然有效。",
                "1.2 编辑器：⌘B、⌘I、⌘K、行首“# ”“- ”是否即时变样式；从网页、Word 粘贴一段带粗体和标题的文字，格式是否保留；就地编辑（E）后保存是否生效。",
                "1.2 写作：引文速查里 Tab 多选后粘到 Word；“原文 + 脚注”格式在 Word 里是否生成脚注；搜“红卫兵”能否找到繁体摘录。",
                "回顾页：按 ⌫ 弃置后马上 ⌘Z，摘录是否恢复、是否回到这一条。",
                "深色模式：回顾卡片、记忆卡（尤其从 Anki 导入、带颜色的卡）、分享图、统计页是否清楚。",
                "记忆卡：学一组《论语》卡，看间隔是否合理；卡片模板的折叠字段能否点开。",
                "引文速查：在 Word 里试一次自动粘贴；不开辅助功能权限时是否提示复制成功。",
                "性能：首页、全部摘录、搜索、记忆卡页、回顾统计页的切换有无明显停顿。",
                "LiquidText：导入一份导出的 Word 笔记，核对出处、页码、图片摘录和批注是否正确。",
                "遇到问题：“帮助 → 导出诊断信息…”生成一个文本文件（不含摘录正文），连同截图一起发给开发者。",
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KongReview 使用说明").font(.title.bold())
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")　摘录 · 回顾 · 记忆卡")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(topics) { t in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(t.title, systemImage: t.icon).font(.title3.bold())
                            Spacer()
                            if let go = t.go {
                                Button("打开 ›") { store.selection = go }.buttonStyle(.link)
                            }
                        }
                        ForEach(t.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.tint)
                                Text(verbatim: item).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
                }
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("使用说明")
    }
}
