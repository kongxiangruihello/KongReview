import Foundation
import KongReviewCore

// MARK: - 4.1.1：问题簿

/// 新建问题面板：预先归入的专题、项目，预先挂上的材料
struct QuestionCreateRequest: Identifiable, Sendable {
    var id = UUID()
    /// 5.0.1：预填的问题（复盘时把“困难”记为问题）
    var title = ""
    var notebookID: Int64?
    var projectID: Int64?
    var material: QuestionAttachRequest?
}

/// “挂到问题”面板：把一条摘录、札记或记忆卡挂到某个问题下
struct QuestionAttachRequest: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: QuestionMaterial.Kind
    var recordId: Int64
    /// 材料内容的开头，面板上显示
    var preview: String
}

extension LibraryStore {
    func refreshQuestions() {
        openQuestionCount = (try? db.openQuestionCount()) ?? 0
        questionRevision += 1
    }

    private func afterQuestionChange() {
        refreshQuestions()
        refreshRevisit()
        // 项目页“未解问题”、专题页“问题与解答”、复盘引导都读问题簿
        researchProjectRevision += 1
        journeyRevision += 1
    }

    /// 打开问题簿；可带一个筛选（如某项目的未解问题、本期已解决）
    func openQuestionBook(_ filter: QuestionFilter? = nil) {
        if let filter, filter != questionBookFilter { questionBookFilter = filter; questionBookPage = 0; questionBookAnchor = nil }
        selection = .questionBook
    }

    func newQuestion(notebookID: Int64? = nil, projectID: Int64? = nil, material: QuestionAttachRequest? = nil, title: String = "") {
        guard !fullBackupBusy else { return }
        questionCreator = QuestionCreateRequest(title: title, notebookID: notebookID, projectID: projectID, material: material)
    }

    @discardableResult
    func createQuestion(title: String, detail: String = "", notebookID: Int64? = nil, projectID: Int64? = nil,
                        material: QuestionAttachRequest? = nil, reason: String = "", open: Bool = false) -> Int64? {
        guard !fullBackupBusy else { return nil }
        var scopes: [(QuestionScope.Kind, Int64)] = []
        if let notebookID { scopes.append((.notebook, notebookID)) }
        if let projectID { scopes.append((.project, projectID)) }
        do {
            let q = try db.createQuestion(title: title, detail: detail, scopes: scopes,
                                          material: material.map { (kind: $0.kind, recordId: $0.recordId, reason: reason) })
            afterQuestionChange()
            if open, let id = q.id { selection = .question(id) }
            return q.id
        } catch { report(error); return nil }
    }

    @discardableResult
    func saveQuestion(id: Int64, title: String, detail: String, answer: String) -> Bool {
        guard !fullBackupBusy else { return false }
        do { try db.saveQuestion(id: id, title: title, detail: detail, answer: answer); afterQuestionChange(); return true }
        catch { report(error); return false }
    }

    func setQuestionStatus(_ id: Int64, _ status: Question.Status) {
        guard !fullBackupBusy else { return }
        do { try db.setQuestionStatus(id: id, status); afterQuestionChange() } catch { report(error) }
    }

    func setQuestionPinned(_ id: Int64, _ pinned: Bool) {
        guard !fullBackupBusy else { return }
        do { try db.setQuestionPinned(id: id, pinned); afterQuestionChange() } catch { report(error) }
    }

    func setQuestionAnswerNote(_ id: Int64, noteId: Int64?) {
        guard !fullBackupBusy else { return }
        do { try db.setQuestionAnswerNote(id: id, noteId: noteId); afterQuestionChange(); refreshIdeaNotes() } catch { report(error) }
    }

    func deleteQuestion(_ id: Int64) {
        guard !fullBackupBusy else { return }
        do {
            try db.deleteQuestion(id: id)
            if selection == .question(id) { selection = .questionBook }
            afterQuestionChange()
        } catch { report(error) }
    }

    func addQuestionMaterial(_ questionId: Int64, kind: QuestionMaterial.Kind, recordIds: [Int64], reason: String = "") {
        guard !fullBackupBusy, !recordIds.isEmpty else { return }
        do {
            for id in recordIds { try db.addQuestionMaterial(questionId: questionId, kind: kind, recordId: id, reason: reason) }
            afterQuestionChange()
        } catch { report(error) }
    }

    func removeQuestionMaterial(_ questionId: Int64, _ m: QuestionMaterial) {
        guard !fullBackupBusy else { return }
        do { try db.removeQuestionMaterial(questionId: questionId, kind: m.kind, recordId: m.recordId); afterQuestionChange() } catch { report(error) }
    }

    func setQuestionMaterialReason(_ questionId: Int64, _ m: QuestionMaterial, reason: String) {
        guard !fullBackupBusy, reason != m.reason else { return }
        do { try db.setQuestionMaterialReason(questionId: questionId, kind: m.kind, recordId: m.recordId, reason: reason); afterQuestionChange() } catch { report(error) }
    }

    func setQuestionScope(_ questionId: Int64, kind: QuestionScope.Kind, recordId: Int64, included: Bool) {
        guard !fullBackupBusy else { return }
        do { try db.setQuestionScope(questionId: questionId, kind: kind, recordId: recordId, included: included); afterQuestionChange() } catch { report(error) }
    }

    /// “写成札记”：新札记以问题为题、解答为正文，打开它
    func writeQuestionAsNote(_ id: Int64) {
        guard !fullBackupBusy else { return }
        do {
            let noteId = try db.writeQuestionAsNote(id: id)
            afterQuestionChange()
            refreshIdeaNotes()
            refreshLearningFocus()
            selection = .ideaNote(noteId)
        } catch { report(error) }
    }

    /// 回顾、记忆卡、编辑面板：“挂到问题”
    func attachToQuestion(kind: QuestionMaterial.Kind, recordId: Int64?, preview: String) {
        guard !fullBackupBusy, let recordId else { return }
        questionAttach = QuestionAttachRequest(kind: kind, recordId: recordId, preview: String(Markdown.plainText(fromHTML: preview).prefix(60)))
    }

    /// 挂着这些记录的问题（回顾卡片提示只看未解决的）
    func questionsHolding(_ kind: QuestionMaterial.Kind, _ ids: [Int64], unsolvedOnly: Bool = false) -> [Int64: [QuestionRef]] {
        _ = questionRevision
        return (try? db.questionsHolding(kind: kind, recordIDs: ids, unsolvedOnly: unsolvedOnly)) ?? [:]
    }

    // MARK: 草稿

    func saveQuestionDraft(_ draft: QuestionDraft) {
        guard !fullBackupBusy else { return }
        do {
            if draft.hasInput { try db.saveProgress(draft, key: draft.key) } else { try db.deleteProgress(key: draft.key) }
        } catch { report(error) }
    }

    func discardQuestionDraft(_ draft: QuestionDraft) {
        guard !fullBackupBusy else { return }
        do { try db.deleteProgress(key: draft.key); questionRevision += 1 } catch { report(error) }
    }

    /// 草稿：已有问题的去问题页继续编辑；尚未保存的新问题建成问题再打开
    func resumeQuestionDraft(_ draft: QuestionDraft) {
        guard !fullBackupBusy else { return }
        if let id = draft.questionId { selection = .question(id); return }
        do {
            let id = try db.restoreQuestionDraft(draft)
            afterQuestionChange()
            selection = .question(id)
        } catch { report(error) }
    }
}
