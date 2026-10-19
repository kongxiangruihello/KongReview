import AppKit
import UniformTypeIdentifiers
import KongReviewCore

extension LibraryStore {
    func exportFullBackup() {
        guard canBeginFullBackup() else { return }
        let panel = NSSavePanel()
        panel.title = "导出完整备份"
        panel.allowedContentTypes = [UTType(filenameExtension: FullBackupService.fileExtension) ?? .data]
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "KongReview-\(date).\(FullBackupService.fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard canBeginFullBackup() else { return }
        do { try flushGrowthReflection?(); try draftPersistence?.flush() }
        catch { report(error); return }
        fullBackupBusy = true
        maintenanceProgress = "正在生成完整备份…"
        let db = self.db
        let draftURL = draftPersistence?.fileURL
        Task.detached(priority: .userInitiated) {
            do {
                try FullBackupService.create(db: db, draftURL: draftURL, defaults: .standard, destination: destination)
                await MainActor.run {
                    self.fullBackupBusy = false
                    self.maintenanceProgress = nil
                    self.infoMessage = "完整备份已保存为“\(destination.lastPathComponent)”。包含数据库、已存入应用的图片／音频、封面与网页缓存、编辑草稿和可迁移设置。可将这个文件拷贝到另一台 Mac，在 KongReview 中选择“恢复完整备份”。外部同步目录、尚未存档的远程资源不在备份内。"
                }
            } catch {
                await MainActor.run { self.fullBackupBusy = false; self.maintenanceProgress = nil; self.report(error) }
            }
        }
    }

