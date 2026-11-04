import XCTest
import GRDB
import KongReviewCore
@testable import KongReview

/// 6.2：答题时编辑试题——各类题的栏目、存下、返回更新后的题；必填为空不存
final class V620ExamEditTests: XCTestCase {
    private func set(_ r: ExamEditRequest, _ values: [String: String]) -> [ExamEditField] {
        r.fields.map { f in var f = f; if let v = values[f.id] { f.text = v }; return f }
    }

    func testEditCardsAndHighlight() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            // 普通卡：正面、背面
            let card = try db.save(Card(deck: "甲", front: "学而时习之", back: "不亦说乎"))
            let r1 = store.examEditRequest(.card(card))
            XCTAssertEqual(r1.fields.map(\.id), ["front", "back"])
            guard case .card(let c1)? = store.examSaveEdit(r1, fields: set(r1, ["back": "<b>不亦说乎</b>？"])) else { return XCTFail() }
            XCTAssertEqual(c1.back, "<b>不亦说乎</b>？")
            XCTAssertEqual(try db.card(id: card.id!)?.back, "<b>不亦说乎</b>？")
            XCTAssertEqual(c1.reps, card.reps, "不动排程")
            XCTAssertNil(store.examSaveEdit(r1, fields: set(r1, ["front": "  "])), "正面不能为空")
            XCTAssertEqual(try db.card(id: card.id!)?.front, "学而时习之")

            // 模板卡：按字段
            try db.save(NoteTemplate(name: "人物", fieldNames: ["人名", "要旨"], front: [0], back: [1]))
            store.reload()
            var t = Card(deck: "甲", front: "戴震", back: "")
            t.noteType = "人物"; t.fields = ["戴震", "由字通词"]
            t = try db.save(t)
            let r2 = store.examEditRequest(.card(t))
            XCTAssertEqual(r2.fields.map(\.label), ["人名", "要旨"])
            guard case .card(let c2)? = store.examSaveEdit(r2, fields: set(r2, ["f1": "由字通词，<mark>由词通道</mark>"])) else { return XCTFail() }
            XCTAssertEqual(c2.fields, ["戴震", "由字通词，<mark>由词通道</mark>"])

            // 摘录：原文、按语、位置；出题方式不变
            let h = try db.save(Highlight(text: "温故而知新", location: "为政"))
            let r3 = store.examEditRequest(.highlight(h, .gist))
            XCTAssertEqual(r3.fields.map(\.id), ["text", "note", "location"])
            XCTAssertFalse(r3.fields[2].html)
            guard case .highlight(let h3, let mode)? = store.examSaveEdit(r3, fields: set(r3, ["text": "温故而<b>知新</b>，可以为师矣", "note": "<p>按：</p>", "location": " 为政第二 "]))
            else { return XCTFail() }
            XCTAssertEqual(mode, .gist)
            XCTAssertEqual(h3.text, "温故而<b>知新</b>，可以为师矣")
            XCTAssertEqual(h3.location, "为政第二")
            XCTAssertEqual(try db.highlights(ids: [h.id!]).first?.note, "<p>按：</p>")
            // 按语删空即为空
            let r3b = store.examEditRequest(.highlight(h3, .gist))
            guard case .highlight(let h3b, _)? = store.examSaveEdit(r3b, fields: set(r3b, ["note": " "])) else { return XCTFail() }
            XCTAssertNil(h3b.note)
        }
    }

    func testEditNoteBlockQuestionAnswer() throws {
        try MainActor.assumeIsolated {
            let db = try AppDatabase(DatabaseQueue())
            let store = LibraryStore(db: db)
            // 札记
            let note = try db.createIdeaNote(title: "士以道自任", body: "<p>依据</p>")
            let item = try XCTUnwrap(try db.revisitNoteItem(id: note.id!))
            let r1 = store.examEditRequest(.note(item))
            guard case .note(let n)? = store.examSaveEdit(r1, fields: set(r1, ["title": "士以道自任（改）", "body": "<p>依据：<b>泰伯篇</b></p>"])) else { return XCTFail() }
            XCTAssertEqual(n.title, "士以道自任（改）")
            XCTAssertTrue(n.body.contains("泰伯篇"))
            XCTAssertNil(store.examSaveEdit(r1, fields: set(r1, ["title": ""])), "题目不能为空")

            // 笔记段落
            let nb = try db.createNotebook(title: "清代学术")
            let blocks = try db.insertBlocks([NotebookBlock(notebookId: nb.id!, position: 1, kind: .text, text: "戴震以考据为手段。")], into: nb.id!, after: nil)
            let b = try XCTUnwrap(try db.revisitBlockItem(id: blocks[0].id!))
            let r2 = store.examEditRequest(.block(b))
            guard case .block(let b2)? = store.examSaveEdit(r2, fields: set(r2, ["text": "戴震以考据为手段，<b>旨在重建义理</b>。"])) else { return XCTFail() }
            XCTAssertTrue(b2.text.contains("重建义理"))

            // 问题：进展题改题目、说明，解答不动
            let q = try db.createQuestion(title: "士的含义如何变化")
            try db.saveQuestion(id: q.id!, title: q.title, detail: "", answer: "<p>由身份到德行</p>")
            let progress = RevisitQuestionItem(id: q.id!, title: q.title, detail: "", status: .open, materialCount: 0,
                                               highlightIDs: [], lastReviewedAt: nil, createdAt: Date())
            let r3 = store.examEditRequest(.question(progress))
            guard case .question(let p3)? = store.examSaveEdit(r3, fields: set(r3, ["title": "“士”的含义如何变化？", "detail": "<p>先秦到汉</p>"])) else { return XCTFail() }
            XCTAssertEqual(p3.title, "“士”的含义如何变化？")
            let saved = try XCTUnwrap(try db.question(id: q.id!))
            XCTAssertEqual(saved.detail, "<p>先秦到汉</p>")
            XCTAssertEqual(saved.answer, "<p>由身份到德行</p>", "进展题不动解答")

            // 解答题：可改解答
            try db.setQuestionStatus(id: q.id!, .solved)
            let a = try XCTUnwrap(try db.answerItem(id: q.id!))
            let r4 = store.examEditRequest(.answer(a))
            XCTAssertEqual(r4.fields.map(\.id), ["title", "detail", "answer"])
            guard case .answer(let a4)? = store.examSaveEdit(r4, fields: set(r4, ["answer": "<p>由<b>身份</b>到<b>德行</b></p>"])) else { return XCTFail() }
            XCTAssertTrue(a4.answer.contains("<b>身份</b>"))
            XCTAssertEqual(try db.question(id: q.id!)?.status, .solved, "不改状态")
        }
    }
}
