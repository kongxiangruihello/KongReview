import Foundation
import KongReviewCore

struct EditorDraftSelection: Identifiable {
    enum Kind { case highlight, card }
    var id: UUID
    var kind: Kind
}

extension LibraryStore {
    var savedHighlightDrafts: [SavedHighlightDraft] { _ = draftRevision; return draftPersistence?.highlightDrafts ?? [] }
    var savedCardDrafts: [SavedCardDraft] { _ = draftRevision; return draftPersistence?.cardDrafts ?? [] }

    func persistHighlightEditorDraft() {
        guard let value = editorDraft, let persistence = draftPersistence else { return }
        do {
            let first = highlightDraftSessionID != value.id
            if first { draftRecoveryNotice = nil }
            let original = first ? try value.highlight.id.flatMap { try db.highlight(id: $0) } : nil
            let pages = first ? try value.highlight.id.map { try db.editionPages($0) } : nil
            try persistence.recordHighlight(value, original: original, originalEditionPages: pages)
            highlightDraftSessionID = value.id
            draftSaveError = nil
            draftRevision += 1
        } catch { draftSaveError = "草稿暂未能保存：" + error.localizedDescription }
    }

    func persistCardEditorDraft() {
        guard let value = cardEditor, let persistence = draftPersistence else { return }
        do {
            if cardDraftSessionID != value.id { draftRecoveryNotice = nil }
            let original = cardDraftSessionID != value.id ? try value.card.id.flatMap { try db.card(id: $0) } : nil
            try persistence.recordCard(value, original: original)
            cardDraftSessionID = value.id
            draftSaveError = nil
            draftRevision += 1
        } catch { draftSaveError = "草稿暂未能保存：" + error.localizedDescription }
    }

    func finishHighlightEditorDraft(id: UUID) {
        do { try draftPersistence?.removeHighlight(id: id); draftRevision += 1 }
        catch { draftSaveError = "正式内容已保存，旧草稿暂未能清除：" + error.localizedDescription }
    }
    func finishCardEditorDraft(id: UUID) {
        do { try draftPersistence?.removeCard(id: id); draftRevision += 1 }
        catch { draftSaveError = "正式内容已保存，旧草稿暂未能清除：" + error.localizedDescription }
    }

    func requestCloseHighlightEditor() {
        guard let draft = editorDraft else { return }
        if savedHighlightDrafts.contains(where: { $0.id == draft.id }) || draftSaveError != nil {
            closingHighlightEditor = true
        } else { editorDraft = nil }
    }
    func requestCloseCardEditor() {
        guard let draft = cardEditor else { return }
        if savedCardDrafts.contains(where: { $0.id == draft.id }) || draftSaveError != nil {
            closingCardEditor = true
        } else { cardEditor = nil }
    }
    func keepAndCloseEditor(_ kind: EditorDraftSelection.Kind) {
        guard draftPersistence != nil else { return }
        switch kind {
        case .highlight: persistHighlightEditorDraft()
        case .card: persistCardEditorDraft()
        }
        guard draftSaveError == nil else { return }
        do {
            try draftPersistence?.flush()
            switch kind {
            case .highlight: editorDraft = nil; closingHighlightEditor = false
            case .card: cardEditor = nil; closingCardEditor = false
            }
        } catch { draftSaveError = "草稿暂未能保存：" + error.localizedDescription }
    }
    func discardAndCloseEditor(_ kind: EditorDraftSelection.Kind) {
        do {
            switch kind {
            case .highlight:
                if let draft = editorDraft { try draftPersistence?.removeHighlight(id: draft.id) }
                editorDraft = nil; closingHighlightEditor = false
            case .card:
                if let draft = cardEditor { try draftPersistence?.removeCard(id: draft.id) }
                cardEditor = nil; closingCardEditor = false
            }
            draftRevision += 1
        } catch { draftSaveError = error.localizedDescription }
    }

    func scheduleDraftRecovery(id: UUID, kind: EditorDraftSelection.Kind) {
        pendingDraftRecovery = EditorDraftSelection(id: id, kind: kind)
        showsDraftRecovery = false
    }
    func performPendingDraftRecovery() {
        guard let selected = pendingDraftRecovery else { return }
        pendingDraftRecovery = nil
        do {
            switch selected.kind {
            case .highlight:
                guard let saved = savedHighlightDrafts.first(where: { $0.id == selected.id }) else { return }
                let current = try saved.highlight.id.flatMap { try db.highlight(id: $0) }
                let pages = try saved.highlight.id.map { try db.editionPages($0) } ?? [:]
                var recovered = saved.restored(current: current, currentEditionPages: pages)
                var notices = recovered.notice.map { [$0] } ?? []
                if let sourceID = recovered.draft.highlight.sourceId, !sources.contains(where: { $0.id == sourceID }) {
                    recovered.draft.highlight.sourceId = nil
                    notices.append("原出处已删除，这份草稿恢复到未归类。")
                }
                let validSources = Set(sources.compactMap(\.id))
                let missingPages = recovered.draft.editionPages.filter { !validSources.contains($0.key) && !$0.value.isEmpty }
                if !missingPages.isEmpty {
                    let lines = missingPages.sorted { $0.key < $1.key }.map { "版本 #\($0.key)：\($0.value)" }
                    let retained = "恢复草稿的版本页码（原版本已删除）：\n" + lines.joined(separator: "\n")
                    recovered.draft.highlight.note = [recovered.draft.highlight.note, retained]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    notices.append("已删除版本的未保存页码保留在按语中。")
                }
                recovered.draft.editionPages = recovered.draft.editionPages.filter { validSources.contains($0.key) }
                editorDraft = recovered.draft
                draftRecoveryNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            case .card:
                guard let saved = savedCardDrafts.first(where: { $0.id == selected.id }) else { return }
                let current = try saved.card.id.flatMap { try db.card(id: $0) }
                var recovered = saved.restored(current: current)
                var notices = recovered.notice.map { [$0] } ?? []
                if let highlightID = recovered.draft.card.highlightId, try db.highlight(id: highlightID) == nil {
                    recovered.draft.card.highlightId = nil
                    notices.append("关联的原摘录已删除，恢复的卡片已解除关联。")
                }
                cardEditor = recovered.draft
                draftRecoveryNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            }
        } catch { report(error) }
    }
    func discardSavedDraft() {
        guard let selected = draftPendingDiscard else { return }
        do {
            switch selected.kind {
            case .highlight: try draftPersistence?.removeHighlight(id: selected.id)
            case .card: try draftPersistence?.removeCard(id: selected.id)
            }
            draftPendingDiscard = nil
            draftRevision += 1
        } catch { report(error) }
    }
}
