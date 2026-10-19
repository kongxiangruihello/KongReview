import Foundation
import GRDB
import KongReviewCore

enum ResolvedGlobalSearchTarget: Sendable {
    case highlight(Highlight, [Int64: String])
    case card(Card)
    case article(Article)
    case source(Source)
}

extension AppDatabase {
    /// 结果行可能在搜索后被编辑/删除；导航时重新读取完整记录，不使用预览文本替代正文。
    func resolveGlobalSearchTarget(_ target: GlobalSearchTarget) async throws -> ResolvedGlobalSearchTarget? {
        try await writer.read { db in
            switch target.kind {
            case .highlight:
                guard let item = try Highlight.fetchOne(db, key: target.recordID), item.deletedAt == nil else { return nil }
                let rows = try Row.fetchAll(db, sql: "SELECT sourceId, page FROM highlight_edition_page WHERE highlightId = ?",
                                            arguments: [target.recordID])
                var pages: [Int64: String] = [:]
                for row in rows { pages[row["sourceId"]] = row["page"] }
                return .highlight(item, pages)
            case .card:
                guard let item = try Card.fetchOne(db, key: target.recordID), item.deletedAt == nil else { return nil }
                return .card(item)
            case .article:
                return try Article.fetchOne(db, key: target.recordID).map { .article($0) }
            case .source:
                return try Source.fetchOne(db, key: target.recordID).map { .source($0) }
            }
        }
    }
}

extension LibraryStore {
    /// 避免命令菜单在其他面板打开时覆盖未保存的编辑内容。
    var canShowGlobalSearch: Bool {
        !showsResourceAudit && learningMaterialExport == nil && learningExplorer == nil && editorDraft == nil && cardEditor == nil && editingSource == nil && addArticleDraft == nil
            && articleSourceDraft == nil && batchPrompt == nil && exportRequest == nil && mergeRequest == nil
            && pendingImport == nil && cardImport == nil && duplicateReview == nil && duplicateCardReview == nil
            && deckOptionsEditor == nil && templateEditor == nil && apkgExport == nil && clozeDraft == nil
            && tagEditor == nil && !showTagManager && bibliographyRequest == nil && newNotebookRequest == nil
            && pageRange == nil && citationCheck == nil && editionImport == nil && chapterProgressRequest == nil
            && backupList == nil && !showsDraftRecovery && pendingDraftRecovery == nil
            && !fullBackupBusy && fullBackupRestore == nil && cardSyncOffer == nil
            && study.cardTagEdit == nil && notebookState.picker == nil && shareImageHighlight == nil
            && savingSearchName == nil
            && sourcePendingDeletion == nil && articlePendingDeletion == nil && notebookPendingDeletion == nil
            && sourcesPendingDeletion.isEmpty && !confirmingEmptyTrash && infoMessage == nil && errorMessage == nil
    }

    func showGlobalSearch() {
        guard canShowGlobalSearch, !globalSearch.isPresented else { return }
        globalSearch.present()
    }

    /// 搜索面板已经关闭后才弹出编辑面板，避免多个 sheet 同时争用主窗口。
    func openGlobalSearchResult(_ target: GlobalSearchTarget) {
        guard canShowGlobalSearch, !globalSearch.isPresented else { return }
        let token = UUID()
        globalSearch.navigationID = token
        let db = self.db
        Task { @MainActor in
            do {
                let result = try await db.resolveGlobalSearchTarget(target)
                guard globalSearch.navigationID == token, canShowGlobalSearch, !globalSearch.isPresented else { return }
                guard let result else {
                    errorMessage = "这项内容已被删除，请重新搜索。"
                    return
                }
                applyGlobalSearchTarget(result)
            } catch {
                guard globalSearch.navigationID == token else { return }
                report(error)
            }
        }
    }

    func applyGlobalSearchTarget(_ result: ResolvedGlobalSearchTarget) {
        guard canShowGlobalSearch else { return }
        switch result {
        case .highlight(let item, let pages):
            list.rememberEditing(item.id)
            var draft = HighlightDraft(highlight: item, tagsText: TagParser.format(item.tags))
            draft.editionPages = pages
            editorDraft = draft
        case .card(let item):
            study.rememberBrowsingCard(item.id)
            cardEditor = CardDraft(card: item, tagsText: TagParser.format(item.tags))
        case .article(let item):
            review.leaveCurrentEditor()
            articleList.rememberArticle(item.id)
            articleReading.open(articleID: item.id)
            openArticle = item
            selection = .articles
            if let id = item.id {
                let db = self.db
                Task.detached(priority: .utility) { try? db.markArticleOpened(id: id) }
            }
        case .source(let item):
            review.leaveCurrentEditor()
            if let id = item.id {
                list.activate(key: "highlights.source.\(id)")
                list.query = ""
                list.extra = ListFilter()
                list.showFilters = false
                selection = .source(id)
            }
        }
    }
}
