import Foundation
import GRDB
import KongReviewCore

/// 3.14：界面预览用的独立示例库。只有另行打包、标识为 `com.kongxiangrui.KongReview.Preview` 的应用会进入这里；
/// 数据全部在内存中，设置写在该标识自己的偏好域，不读写个人学习库。正式应用不会进入这条路径。
@MainActor enum PreviewLibrary {
    static var isEnabled: Bool { Bundle.main.bundleIdentifier == "com.kongxiangrui.KongReview.Preview" }

    /// 6.1.1：启动参数 `-previewBackup <完整备份路径>` 时，改用这份备份的副本（解到缓存目录的临时库）。
    /// 原备份文件只读不改；正式学习库不碰；关掉预览后副本留在缓存目录，下次打开时清掉。
    static let backupKey = "previewBackup"
    /// 载入了备份时为备份的说明（侧栏底部显示），否则为 nil
    private(set) static var backupLabel: String?

    static func makeStore() -> LibraryStore {
        if let path = UserDefaults.standard.string(forKey: backupKey), !path.isEmpty {
            do { return try makeStore(backup: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
            catch { NSLog("预览：载入备份失败，改用示例库：\(error)") }
        }
        return makeSampleStore()
    }

    static func makeStore(backup url: URL, workRoot: URL? = nil, defaults: UserDefaults = .standard) throws -> LibraryStore {
        let prepared = try FullBackupService.prepare(url: url)
        defer { prepared.cleanup() }
        let fm = FileManager.default
        let root = workRoot ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KongReview预览·备份副本", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = root.appendingPathComponent("library.sqlite")
        try fm.copyItem(at: FullBackupService.databaseFile(of: prepared), to: copy)
        let db = try AppDatabase(DatabaseQueue(path: copy.path))
        // 设置照备份里的（卷面题数等）。先清掉上次预览留下的一切——包括当天的卷尾再考、新录轮次等，
        // 它们记的是示例库的编号，留着会指到副本里别的摘录
        if isEnabled, let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        for key in FullBackupService.preferenceKeys { defaults.removeObject(forKey: key) }
        for (key, value) in try FullBackupService.settings(of: prepared) { defaults.set(value, forKey: key) }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        backupLabel = "学习库副本（备份于 \(f.string(from: prepared.manifest.createdAt))，\(prepared.counts.highlights) 条摘录）"
        return LibraryStore(db: db, draftPersistence: nil, positionDefaults: nil)
    }

    static func makeSampleStore() -> LibraryStore {
        backupLabel = nil
        // 6.1.1：上次预览（可能载入过备份）留下的当天卷面状态记的是别的库的编号，清掉
        if isEnabled {
            for key in [LibraryStore.examRelearnKey, ExamFresh.sessionKey] { UserDefaults.standard.removeObject(forKey: key) }
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("review.session.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        do {
            let db = try AppDatabase(DatabaseQueue())
            let now = Date()
            let calendar = Calendar.current
            func day(_ offset: Int, hour: Int = 9) -> Date {
                let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: now)!)
                return calendar.date(byAdding: .hour, value: hour, to: start)!
            }
            let sources = [
                try db.save(Source(title: "论语译注", author: "杨伯峻")),
                try db.save(Source(title: "国史大纲", author: "钱穆")),
                try db.save(Source(title: "中国近三百年学术史", author: "梁启超")),
            ]
            var highlights: [Highlight] = []
            let texts = ["学而时习之，不亦说乎", "温故而知新，可以为师矣", "对本国历史应略有所知", "学术思想之变迁", "君子不器",
                         "知之为知之，不知为不知", "三人行，必有我师焉", "经世致用", "清代学术概论", "吾日三省吾身",
                         "博学而笃志", "考据与义理", "士不可以不弘毅", "见贤思齐焉", "学而不思则罔"]
            for (i, text) in texts.enumerated() {
                highlights.append(try db.save(Highlight(sourceId: sources[i % 3].id, text: text, createdAt: day(-(i % 9)))))
            }
            // 近两周的回顾与卡片学习记录
            for offset in -13...(-1) where offset % 3 != 0 {
                for h in highlights.prefix(3 + (offset + 13) % 5) { db.log(ReviewEvent(kind: .keep, highlightId: h.id, at: day(offset))) }
            }
            var cards: [Card] = []
            for (i, h) in highlights.enumerated() {
                let deck = i % 3 == 0 ? "论语::学而" : (i % 3 == 1 ? "史学" : "学术史")
                cards.append(try db.save(Card(deck: deck, front: h.text, back: "释义 \(i + 1)", highlightId: h.id,
                                              due: day(-1), createdAt: day(-(i % 9)))))
            }
            for offset in -12...(-1) where offset % 4 != 0 {
                for c in cards.prefix(2 + (offset + 12) % 4) { _ = try db.answer(c, offset % 5 == 0 ? .again : .good, now: day(offset)) }
            }
            // 今天：已学 4 张，另有若干待学
            for c in cards.suffix(4) { _ = try db.answer(c, .easy, now: day(0, hour: max(0, calendar.component(.hour, from: now) - 1))) }
            for i in 0..<8 { _ = try db.save(Card(deck: "史学", front: "待学示例 \(i + 1)", back: "答案", due: day(-1))) }
            // 3.15：难卡——第 6 条摘录的卡片近几天重来 3 次（回顾时“重读原文”）；本周写过几条按语、收藏几条
            for d in [-3, -2, -1] { _ = try db.answer(cards[5], .again, now: day(d, hour: 20)) }
            for h in highlights.prefix(3) {
                var noted = h; noted.note = "<p>按：\(String(h.text.prefix(4)))一句，可与《学而》首章互参。</p>"
                _ = try db.save(noted)
                db.log(ReviewEvent(kind: .note, highlightId: h.id, at: day(-1, hour: 10)))
            }
            for h in highlights[3...4] { db.log(ReviewEvent(kind: .favorite, highlightId: h.id, at: day(-1, hour: 11))) }
            // 本期焦点：专题“何以为士”，收入其中五条摘录
            let notebook = try db.createNotebook(title: "何以为士")
            _ = try db.insertBlocks(highlights.enumerated().filter { $0.offset % 3 == 0 }.map {
                NotebookBlock(notebookId: notebook.id!, position: Double($0.offset + 1), kind: .highlight, highlightId: $0.element.id)
            }, into: notebook.id!, after: nil)
            // 4.0：当前项目——论文，处于“初稿”；归入专题“何以为士”与《中国近三百年学术史》，有两项下一步与问题簿中的问题
            var project = try db.saveResearchProject(ResearchProject(title: "何以为士：先秦儒家的士人观", kind: .paper, stage: .idea,
                                                                       question: "“士”的自我期许如何从身份转为德行？",
                                                                       dueDate: calendar.startOfDay(for: day(71)), targetWords: 20_000), now: day(-30))
            try db.setResearchProjectStage(id: project.id!, stage: .material, now: day(-20))
            try db.setResearchProjectStage(id: project.id!, stage: .draft, now: day(-6))
            project = try db.researchProject(id: project.id!)!
            try db.linkToResearchProject(project.id!, kind: .notebook, recordId: notebook.id!)
            try db.linkToResearchProject(project.id!, kind: .source, recordId: sources[2].id!)
            try db.setLearningFocus(LearningFocus(kind: .project, id: project.id!, title: project.title, startedAt: day(-6)))
            let projectLink = LearningPlanLink(kind: .project, recordID: project.id!, title: project.title)
            var next1 = LearningPlan(title: "补齐第三节引文页码", link: projectLink); next1.dueDate = day(2)
            var next2 = LearningPlan(title: "改写第二节结论", link: projectLink); next2.dueDate = day(5)
            try db.saveLearningPlan(next1); try db.saveLearningPlan(next2)
            _ = try db.saveResearchProject(ResearchProject(title: "《论语》导读讲稿", kind: .course, stage: .material), now: day(-3))
            // 4.0 第二步：写作量——专题里分几天写的文字，另有一笔 Word 稿的手记
            let drafts: [(Int, String)] = [(-40, "<p>士之为士，先在其志。孔子言“士志于道”，以道自任，非以身份自居。</p>"),
                                           (-26, "<p>曾子“士不可以不弘毅”一章，弘言其量，毅言其守，二者相须。</p>"),
                                           (-12, "<h2>一、从身份到德行</h2>"),
                                           (-11, "<p>春秋以前之士，多指封建等级中最低一层；至孔门，士乃成为一种自我期许。</p>"),
                                           (-4, "<p>孟子言“无恒产而有恒心者，惟士为能”，士之可贵，正在其不待外物而自立。</p>"),
                                           (-1, "<p>本节拟以《论语》《孟子》为主线，旁及《荀子·修身》。</p>")]
            for (offset, html) in drafts {
                _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 0, kind: .text, text: html)],
                                        into: notebook.id!, after: nil, now: day(offset, hour: 21))
            }
            // 4.1：札记——一条引用两条摘录、链接另一条，并归入当前项目；另一条被链接
            let selfReliance = try db.createIdeaNote(title: "士之可贵在于不待外物而自立",
                                                     body: "<p>孟子“无恒产而有恒心者，惟士为能”，与曾子“任重道远”相发明，参见 [[士由身份转为德行]]。</p>",
                                                     highlightIDs: [highlights[12].id!, highlights[10].id!], now: day(-3))
            let identity = try db.createIdeaNote(title: "士由身份转为德行",
                                                 body: "<p>春秋以前之士多指等级中的一层；至孔门，“士”成为一种自我期许。</p>",
                                                 highlightIDs: [highlights[0].id!], now: day(-40))
            try db.linkToResearchProject(project.id!, kind: .note, recordId: selfReliance.id!)
            // 5.1：《国史大纲》一个月前读完，今天第一次重温其提要
            try db.saveBookSummary(sourceId: sources[1].id!, oneLine: "国史须以温情与敬意读之，治史者当知本国文化之所以然。",
                                   body: "<p>引论列“信念”四条；以民族文化为主线，通论自上古至清末。</p>",
                                   finishedAt: day(-30), now: day(-30))
            // 5.0.3：去年今日——一年前的今天写的札记
            _ = try db.createIdeaNote(title: "读书先须识字，识字先须明音", body: "<p>乾嘉学者以小学为治经之门径。</p>",
                                      now: calendar.date(byAdding: .year, value: -1, to: day(0, hour: 20))!)
            // 5.0.1：昨天修订过一次（复盘“看自己的想法”里列为本期修订）
            try db.saveIdeaNote(id: selfReliance.id!, title: selfReliance.title,
                                body: "<p>孟子“无恒产而有恒心者，惟士为能”，与曾子“任重道远”相发明，参见 [[士由身份转为德行]]。士之自立，不待外物，而在其志。</p>",
                                now: day(-1))
            // 4.1.2：专题笔记本末尾放一个札记块
            _ = try db.insertBlocks([NotebookBlock(notebookId: notebook.id!, position: 0, kind: .note, text: selfReliance.body, noteId: selfReliance.id!)],
                                    into: notebook.id!, after: nil, now: day(-2, hour: 21))
            // 4.1.1：问题簿——一个「常念」、挂着今日回顾当前摘录；一个刚记下；一个已解决（解答指向札记）；一个搁置
            let pinned = try db.createQuestion(title: "“士志于道”与“士不可以不弘毅”能否互证？", scopes: [(.notebook, notebook.id!)], now: day(-9))
            try db.setQuestionPinned(id: pinned.id!, true)
            try db.addQuestionMaterial(questionId: pinned.id!, kind: .highlight, recordId: highlights[12].id!, reason: "“任重道远”正是“志于道”的担当", now: day(-8))
            try db.addQuestionMaterial(questionId: pinned.id!, kind: .highlight, recordId: highlights[5].id!, now: day(-4))
            try db.addQuestionMaterial(questionId: pinned.id!, kind: .note, recordId: selfReliance.id!, now: day(-3))
            let unpinned = try db.createQuestion(title: "梁启超论清代学术的“经世”一义出处待核", scopes: [(.notebook, notebook.id!)], now: day(-7))
            let status = try db.createQuestion(title: "孔门之“士”是否已脱离封建等级的含义？", scopes: [(.project, project.id!)], now: day(-12))
            try db.addQuestionMaterial(questionId: status.id!, kind: .highlight, recordId: highlights[0].id!, now: day(-10))
            if let target = try db.resolveIdeaNoteID(title: "士由身份转为德行") {
                try db.setQuestionAnswerNote(id: status.id!, noteId: target, now: day(-5))
                try db.setQuestionStatus(id: status.id!, .solved, now: day(-5))
            }
            let shelved = try db.createQuestion(title: "“士”与“君子”在《论语》中如何分用？", detail: "<p>待读完《论语》全书再看。</p>", now: day(-20))
            try db.setQuestionStatus(id: shelved.id!, .shelved, now: day(-15))
            // 5.0.0：重温——“士由身份转为德行”与「常念」问题今天到期
            try db.writer.write { d in
                try d.execute(sql: "UPDATE idea_note_review SET dueDay = ? WHERE noteId = ?", arguments: [AppDatabase.revisitDay(now), identity.id!])
                try d.execute(sql: "INSERT OR REPLACE INTO question_review(questionId, dueDay) VALUES (?, ?)", arguments: [pinned.id!, AppDatabase.revisitDay(now)])
                // 6.0.9：没标常念的进展题、已解决的解答题今天也到期
                try d.execute(sql: "INSERT OR REPLACE INTO question_review(questionId, dueDay) VALUES (?, ?)", arguments: [unpinned.id!, AppDatabase.revisitDay(now)])
                try d.execute(sql: "INSERT OR REPLACE INTO question_answer_review(questionId, dueDay) VALUES (?, ?)", arguments: [status.id!, AppDatabase.revisitDay(now)])
            }
            try db.recordExternalWritingTotal(projectId: project.id!, total: 3_200, day: day(-20), now: day(-20))
            try db.recordExternalWritingTotal(projectId: project.id!, total: 4_650, day: day(-2), note: "第二节初稿（Word）", now: day(-2))
            // 今日回顾：一组 10 条，已回顾 4 条；当前第 5 条为“重读原文”
            let others = highlights.prefix(10).compactMap(\.id).filter { $0 != highlights[5].id! }
            let ids = Array(others.prefix(4)) + [highlights[5].id!] + Array(others.dropFirst(4).prefix(5))
            for id in ids.prefix(4) { db.log(ReviewEvent(kind: .keep, highlightId: id, at: now.addingTimeInterval(-600))) }
            // 6.0.8：两条昨天新录的、一条四天前录且三天前考过一次的，排在已答的 4 条之后（与正式组卷的次序相同）
            for (i, text) in ["新录示例：君子不器。", "新录示例：吾日三省吾身。"].enumerated() {
                _ = try db.save(Highlight(sourceId: sources[0].id, text: text, location: "第 \(i + 20) 页", createdAt: day(-1, hour: 21)))
            }
            // 6.3.6：这一条带译文与按语（含粗体、列表），今天排在摘录题最前，预览里能看到日课展开后的排版
            let second = try db.save(Highlight(sourceId: sources[1].id, text: "新录示例：士不可以不弘毅，任重而道远。",
                                               translation: "读书人不可以不志向宏大而意志坚强，因为担子重、路程远。",
                                               note: "**弘**言其量，**毅**言其守。\n\n- 朱注：非弘不能胜其重，非毅无以致其远\n- 可与“士志于道”章对读",
                                               location: "第 31 页", createdAt: day(-4, hour: 21)))
            try db.recordExamResult(kind: .gist, recordId: second.id!, result: .partly, now: day(-3, hour: 20))
            let fresh = try db.examFreshCandidates(now: now, limit: ExamFresh.defaultPerDay)
            ExamFresh.Session(day: ReviewSessionRecord.dayString(now), rounds: Dictionary(fresh.map { ($0.id, $0.round) }, uniquingKeysWith: { a, _ in a })).save()
            // 一组仍是 10 条：新录占名额
            let ordered = Array((Array(ids.prefix(4)) + fresh.map(\.id) + Array(ids.dropFirst(4))).prefix(ids.count))
            let record = ReviewSessionRecord(day: ReviewSessionRecord.dayString(now), regularIds: ordered, masteryIds: [], position: 4)
            UserDefaults.standard.set(try JSONEncoder().encode(record), forKey: ReviewSessionRecord.key(theme: nil))
            // 本周复盘与计划
            let week = GrowthPeriod.week.window(containing: now)
            try db.saveProgress(GrowthReflection(goalHighlights: 30, goalCards: 40,
                                                 gains: "<p>读完《论语·学而》前五章，能说明“学”与“习”的区别。</p>",
                                                 challenges: "<p>生字较多，记忆卡重来次数偏高。</p>",
                                                 nextSteps: "<p>每天复习十张《学而》卡片，并整理一篇札记。</p>"), key: week.key)
            let lastWeek = GrowthPeriod.week.window(containing: week.previousStart)
            try db.saveProgress(GrowthReflection(nextSteps: "<p>先把《学而》篇的生字整理成卡片。</p>"), key: lastWeek.key)
            var plan = LearningPlan(title: "整理《学而》篇生字卡片", originKey: lastWeek.key)
            plan.dueDate = day(-2); plan.createdAt = day(-6); plan.completedAt = day(-1)
            try db.saveLearningPlan(plan)
            try db.saveLearningPlan(LearningPlan(title: "写一篇《学而》札记", originKey: week.key))
            // 6.0.4：几篇整篇存进来、还没划过的文章（今日标注）；另有两篇以前在别处划过（同一出处的短摘录出现在正文里），不抽
            let essays: [(Int, String, [String])] = [
                (2, "梁启超论清学", ["清代学术，以复古为解放。", "其始也，自宋明理学之反动而起；其继也，考证之学大盛，乾嘉诸老，各有专门。", "其末也，今文学兴，经世之说复起，而西学之输入，遂开新局。"]),
                (1, "钱穆论读史", ["凡读本书请先具下列诸信念。", "当信任何一国之国民，尤其是自称知识在水平线以上之国民，对其本国已往历史，应该略有所知。", "所谓对其本国已往历史略有所知者，尤必附随一种对其本国已往历史之温情与敬意。"]),
                (0, "论语学而章疏", ["学而时习之，不亦说乎。", "学者，觉也，效也；习者，鸟数飞也。学之不已，如鸟数飞，所以说也。", "有朋自远方来，不亦乐乎。同门曰朋，同志曰友。"]),
                (1, "钱穆论国史之精神", ["治国史之第一任务，在能于国家民族之内部自身，求得其独特精神之所在。", "此种精神，即其民族文化之生命。", "国史所载，非帝王将相之家谱，乃一民族之全体生命史也。"]),
            ]
            for (i, essay) in essays.enumerated() {
                let body = (0..<16).flatMap { round in essay.2.map { "\($0)（\(round + 1)）" } }.joined(separator: "\n\n")
                _ = try db.save(Highlight(sourceId: sources[essay.0].id, text: "## \(essay.1)\n\n" + body + String(repeating: "\n\n读者按：此段宜反复读之。", count: 6), createdAt: day(-20 - i)))
            }
            _ = try db.save(Highlight(sourceId: sources[2].id, text: "## 已在别处划过的一篇\n\n" + String(repeating: "梁启超作清代学术概论，谓经世致用之学，起于明末清初诸大儒。顾炎武、黄宗羲、王夫之，皆以天下为己任。\n\n", count: 20), createdAt: day(-25)))
            // 6.0.5：成绩册——近三周的每日成绩（有几天没打卡）、卷面作答（几条摘录常错）、一段笔记两次需重读
            let notes = ["读完学而篇", "出处题错了两道", "", "记忆卡顺手", "补了昨天的", "", "札记想清楚了一条"]
            for offset in -20...(-1) where offset % 6 != 0 {
                let key = AppDatabase.revisitDay(day(offset))
                let due = 18 + (offset + 20) % 7, done = offset % 5 == 0 ? due / 2 : due
                let score = 3 + (offset + 20) % 3
                // 6.3.5：前天做完了却没写日评，示例里能看到补签卡片
                let checked = done == due && offset != -2
                try db.writer.write { d in
                    try d.execute(sql: """
                        INSERT INTO daily_checkin(day, status, selfScore, note, doneCount, dueCount, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [key, checked ? "checked" : nil, checked ? score : nil,
                                         notes[(offset + 20) % notes.count], done, due, day(offset, hour: 21), day(offset, hour: 21)])
                }
                for (i, h) in highlights.prefix(8).enumerated() where (offset + i) % 3 == 0 {
                    let result: SelfTestResult = i < 2 && offset % 2 == 0 ? .forgot : (i + offset) % 4 == 0 ? .partly : .remembered
                    try db.recordExamResult(kind: i % 2 == 0 ? .gist : .source, recordId: h.id!, result: result, now: day(offset, hour: 20))
                }
                if offset % 4 == 0 {
                    try db.recordExamResult(kind: .argument, recordId: identity.id!, result: offset % 8 == 0 ? .partly : .remembered, now: day(offset, hour: 20))
                }
            }
            if let textBlock = try db.writer.read({ try Int64.fetchOne($0, sql: "SELECT id FROM notebook_block WHERE kind = 'text' ORDER BY id LIMIT 1") }) {
                try db.recordBlockRevisit(blockId: textBlock, outcome: .reread, now: day(-10, hour: 20))
                try db.recordBlockRevisit(blockId: textBlock, outcome: .reread, now: day(-3, hour: 20))
            }
            // 6.2：近几天写了回答的摘录题——一道判“记得”而要点只写出 1/4（自评偏高），其余对得上
            for (i, h) in highlights.prefix(6).enumerated() {
                let m = IdeaUnitMatch(units: (0..<4).map { IdeaUnit(text: "要点\($0 + 1)", hit: $0 <= i % 4) })
                try db.recordCalibration(kind: .highlight, recordId: h.id!, match: m, result: i % 3 == 0 ? .remembered : .partly,
                                         now: now.addingTimeInterval(-Double(i + 1) * 3_600))
            }
            // 6.1.1：一种带 HTML 模板的多字段笔记类型与两张卡（一个月后才到期，不进今天的卷子），便于检查卡片模板编辑窗
            try db.save(NoteTemplate(name: "人物（示例）", fieldNames: ["人名", "生卒", "要旨"], front: [0], back: [1, 2],
                                     html: NoteTemplateHTML(front: "<div class=\"who\">{{人名}}</div>",
                                                            back: "{{FrontSide}}<p class=\"years\">{{生卒}}</p>{{#要旨}}<div class=\"gist\">{{要旨}}</div>{{/要旨}}",
                                                            css: ".who { font-size: 30px; letter-spacing: .1em; } .years { color: #8a6d3b; } .gist { text-align: left; }")))
            for (name, years, gist) in [("顾炎武", "1613—1682", "经学即理学；行己有耻，博学于文"), ("戴震", "1724—1777", "由字通词，由词通道")] {
                var c = Card(deck: "学术史", front: name, back: gist, state: .review, interval: 30, due: day(30), reps: 3, createdAt: day(-40))
                c.noteType = "人物（示例）"; c.fields = [name, years, gist]
                _ = try db.save(c)
            }
            // 6.0.7：“默认”牌组绑一个带起始内容（HTML）的录入预设，新建卡片时可看到填进去的样子
            var preset = CardEntryPreset(name: "名词解释（示例）", sections: [.init(name: "背景"), .init(name: "意义")])
            preset.frontRule = .init(hint: "填写需要解释的概念或名词", required: true, html: "<h3>概念：</h3>")
            preset.backRule = .init(hint: "先用一句话概括，再列出关键要素", required: true,
                                    html: "<p><b>一句话：</b></p><ul><li>要素一：</li><li>要素二：</li></ul>")
            preset.sections[0].rule = .init(hint: "交代提出背景、时间或适用范围")
            preset.sections[1].rule = .init(hint: "说明历史地位、影响或概念边界", html: "<p><i>影响：</i></p>")
            try db.saveCardEntryPreset(preset)
            try db.setDeckEntryPreset(deck: "默认", presetID: preset.id)
            UserDefaults.standard.set(10, forKey: SettingsKeys.dailyCount)
            UserDefaults.standard.set(3, forKey: AnnotateSettings.perDayKey)
            UserDefaults.standard.removeObject(forKey: ExamFresh.perDayKey)
            // 每次打开都从“不限时长”开始（设置里改过的不带进下一次预览）
            UserDefaults.standard.removeObject(forKey: ExamSettings.minutesKey)
            // 6.4.0：示例里的问题簿、专题笔记本照正式库那样并入札记
            if NotesMergeSwitch.onOpen { _ = try db.mergeIntoIdeaNotes() }
            let store = LibraryStore(db: db, draftPersistence: nil, positionDefaults: nil)
            store.journeyNavigation.period = .week
            return store
        } catch { fatalError("预览示例库创建失败：\(error)") }
    }
}
