import Foundation
import KongReviewCore

// MARK: - 6.2：答题时编辑试题（HTML）
//
// 卷面上每道题都能当场改：记忆卡的正面、背面（模板卡按字段），摘录的原文、按语、位置，札记的题目、正文，
// 笔记段落，问题的题目、说明、解答。正文类一律给 HTML 源码框与即时预览。改完回到卷面，展开与否、“我的回答”都不动；
// 只改内容，不动排程与作答记录。

/// 编辑试题里的一栏
struct ExamEditField: Identifiable, Equatable {
    var id: String
    var label: String
    var text: String
    /// 正文类（HTML 源码框 + 预览）；否则一行文字
    var html = true
    /// 不能为空
    var required = false
}

/// 一次编辑：哪道题、有哪些栏
struct ExamEditRequest: Identifiable {
    let id = UUID()
    let question: ExamQuestion
    var fields: [ExamEditField]
}

extension LibraryStore {
    /// 这道题能编辑的各栏（现有内容）
    func examEditRequest(_ q: ExamQuestion) -> ExamEditRequest {
        switch q {
        case .card(let c):
            if let type = c.noteType, !c.fields.isEmpty {
                let names = noteTemplates[type]?.fieldNames ?? []
                return ExamEditRequest(question: q, fields: c.fields.indices.map { i in
                    ExamEditField(id: "f\(i)", label: i < names.count ? names[i] : "字段\(i + 1)", text: c.fields[i], required: i == 0)
                })
            }
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "front", label: "正面", text: c.front, required: true),
                ExamEditField(id: "back", label: "背面", text: c.back),
            ])
        case .highlight(let h, _):
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "text", label: "原文", text: h.text, required: true),
                ExamEditField(id: "note", label: "按语", text: h.note ?? ""),
                ExamEditField(id: "location", label: "位置", text: h.location ?? "", html: false),
            ])
        case .note(let n):
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "title", label: "题目", text: n.title, html: false, required: true),
                ExamEditField(id: "body", label: "正文", text: n.body),
            ])
        case .block(let b):
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "text", label: "正文（《\(b.notebookTitle)》）", text: b.text, required: true),
            ])
        case .question(let item):
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "title", label: "问题", text: item.title, html: false, required: true),
                ExamEditField(id: "detail", label: "说明", text: item.detail),
            ])
        case .answer(let a):
            return ExamEditRequest(question: q, fields: [
                ExamEditField(id: "title", label: "问题", text: a.title, html: false, required: true),
                ExamEditField(id: "detail", label: "说明", text: a.detail),
                ExamEditField(id: "answer", label: "解答", text: a.answer),
            ])
        }
    }

    /// 存下改过的各栏，返回更新后的这道题（失败返回 nil，错误已报告）
    func examSaveEdit(_ request: ExamEditRequest, fields: [ExamEditField], now: Date = Date()) -> ExamQuestion? {
        guard !fullBackupBusy else { return nil }
        if let empty = fields.first(where: { $0.required && !HTMLSourceCodec.hasContent($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            report(ExamEditError.empty(empty.label)); return nil
        }
        func value(_ id: String) -> String { fields.first { $0.id == id }?.text ?? "" }
        func trimmed(_ id: String) -> String { value(id).trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            switch request.question {
            case .card(var c):
                if c.noteType != nil, !c.fields.isEmpty {
                    c.fields = c.fields.indices.map { i in fields.first { $0.id == "f\(i)" }?.text ?? c.fields[i] }
                } else {
                    c.front = value("front"); c.back = value("back")
                }
                c.updatedAt = now
                let saved = try db.save(c)
                revisionBump()
                return .card(saved)
            case .highlight(var h, let mode):
                h.text = value("text")
                h.note = trimmed("note").isEmpty ? nil : value("note")
                h.location = trimmed("location").isEmpty ? nil : trimmed("location")
                h.updatedAt = now
                let saved = try db.save(h)
                reload()
                return .highlight(saved, mode)
            case .note(let n):
                guard saveIdeaNote(id: n.id, title: trimmed("title"), body: value("body")) else { return nil }
                return (try db.revisitNoteItem(id: n.id)).map { .note($0) }
            case .block(let b):
                try db.updateBlockText(b.id, text: value("text"), now: now)
                refreshNotebookHighlights()
                return (try db.revisitBlockItem(id: b.id)).map { .block($0) }
            case .question(var item):
                let answer = try db.question(id: item.id)?.answer ?? ""
                guard saveQuestion(id: item.id, title: trimmed("title"), detail: value("detail"), answer: answer) else { return nil }
                item.title = trimmed("title"); item.detail = value("detail")
                return .question(item)
            case .answer(let a):
                guard saveQuestion(id: a.id, title: trimmed("title"), detail: value("detail"), answer: value("answer")) else { return nil }
                return (try db.answerItem(id: a.id)).map { .answer($0) } ?? .answer(a)
            }
        } catch { report(error); return nil }
    }
}

enum ExamEditError: LocalizedError {
    case empty(String)
    var errorDescription: String? {
        switch self { case .empty(let label): "“\(label)”不能为空。" }
    }
}

extension LibraryStore {
    /// 6.3.2：记忆卡、摘录在原来的编辑窗口里改过之后，按 id 重新取一遍（删去了、或不是这两类则返回 nil，卷面不动）
    func examRefreshed(_ q: ExamQuestion) -> ExamQuestion? {
        switch q {
        case .card(let c):
            guard let id = c.id, let fresh = try? db.card(id: id), fresh.deletedAt == nil else { return nil }
            return .card(fresh)
        case .highlight(let h, let mode):
            guard let id = h.id, let fresh = try? db.highlight(id: id), fresh.deletedAt == nil else { return nil }
            return .highlight(fresh, mode)
        default:
            return nil
        }
    }
}
