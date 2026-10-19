import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

final class V311BulkEntryTests: XCTestCase {
    private func database() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }
    private func candidate(_ front: String,_ back: String = "答案",line: Int = 1) -> CardBulkEntryCandidate {
        .init(line:line,values:[CardBulkEntryParser.html(front),CardBulkEntryParser.html(back)])
    }
    private var basic: CardBulkEntryConfiguration { .init(deck:"新牌组",mapping:[.front,.back]) }
    private func preview(_ db: AppDatabase,_ candidates: [CardBulkEntryCandidate],configuration: CardBulkEntryConfiguration? = nil,
                         selected: Set<UUID>? = nil) throws -> CardBulkEntryPreview {
        try db.previewCardBulkEntry(candidates:candidates,configuration:configuration ?? basic,
                                    selectedIDs:selected ?? Set(candidates.map(\.id)))
    }

    func testTSVRetainsQuotedMultilineAnswersTabsAndDoubledQuotes() throws {
        let text = "问题一\t\"答案第一行\n第二行\t同一单元格\"\n问题二\t\"带\"\"双引号\"\"\"\n"
        let parsed = CardBulkEntryParser.parse(text,format:.tabSeparated)
        XCTAssertTrue(parsed.issues.isEmpty)
        XCTAssertEqual(parsed.columnCount,2)
        XCTAssertEqual(parsed.rows.map(\.line),[1,3])
        XCTAssertEqual(parsed.rows.map(\.values),[["问题一","答案第一行\n第二行\t同一单元格"],["问题二","带\"双引号\""]])
        let candidates = try CardBulkEntryParser.candidates(parsed)
        XCTAssertTrue(candidates[0].values[1].contains("<br>\n第二行\t"))
    }

    func testMalformedTSVAndOversizedBatchBlockInsteadOfDiscardingRows() throws {
        let malformed = CardBulkEntryParser.parse("问题\t\"第一行\n没有闭合",format:.tabSeparated)
        XCTAssertEqual(malformed.issues.first?.line,1)
        XCTAssertThrowsError(try CardBulkEntryParser.candidates(malformed))
        let trailing = CardBulkEntryParser.parse("问题\t\"答案\"未分列",format:.tabSeparated)
        XCTAssertFalse(trailing.issues.isEmpty)
        let many = CardBulkEntryParser.parse((1...501).map { "问题\($0)\t答案" }.joined(separator:"\n"),format:.tabSeparated)
        XCTAssertEqual(many.rows.count,501)
        XCTAssertFalse(many.issues.isEmpty)
        XCTAssertThrowsError(try CardBulkEntryParser.candidates(many))
        let withHeader = CardBulkEntryParser.parse("题目\t答案\n" + (1...500).map { "问题\($0)\t答案" }.joined(separator:"\n"),
                                                 format:.tabSeparated,firstRowIsHeader:true)
        XCTAssertEqual(withHeader.rows.count,501)
        XCTAssertTrue(withHeader.issues.isEmpty)
    }

    func testQuestionAnswerGroupsPreserveContinuationAndReportUnownedLines() throws {
        let parsed = CardBulkEntryParser.parse("问：第一题\n答：第一段\n第二段\n\n第三段\n问:第二题\n答:第二答案",format:.questionAnswer)
        XCTAssertTrue(parsed.issues.isEmpty)
        XCTAssertEqual(parsed.rows.count,2)
        XCTAssertEqual(parsed.rows[0].values,["第一题","第一段\n第二段\n\n第三段"])
        XCTAssertEqual(parsed.rows[1].line,6)
        let malformed = CardBulkEntryParser.parse("孤立文字\n答：无问题\n问：只有问题",format:.questionAnswer)
        XCTAssertEqual(malformed.issues.map(\.line),[1,2,3])
        XCTAssertThrowsError(try CardBulkEntryParser.candidates(malformed))
        let repeated = CardBulkEntryParser.parse("问：题\n答：甲\n答：乙",format:.questionAnswer)
        XCTAssertFalse(repeated.issues.isEmpty)
        XCTAssertTrue(repeated.rows[0].values[1].contains("答：乙"))
    }

    func testHTMLIsPreservedAndPlainComparisonsAreEscaped() {
        let html = #"<p><a href="https://example.com">原样链接</a></p>"#
        XCTAssertEqual(CardBulkEntryParser.html(html),html)
        XCTAssertEqual(CardBulkEntryParser.html("1 < 2 & 3 > 1\n第二行"),"<p>1 &lt; 2 &amp; 3 &gt; 1<br>\n第二行</p>")
        XCTAssertEqual(CardBulkEntryParser.html(""),"")
    }

    func testEveryNonemptyColumnNeedsUniqueFieldMapping() throws {
        let row = CardBulkEntryCandidate(line:1,values:["问题","答案","不能遗漏"])
        var config = basic
        config.mapping.append(.unassigned)
        XCTAssertThrowsError(try config.makeCard(row,templates:[:]))
        config.mapping = [.front,.back,.back]
        XCTAssertThrowsError(try config.makeCard(row,templates:[:]))
        config.mapping = [.front,.back,.section(5)]
        XCTAssertThrowsError(try config.makeCard(row,templates:[:]))
    }

    func testPresetSectionMappingRequiredRulesAndHintsStayOutsideBody() throws {
        let db = try database()
        let preset = CardEntryPreset(name:"史料",deck:"预设牌组",tags:["默认标签"],
                                    sections:[.init(name:"出处",rule:.init(hint:"请写书名页码",required:true))])
        try db.saveCardEntryPreset(preset)
        let config = CardBulkEntryConfiguration(deck:"指定牌组",tags:["补充标签"],preset:preset,mapping:[.front,.back,.section(0)])
        let row = CardBulkEntryCandidate(line:1,values:["问题","答案",""])
        let missing = try preview(db,[row],configuration:config)
        XCTAssertFalse(missing.canSave)
        XCTAssertTrue(missing.items[0].issues.joined().contains("出处"))
        var filled = row
        filled.values[2] = "<p>《史记》卷一</p>"
        let saved = try db.saveCardBulkEntry(preview(db,[filled],configuration:config))
        XCTAssertEqual(saved.first?.deck,"指定牌组")
        XCTAssertEqual(Set(saved[0].tags),["默认标签","补充标签"])
        XCTAssertEqual(saved[0].sections?.first?.text,"<p>《史记》卷一</p>")
        XCTAssertFalse(String(data:try JSONEncoder().encode(saved[0]),encoding:.utf8)!.contains("请写书名页码"))
    }

    func testCrossDeckAndMediaAwareDuplicateRulesMatchSingleCardEntry() throws {
        let db = try database()
        _ = try db.save(Card(deck:"原牌组",front:"<b> Example  QUESTION </b>",back:"旧答案"))
        let duplicate = try preview(db,[candidate("  example question  ")])
        XCTAssertFalse(duplicate.canSave)
        XCTAssertTrue(duplicate.items[0].issues[0].contains("原牌组"))
        try db.writer.write { sql in
            try sql.execute(sql:"INSERT INTO card_media(name,data) VALUES(?,?),(?,?)",arguments:["a.png",Data([1,2]),"b.png",Data([1,2])])
        }
        _ = try db.save(Card(front:"<img src='a.png'>"))
        let image = try preview(db,[candidate("<img src='b.png'>")])
        XCTAssertFalse(image.canSave)
        XCTAssertNotNil(try db.duplicateCard(for:Card(front:"<img src='b.png'>")))
    }

    func testDeletedDuplicateIsVisibleAndCannotBeSilentlyRecreated() throws {
        let db = try database()
        _ = try db.save(Card(deck:"废弃题",front:"旧问题",deletedAt:Date()))
        let value = try preview(db,[candidate("旧问题")])
        XCTAssertFalse(value.canSave)
        XCTAssertTrue(value.items[0].issues[0].contains("最近删除"))
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        XCTAssertEqual(try db.cardCount(),0)
    }

    func testBatchDuplicatesCanBeResolvedByExplicitSelection() throws {
        let db = try database()
        let rows = [candidate("同一题",line:1),candidate("<strong>同一题</strong>",line:2)]
        let duplicate = try preview(db,rows)
        XCTAssertFalse(duplicate.canSave)
        XCTAssertTrue(duplicate.items[1].issues[0].contains("第 1 行"))
        XCTAssertThrowsError(try db.saveCardBulkEntry(duplicate))
        XCTAssertEqual(try db.cardCount(),0)
        let selected = try preview(db,rows,selected:[rows[1].id])
        XCTAssertTrue(selected.canSave)
        XCTAssertEqual(try db.saveCardBulkEntry(selected).count,1)
        XCTAssertEqual(try db.cardCount(),1)
    }

    func testSaveRechecksCollisionAndLeavesEntireBatchAndSourceUnchanged() throws {
        let db = try database()
        let rows = [candidate("新题一",line:1),candidate("新题二",line:2)]
        let value = try preview(db,rows)
        XCTAssertTrue(value.canSave)
        _ = try db.save(Card(deck:"刚添加",front:"新题二"))
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        XCTAssertEqual(try db.cardCount(),1)
        XCTAssertEqual(value.candidates,rows)
        XCTAssertEqual(try db.cards().first?.deck,"刚添加")
    }

    func testSaveRejectsPresetMutationAndDeletionAfterPreview() throws {
        let db = try database()
        var preset = CardEntryPreset(name:"预设",sections:[.init(name:"释义")])
        try db.saveCardEntryPreset(preset)
        let config = CardBulkEntryConfiguration(preset:preset,mapping:[.front,.back])
        let value = try preview(db,[candidate("新题")],configuration:config)
        let old = preset;preset.tags = ["刚修改"]
        try db.saveCardEntryPreset(preset,expected:old)
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        try db.deleteCardEntryPreset(id:preset.id)
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        XCTAssertEqual(try db.cardCount(),0)
    }

    func testTypedMappingUsesRenderedFrontAndRejectsDisplayTemplateChanges() throws {
        let db = try database()
        var template = NoteTemplate(name:"反向",fieldNames:["解释","题目"],front:[1],back:[0])
        try db.save(template)
        let preset = CardEntryPreset(name:"反向预设",noteType:template.name,fieldNames:template.fieldNames)
        try db.saveCardEntryPreset(preset)
        let config = CardBulkEntryConfiguration(preset:preset,mapping:[.field(1),.field(0)])
        _ = try db.save(Card(front:"题面"))
        let duplicate = try preview(db,[candidate("题面","另一答案")],configuration:config)
        XCTAssertFalse(duplicate.canSave)
        let valid = try preview(db,[candidate("新题面","答案")],configuration:config)
        XCTAssertTrue(valid.canSave)
        XCTAssertEqual(valid.items[0].card?.fields,["<p>答案</p>","<p>新题面</p>"])
        template.front = [0];template.back = [1]
        try db.save(template)
        XCTAssertThrowsError(try db.saveCardBulkEntry(valid))
        XCTAssertEqual(try db.cardCount(),1)
    }

    func testTransactionFailureRollsBackCardsAndPersistentEntryHistory() throws {
        let db = try database()
        let value = try preview(db,[candidate("题一"),candidate("题二",line:2)])
        try db.writer.write { sql in
            try sql.execute(sql:"CREATE TRIGGER bulk_test_abort BEFORE INSERT ON card WHEN NEW.front LIKE '%题二%' BEGIN SELECT RAISE(ABORT,'fixture abort'); END")
        }
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        XCTAssertEqual(try db.cardCount(),0)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM card_entry_record") },0)
        try db.writer.write { try $0.execute(sql:"DROP TRIGGER bulk_test_abort") }
        XCTAssertEqual(try db.saveCardBulkEntry(value).count,2)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM card_entry_record") },2)
    }

    func testRepeatedSaveAndForeignCandidateSelectionCannotCreateExtraCards() throws {
        let db = try database()
        let rows = [candidate("一次保存")]
        XCTAssertThrowsError(try preview(db,rows,selected:[UUID()]))
        var duplicateID = rows[0];duplicateID.values[0] = "不同内容"
        XCTAssertThrowsError(try preview(db,[rows[0],duplicateID]))
        let value = try preview(db,rows)
        XCTAssertEqual(try db.saveCardBulkEntry(value).count,1)
        XCTAssertThrowsError(try db.saveCardBulkEntry(value))
        XCTAssertEqual(try db.cardCount(),1)
    }
}
