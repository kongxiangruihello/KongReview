import Foundation
import GRDB
import KongReviewCore

/// 3.14：界面预览用的独立示例库。只有另行打包、标识为 `com.kongxiangrui.KongReview.Preview` 的应用会进入这里；
/// 数据全部在内存中，设置写在该标识自己的偏好域，不读写个人学习库。正式应用不会进入这条路径。
@MainActor enum PreviewLibrary {
    static var isEnabled: Bool { Bundle.main.bundleIdentifier == "com.kongxiangrui.KongReview.Preview" }

    static func makeStore() -> LibraryStore {
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
            try db.setLearningFocus(LearningFocus(kind: .notebook, id: notebook.id!, title: notebook.title, startedAt: day(-2)))
            // 今日回顾：一组 10 条，已回顾 4 条；当前第 5 条为“重读原文”
            let others = highlights.prefix(10).compactMap(\.id).filter { $0 != highlights[5].id! }
            let ids = Array(others.prefix(4)) + [highlights[5].id!] + Array(others.dropFirst(4).prefix(5))
            for id in ids.prefix(4) { db.log(ReviewEvent(kind: .keep, highlightId: id, at: now.addingTimeInterval(-600))) }
            let record = ReviewSessionRecord(day: ReviewSessionRecord.dayString(now), regularIds: Array(ids), masteryIds: [], position: 4)
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
            UserDefaults.standard.set(10, forKey: SettingsKeys.dailyCount)
            let store = LibraryStore(db: db, draftPersistence: nil, positionDefaults: nil)
            store.journeyNavigation.period = .week
            return store
        } catch { fatalError("预览示例库创建失败：\(error)") }
    }
}