    func chooseFullBackupRestore() {
        guard canBeginFullBackup() else { return }
        let panel = NSOpenPanel()
        panel.title = "选择完整备份"
        panel.allowedContentTypes = [UTType(filenameExtension: FullBackupService.fileExtension) ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard canBeginFullBackup() else { return }
        fullBackupBusy = true
        maintenanceProgress = "正在校验完整备份…"
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let prepared = try FullBackupService.prepare(url: url)
                await MainActor.run {
                    self.fullBackupBusy = false
                    self.maintenanceProgress = nil
                    self.fullBackupRestore?.cleanup()
                    WindowOpener.showMain()
                    self.fullBackupRestore = prepared
                }
            } catch {
                await MainActor.run { self.fullBackupBusy = false; self.maintenanceProgress = nil; self.report(error) }
            }
        }
    }

    func cancelFullBackupRestore() {
        fullBackupRestore?.cleanup()
        fullBackupRestore = nil
    }

    /// 只能由预览页的明确恢复确认调用。
    func confirmFullBackupRestore() {
        guard let prepared = fullBackupRestore, canBeginFullBackup(allowPrepared: true) else { return }
        do { try flushGrowthReflection?(); try draftPersistence?.flush() }
        catch { report(error); return }
        resourceAudit.reset(); showsResourceAudit = false
        growthGeneration += 1
        journeyNavigation = JourneyNavigation()
        invalidateDerivedStatistics()
        fullSimilarityTask?.cancel()
        fullSimilaritySession = nil
        fullBackupBusy = true
        maintenanceProgress = "正在保存恢复前的完整备份并恢复资料…"
        fullBackupRestore = nil
        let db = self.db
        let draftURL = draftPersistence?.fileURL
        Task.detached(priority: .userInitiated) {
            defer { prepared.cleanup() }
            do {
                let directory = try BackupService.directory()
                let safety = try FullBackupService.restore(prepared, db: db, draftURL: draftURL,
                                                          defaults: .standard, safetyDirectory: directory)
                await MainActor.run {
                    self.fullBackupBusy = false
                    self.maintenanceProgress = nil
                    self.finishFullBackupRestore()
                    self.infoMessage = "已恢复完整备份：\(prepared.counts.highlights) 条摘录、\(prepared.counts.cards) 张记忆卡，以及草稿和学习设置。\n恢复前的完整资料另存为“\(safety.lastPathComponent)”，位于备份文件夹，可用“恢复完整备份”重新打开。外部同步目录和本机权限保持原设置。"
                }
            } catch {
                await MainActor.run {
                    self.fullBackupBusy = false
                    self.maintenanceProgress = nil
                    // 服务已回滚；重载草稿及缓存，避免仍显示恢复尝试中的内容。
                    self.finishFullBackupRestore()
                    self.report(error)
                }
            }
        }
    }

    private func canBeginFullBackup(allowPrepared: Bool = false) -> Bool {
        guard allowPrepared || fullBackupRestore == nil else {
            infoMessage = "请先关闭当前完整备份预览。"
            return false
        }
        guard !fullBackupBusy, maintenanceProgress == nil, importProgress == nil,
              articleProgress == nil, !liquidTextChecking,
              notebookState.pendingSaves.isEmpty, notebookState.pendingNoteSaves.isEmpty else {
            infoMessage = "请等当前保存、导入或整理完成后，再操作完整备份。"
            return false
        }
        guard editorDraft == nil, cardEditor == nil, review.editorSession == nil,
              !hasBlockingFullBackupPanel else {
            infoMessage = "请先保存或关闭正在编辑的内容，再操作完整备份。关闭时保留的草稿也会包含在完整备份中。"
            return false
        }
        guard draftSaveError == nil else {
            infoMessage = "草稿尚未成功保存，请先处理草稿保存提示，再操作完整备份。"
            return false
        }
        return true
    }

    private var hasBlockingFullBackupPanel: Bool {
        showsResourceAudit || learningMaterialExport != nil || learningExplorer != nil || globalSearch.isPresented || editingSource != nil || templateEditor != nil || deckOptionsEditor != nil
            || study.cardTagEdit != nil || study.renamingDeck != nil || duplicateCardReview != nil || duplicateReview != nil
            || newNotebookRequest != nil || addArticleDraft != nil || articleSourceDraft != nil || clozeDraft != nil
            || backupList != nil || tagEditor != nil || showTagManager || bibliographyRequest != nil
            || pendingImport != nil || cardImport != nil || batchPrompt != nil || exportRequest != nil || mergeRequest != nil
            || apkgExport != nil || cardSyncOffer != nil || pageRange != nil || citationCheck != nil
            || editionImport != nil || chapterProgressRequest != nil || shareImageHighlight != nil
            || showsDraftRecovery || pendingDraftRecovery != nil || sourcePendingDeletion != nil || articlePendingDeletion != nil
            || notebookPendingDeletion != nil || !sourcesPendingDeletion.isEmpty || confirmingEmptyTrash || pendingRestore != nil
            || savingSearchName != nil || notebookState.picker != nil || notebookState.editingNote != nil
    }

    private func finishFullBackupRestore() {
        cardWorkflow.startSession()
        cardWorkflow.actionBusy = false
        flushGrowthReflection = nil
        undoManager?.removeAllActions()
        do { try draftPersistence?.reloadFromDisk(); draftSaveError = nil }
        catch { draftSaveError = "完整资料已恢复，但草稿暂未能读取：" + error.localizedDescription }
        highlightDraftSessionID = nil
        cardDraftSessionID = nil
        draftRecoveryNotice = nil
        pendingDraftRecovery = nil
        draftPendingDiscard = nil
        draftRevision += 1
        review.suppressEditorRecording = true
        review.editorSession = nil
        review.noteDraft = nil
        review.inlineDraft = nil
        review.volatileDrafts = [:]
        review.cards = []
        review.position = 0
        review.theme = nil
        review.day = ""
        review.sessionToken += 1
        review.suppressEditorRecording = false
        review.showRelated = UserDefaults.standard.bool(forKey: "review.showRelated")
        notebookState = NotebookState()
        openArticle = nil
        duplicateReview = nil
        duplicateCardReview = nil
        weeklyDigestCache = nil
        heatmapCache = nil
        coverRevision += 1
        clearCardRatingUndo()
        list.loadID = UUID()
        list.items = []
        list.selection = []
        list.pendingSelection = nil
        list.anchorID = nil
        list.lastQuery = nil
        list.page = 1
        list.pageInput = "1"
        sourceSort = SourceSort.current
        sourcesExpanded = UserDefaults.standard.bool(forKey: "sidebar.sourcesExpanded")
        tagsExpanded = UserDefaults.standard.bool(forKey: "sidebar.tagsExpanded")
        study.showContext = UserDefaults.standard.bool(forKey: "study.showContext")
        openCardsHome()
        selection = .home
        reload()
        HotKeyCenter.shared.apply(HotKeyPreset.current)
        HotKeyCenter.shared.applyLookup(HotKeyPreset.lookup)
        StatusItemController.shared.apply()
        ReminderScheduler.shared.applySavedSettings()
    }
}
