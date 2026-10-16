import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V24ExperienceTests: XCTestCase {
    func testEveryHighlightIsReachableAcrossPagesAndFilters() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let source = try db.save(Source(title: "已归类"))
        let records = (0..<451).map { Highlight(sourceId: $0.isMultiple(of: 2) ? source.id : nil,
                                              text: "分页测试第\($0)条", createdAt: Date(timeIntervalSince1970: 1000)) }
        try db.save(records)
        for query in [HighlightQuery(), HighlightQuery(unsortedOnly: true)] {
            let expected = try db.highlights(query).compactMap(\.id)
            var loaded: [Int64] = []
            for offset in stride(from: 0, to: expected.count, by: ListState.pageSize) {
                let page = try await db.highlightPage(query, limit: ListState.pageSize, offset: offset)
                XCTAssertEqual(page.total, expected.count)
                XCTAssertLessThanOrEqual(page.items.count, ListState.pageSize)
                loaded += page.items.compactMap(\.id)
            }
            XCTAssertEqual(loaded, expected)
            XCTAssertEqual(Set(loaded).count, expected.count)
        }
        let searched = try await db.highlightPage(HighlightQuery(text: "第450条"), limit: 200, offset: 0)
        XCTAssertEqual(searched.total, 1)
        XCTAssertEqual(searched.items.first?.text, "分页测试第450条")
    }

    func testEditingRefreshesFullOriginalInsteadOfListPreview() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let original = String(repeating: "完整原文不能被列表预览截断。", count: 1000)
            let saved = try db.save(Highlight(text: original, translation: "译文", note: "按语"))
            let store = LibraryStore(db: db)
            var preview = saved
            preview.text = ""
            preview.note = nil
            store.edit(preview)
            XCTAssertEqual(store.editorDraft?.highlight.text, original)
            XCTAssertEqual(store.editorDraft?.highlight.note, "按语")
            XCTAssertEqual(store.editorDraft?.highlight.translation, "译文")
        }
    }

    func testManualCardDuplicateIsRejectedButOriginalCanBeEdited() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let first = try db.save(Card(deck: "甲", front: "问题", back: "答案"))
            let store = LibraryStore(db: db)
            store.cardEditor = CardDraft(card: Card(deck: "乙", front: " 问题\n", back: "答案 "))
            store.commitCardEditor()
            XCTAssertEqual(try db.cardCount(), 1)
            XCTAssertNotNil(store.cardEditor?.error)
            XCTAssertEqual(store.cardEditor?.card.front, " 问题\n", "被拦截后保留输入草稿")
            store.editCard(first)
            store.commitCardEditor()
            XCTAssertNil(store.cardEditor)
            XCTAssertEqual(try db.cardCount(), 1)
            store.cardEditor = CardDraft(card: Card(front: "问题", back: "不同答案"))
            store.commitCardEditor()
            XCTAssertEqual(try db.cardCount(), 2)
        }
    }

    func testDifferentBackSectionsAreNotDuplicateAnswers() throws {
        let db = try AppDatabase(DatabaseQueue())
        var first = Card(front: "行", back: "")
        first.sections = [CardSection(name: "释义", text: "xíng：走")]
        first = try db.save(first)
        var second = Card(front: "行", back: "")
        second.sections = [CardSection(name: "释义", text: "háng：行列")]
        XCTAssertNil(try db.duplicateCard(for: second))
        second.sections = [CardSection(name: "释义", text: "xíng：走")]
        XCTAssertEqual(try db.duplicateCard(for: second)?.id, first.id, "栏目 UUID 不应妨碍查重")
    }

    func testHomeCountsDoNotHideHighlightsAfterStudyingCards() throws {
        try MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let key = ReviewSessionRecord.key(theme: nil)
            let savedSession = defaults.object(forKey: key)
            let savedDaily = defaults.object(forKey: SettingsKeys.dailyCount)
            defer {
                if let savedSession { defaults.set(savedSession, forKey: key) } else { defaults.removeObject(forKey: key) }
                if let savedDaily { defaults.set(savedDaily, forKey: SettingsKeys.dailyCount) } else { defaults.removeObject(forKey: SettingsKeys.dailyCount) }
            }
            defaults.removeObject(forKey: key)
            defaults.set(10, forKey: SettingsKeys.dailyCount)
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            XCTAssertEqual(store.selection, .home)
            XCTAssertEqual(store.todayCounts().highlights, 0)
            let highlights = try (0..<5).map { try db.save(Highlight(text: "摘录\($0)")) }
            let muted = try db.save(Source(title: "不回顾", reviewWeight: 0))
            _ = try db.save(Highlight(sourceId: muted.id, text: "不计入"))
            store.reviewedToday = true
            XCTAssertEqual(store.todayCounts().highlights, 5)
            ReviewSessionRecord(day: ReminderPlan.dayKey(Date()), regularIds: highlights.compactMap(\.id),
                                masteryIds: [], position: 2).save(key: key)
            XCTAssertEqual(store.todayCounts().highlights, 3)
            try db.deletePermanently(highlights[0])
            XCTAssertEqual(store.todayCounts().highlights, 3, "删除已看条目不能减少未看条数")
            let record = ReviewSessionRecord(day: ReminderPlan.dayKey(Date()),
                regularIds: highlights.compactMap(\.id), masteryIds: [], position: 2)
            XCTAssertEqual(record.resumePosition(existingIDs: Set(highlights.dropFirst().compactMap(\.id))), 1)
        }
    }
}
