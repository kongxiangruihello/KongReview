import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V245SourcePagingTests: XCTestCase {
    private let defaultSort = [SourcePageSort(.count, descending: true)]

    func testAll451SourcesAreReachableWithStableTies() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let ids = try await db.writer.write { connection in
            try (0..<451).map { index -> Int64 in
                var source = Source(title: "书目\(index)", createdAt: Date(timeIntervalSince1970: 1000))
                try source.insert(connection)
                return source.id!
            }
        }
        var seen: [Int64] = []
        for page in 1...3 {
            let result = try await db.sourcePage(query: "", onlyDuplicates: false,
                sorts: defaultSort, page: page)
            XCTAssertEqual(result.total, 451)
            XCTAssertEqual(result.page, page)
            XCTAssertEqual(result.items.count, page == 3 ? 51 : 200)
            seen += result.items.map(\.id)
        }
        XCTAssertEqual(seen, ids)
        XCTAssertEqual(Set(seen).count, 451)
    }

    func testAllTableColumnsSortBeforePaginationAndExcludeDeletedHighlightsFromCounts() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Source(title: "丙", author: "甲", kind: .web, createdAt: Date(timeIntervalSince1970: 3000)))
        let b = try db.save(Source(title: "乙", author: "丙", kind: .book, createdAt: Date(timeIntervalSince1970: 1000)))
        let c = try db.save(Source(title: "甲", author: "乙", kind: .pdf, createdAt: Date(timeIntervalSince1970: 2000)))
        let d = try db.save(Source(title: "甲", author: "乙", kind: .pdf, createdAt: Date(timeIntervalSince1970: 2000)))
        try db.save(Highlight(sourceId: a.id, text: "保留", isDiscarded: true))
        try db.save(Highlight(sourceId: b.id, text: "第一条"))
        try db.save(Highlight(sourceId: b.id, text: "第二条"))
        try db.save(Highlight(sourceId: c.id, text: "已删除", deletedAt: Date()))
        let all = [SourceRow(id: a.id!, source: a, count: 1), SourceRow(id: b.id!, source: b, count: 2),
                   SourceRow(id: c.id!, source: c, count: 0), SourceRow(id: d.id!, source: d, count: 0)]
        for field in [SourcePageSort.Field.title, .author, .kind, .count, .createdAt] {
            for descending in [false, true] {
                let sort = SourcePageSort(field, descending: descending)
                let expected = all.sorted {
                    let comparison = sort.comparator.compare($0, $1)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
                var actual: [SourceRow] = []
                for page in 1...2 {
                    let result = try await db.sourcePage(query: "", onlyDuplicates: false,
                        sorts: [sort], page: page, pageSize: 2)
                    actual += result.items
                }
                XCTAssertEqual(actual, expected, "\(field), descending: \(descending)")
            }
        }
    }

    func testSearchMatchesTitleOrAuthorAndTreatsWildcardsLiterally() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let title = try db.save(Source(title: "Modern History"))
        let author = try db.save(Source(title: "其他", author: "MODERN研究者"))
        let literal = try db.save(Source(title: "100%_完成"))
        try db.save(Source(title: "100个完成"))
        let matches = try await db.sourcePage(query: " \nmodern  ", onlyDuplicates: false,
            sorts: defaultSort, page: 99, pageSize: 1)
        XCTAssertEqual(matches.total, 2)
        XCTAssertEqual(matches.page, 2)
        XCTAssertEqual(matches.items.map(\.id), [author.id!])
        let first = try await db.sourcePage(query: "modern", onlyDuplicates: false,
            sorts: defaultSort, page: 1, pageSize: 1)
        XCTAssertEqual(first.items.map(\.id), [title.id!])
        let wildcards = try await db.sourcePage(query: "%_", onlyDuplicates: false,
            sorts: defaultSort, page: 1)
        XCTAssertEqual(wildcards.items.map(\.id), [literal.id!])
        let empty = try await db.sourcePage(query: "不存在", onlyDuplicates: false,
            sorts: defaultSort, page: 999)
        XCTAssertEqual(empty.page, 1)
        XCTAssertEqual(empty.total, 0)
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testDuplicatesAreMarkedAcrossPagesAndRemainMarkedWhenSearchHidesTheirPartner() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let first = try db.save(Source(title: "《历史研究》", author: "原作者"))
        try await db.writer.write { connection in
            for index in 0..<449 {
                var source = Source(title: "独立书目\(index)")
                try source.insert(connection)
            }
        }
        let last = try db.save(Source(title: "历史研究（修订本）", author: "新作者"))
        let head = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 1)
        let tail = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 3)
        XCTAssertEqual(head.duplicateIDs, [first.id!])
        XCTAssertEqual(tail.duplicateIDs, [last.id!])
        XCTAssertEqual(head.duplicateCount, 2)
        XCTAssertEqual(tail.duplicateCount, 2)
        let searched = try await db.sourcePage(query: "新作者", onlyDuplicates: true,
            sorts: defaultSort, page: 1)
        XCTAssertEqual(searched.items.map(\.id), [last.id!])
        XCTAssertEqual(searched.duplicateIDs, [last.id!])
        XCTAssertEqual(searched.total, 1)
        XCTAssertEqual(searched.duplicateCount, 2)
    }

    func testDuplicateFilterGroupsByNormalizedTitleThenCountWithStableTies() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let a = try db.save(Source(title: "甲书"))
        let b = try db.save(Source(title: "甲书（修订本）"))
        let c = try db.save(Source(title: "乙书"))
        let d = try db.save(Source(title: "《乙书》"))
        try db.save(Source(title: "单独书目"))
        try db.save(Highlight(sourceId: b.id, text: "有摘录"))
        let pairs = [(a, 0), (b, 1), (c, 0), (d, 0)]
        let expected = pairs.sorted {
            let left = SourceDedup.key($0.0.title), right = SourceDedup.key($1.0.title)
            if left != right { return left < right }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id! < $1.0.id!
        }.map { $0.0.id! }
        var seen: [Int64] = []
        for page in 1...4 {
            let result = try await db.sourcePage(query: "", onlyDuplicates: true,
                sorts: [SourcePageSort(.createdAt, descending: true)], page: page, pageSize: 1)
            XCTAssertEqual(result.total, 4)
            seen += result.items.map(\.id)
        }
        XCTAssertEqual(seen, expected)
    }

    func testDeletingAndMergingTheLastPageClampsPageAndRecounts() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let ids = try await db.writer.write { connection in
            try (0..<401).map { index -> Int64 in
                var source = Source(title: "书目\(index)")
                try source.insert(connection)
                return source.id!
            }
        }
        let last = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 3)
        XCTAssertEqual(last.items.map(\.id), [ids.last!])
        try db.deleteSources([ids.last!])
        let afterDeletion = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 3)
        XCTAssertEqual(afterDeletion.page, 2)
        XCTAssertEqual(afterDeletion.total, 400)
        XCTAssertEqual(afterDeletion.items.count, 200)
        try db.save(Highlight(sourceId: ids[399], text: "合并后归入第一个出处"))
        try db.mergeSources([ids[0], ids[399]], into: ids[0])
        let afterMerge = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 3)
        XCTAssertEqual(afterMerge.page, 2)
        XCTAssertEqual(afterMerge.total, 399)
        XCTAssertEqual(afterMerge.items.count, 199)
        let first = try await db.sourcePage(query: "", onlyDuplicates: false, sorts: defaultSort, page: 1)
        XCTAssertEqual(first.items.first?.id, ids[0])
        XCTAssertEqual(first.items.first?.count, 1)
    }

    func testPageNavigationClearsSelectionAndInvalidatesPendingLoads() {
        MainActor.assumeIsolated {
            let state = SourceManagerState()
            let source = Source(id: 1, title: "当前页")
            state.items = [SourceRow(id: 1, source: source, count: 0)]
            state.total = 451
            state.selection = [1]
            let previousLoad = state.loadID
            state.goToPage(999)
            XCTAssertEqual(state.page, 3)
            XCTAssertEqual(state.pageInput, "3")
            XCTAssertTrue(state.selection.isEmpty)
            XCTAssertTrue(state.items.isEmpty)
            XCTAssertNotEqual(state.loadID, previousLoad)
            state.goToPage(-1)
            XCTAssertEqual(state.page, 1)
        }
    }
}
