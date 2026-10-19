import SwiftUI
import KongReviewCore

struct CardBulkEntryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialDeck: String? = nil
    var onEditOriginal: ((UUID,Int64) -> Void)? = nil
    var onSaved: ([Card]) -> Void
    @State private var source = ""
    @State private var format = CardBulkEntryFormat.tabSeparated
    @State private var firstRowIsHeader = false
    @State private var headers: [String] = []
    @State private var deck = "默认"
    @State private var tags = ""
    @State private var presets: [CardEntryPreset] = []
    @State private var presetID: UUID?
    @State private var presetSnapshot: CardEntryPreset?
    @State private var mapping: [CardBulkEntryDestination] = []
    @State private var candidates: [CardBulkEntryCandidate] = []
    @State private var selected = Set<UUID>()
    @State private var parseIssues: [CardBulkEntryParseIssue] = []
    @State private var preview: CardBulkEntryPreview?
    @State private var error: String?
    @State private var busy = false
    @State private var didSave = false
    @State private var showsCloseConfirmation = false
    @State private var showsReparseConfirmation = false
    @State private var editing: CardBulkEntryCandidate?
    @State private var learningPreview: CardEditorPreviewSnapshot?
    @State private var page = 1
    @State private var draftID = UUID()
    @State private var persistedDraft: CardBulkEntryDraft?
    @State private var didLoad = false
    @State private var didDiscard = false
    @State private var restoredNotice: String?
    @State private var editingWorkingCopy: CardBulkEntryCandidate?
    @State private var originalPreview: CardBulkOriginalRequest?
    @State private var appending: CardBulkOriginalRequest?
    private let pageSize = 30

    private var configuration: CardBulkEntryConfiguration {
        .init(deck:deck,tags:TagParser.parse(tags),preset:presetSnapshot,mapping:mapping)
    }
    private var draftSnapshot: CardBulkEntryDraft {
        var value = CardBulkEntryDraft()
        value.id = draftID;value.source = source;value.format = format;value.firstRowIsHeader = firstRowIsHeader
        value.headers = headers;value.configuration = configuration;value.candidates = candidates
        value.selectedIDs = selected;value.page = page;value.editingCandidate = editingWorkingCopy ?? editing
        return value
    }
    private var needsReview: Bool {
        preview?.configuration != configuration || preview?.candidates != candidates || preview?.selectedIDs != selected
    }
    private var blocked: Bool { busy || didSave || store.fullBackupBusy }
    private var pageCount: Int { max(1,(candidates.count + pageSize - 1) / pageSize) }
    private var pageCandidates: [CardBulkEntryCandidate] { Array(candidates.dropFirst((page - 1) * pageSize).prefix(pageSize)) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("批量粘贴问答").font(.title2.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Text("先拆分并逐条预览，勾选后再统一保存；相同正面会提示，不会覆盖已有卡片。每批最多 500 张。")
                .font(.caption).foregroundStyle(.secondary)
            settings.disabled(blocked)
            if let restoredNotice { Text(restoredNotice).font(.caption).foregroundStyle(.secondary) }
            CardAppendUndoBanner()
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
            if candidates.isEmpty { pasteContent } else { reviewContent }
            HStack {
                Button("保存草稿并关闭") { requestClose() }.keyboardShortcut(.cancelAction).handCursor().disabled(busy)
                Button("放弃本批输入",role:.destructive) { showsCloseConfirmation = true }.disabled(blocked)
                Spacer()
                if candidates.isEmpty {
                    Button("拆分并检查") { parse() }.buttonStyle(.borderedProminent)
                        .disabled(blocked || source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).handCursor()
                        .accessibilityIdentifier("card-bulk-parse")
                } else {
                    Text("将保存勾选的 \(selected.count) 张").font(.caption).foregroundStyle(.secondary)
                    Button("重新检查") { check() }.disabled(blocked || selected.isEmpty).handCursor()
                        .accessibilityIdentifier("card-bulk-check")
                    Button("确认保存 \(selected.count) 张") { save() }.buttonStyle(.borderedProminent)
                        .disabled(blocked || needsReview || preview?.canSave != true).handCursor()
                        .accessibilityIdentifier("card-bulk-save")
                }
            }
        }
        .padding(20).frame(minWidth:740,idealWidth:900,minHeight:650,idealHeight:760)
        .interactiveDismissDisabled(!didSave && (!source.isEmpty || !candidates.isEmpty))
        .task { load() }
        .task(id:draftSnapshot) {
            guard didLoad,!didSave,!didDiscard,draftSnapshot.hasInput else { return }
            do { try await Task.sleep(for:.milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = persistDraft()
        }
        .onDisappear { if didLoad,!didSave,!didDiscard { _ = persistDraft() } }
        .onChange(of:presetID) { _,_ in
            guard presetID != presetSnapshot?.id else { return }
            presetSnapshot = presets.first { $0.id == presetID }
            mapping = configuration.defaultMapping(columnCount:candidates.map(\.values.count).max() ?? 0)
            preview = nil
        }
        .onChange(of:candidates.count) { _,_ in page = min(page,pageCount) }
        .confirmationDialog("放弃本批尚未保存的输入？",isPresented:$showsCloseConfirmation,titleVisibility:.visible) {
            Button("放弃本批输入",role:.destructive) {
                do { try store.db.clearCardBulkEntryDraft(expectedID:draftID);didDiscard = true;dismiss() }
                catch { self.error = error.localizedDescription }
            }
            Button("继续编辑",role:.cancel) { }
        } message: { Text("确认后会删除这批尚未保存的草稿；已经保存到卡片库的内容保持原样。") }
        .confirmationDialog("返回粘贴原文？",isPresented:$showsReparseConfirmation,titleVisibility:.visible) {
            Button("返回原文并重新拆分",role:.destructive) {
                candidates = [];selected = [];preview = nil;mapping = [];error = nil;page = 1
            }
            Button("继续检查",role:.cancel) { }
        } message: { Text("原始粘贴内容仍保留；候选中的逐条修改和移除会清除。") }
        .sheet(item:$editing,onDismiss:{ editingWorkingCopy = nil;_ = persistDraft() }) { candidate in
            CardBulkEntryCandidateEditor(candidate:candidate,configuration:configuration,templates:store.noteTemplates,onChanged:{ editingWorkingCopy = $0 }) { changed in
                guard !blocked,let index = candidates.firstIndex(where:{ $0.id == changed.id }) else { return }
                candidates[index] = changed;preview = nil
            }.disabled(blocked)
        }
        .sheet(item:$learningPreview) { CardEditorPreviewView(snapshot:$0) }
        .sheet(item:$originalPreview) { request in CardBulkOriginalPreview(request:request) }
        .sheet(item:$appending) { request in
            CardBulkAppendView(request:request) {
                selected.remove(request.candidateID);preview = nil
                _ = persistDraft();check()
            }
        }
    }

    private var settings: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("牌组")
                TextField("目标牌组",text:$deck).textFieldStyle(.roundedBorder)
                Menu("选择牌组") {
                    ForEach((try? store.db.deckNames()) ?? [],id:\.self) { value in Button(value) { deck = value } }
                }.fixedSize()
                Text("标签")
                TextField("空格或逗号分隔",text:$tags).textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("录入预设",selection:$presetID) {
                    Text("普通正反面").tag(Optional<UUID>.none)
                    ForEach(presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    if let presetSnapshot,!presets.contains(where:{ $0.id == presetSnapshot.id }) {
                        Text(presetSnapshot.name + "（草稿快照）").tag(Optional(presetSnapshot.id))
                    }
                }
                Text("沿用预设栏目和默认标签；所填牌组优先。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pasteContent: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("粘贴格式",selection:$format) {
                ForEach(CardBulkEntryFormat.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented).disabled(blocked)
            Text(format == .tabSeparated
                 ? "从表格复制：每行一张，Tab 分列。多行单元格请用英文双引号包住，内部引号写成两个双引号。下一步可指定每列对应的字段。"
                 : "每组以“问：”开头，另起一行写“答：”。答案可分多行，直到下一行“问：”。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if format == .tabSeparated { Toggle("第一行是表头，不创建卡片",isOn:$firstRowIsHeader).toggleStyle(.checkbox).disabled(blocked) }
            TextEditor(text:$source).font(.system(.body,design:.monospaced))
                .frame(minHeight:220).border(.quaternary).disabled(blocked)
                .accessibilityLabel("批量粘贴原文").accessibilityIdentifier("card-bulk-source")
            if !parseIssues.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing:4) {
                        ForEach(parseIssues) { issue in Text("第 \(issue.line) 行：\(issue.message)").foregroundStyle(.red).textSelection(.enabled) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:100)
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment:.leading,spacing:8) {
            DisclosureGroup("字段对应（\(mapping.count) 列，每列均需分配）") {
                ScrollView(.horizontal) {
                    HStack(alignment:.top,spacing:12) {
                        ForEach(mapping.indices,id:\.self) { index in
                            Picker(columnTitle(index),selection:Binding(get:{ mapping.indices.contains(index) ? mapping[index] : .unassigned },set:{ value in
                                guard mapping.indices.contains(index) else { return }
                                mapping[index] = value;preview = nil
                            })) {
                                Text("未分配").tag(CardBulkEntryDestination.unassigned)
                                ForEach(configuration.destinations(),id:\.destination.id) { destination in
                                    Text(destination.title).tag(destination.destination)
                                }
                            }.frame(minWidth:155)
                        }
                    }.padding(.vertical,4)
                }
            }.disabled(blocked)
            HStack {
                Button("全部勾选") { selected = Set(candidates.map(\.id)) }.disabled(blocked)
                Button("全部取消") { selected = [] }.disabled(blocked)
                Text("共 \(candidates.count) 张 · 已选 \(selected.count) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("返回粘贴原文") { showsReparseConfirmation = true }.disabled(blocked)
            }.controlSize(.small)
            if needsReview { Text("内容、选择或设置有变化，请重新检查后保存。").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(pageCandidates) { candidate in candidateRow(candidate) }
                }.padding(.trailing,4)
            }.frame(minHeight:200).disabled(blocked)
            HStack {
                Button("上一页") { page = max(1,page - 1) }.disabled(blocked || page <= 1)
                Text("第 \(page) / \(pageCount) 页").font(.caption)
                Button("下一页") { page = min(pageCount,page + 1) }.disabled(blocked || page >= pageCount)
                Spacer()
                Text("未勾选的卡片不会保存。红色问题需修正或取消勾选。").font(.caption).foregroundStyle(.secondary)
            }.controlSize(.small)
        }
    }

    private func candidateRow(_ candidate: CardBulkEntryCandidate) -> some View {
        let item = preview?.items.first { $0.id == candidate.id }
        return HStack(alignment:.top,spacing:10) {
            Toggle("选择第 \(candidate.line) 行",isOn:Binding(get:{ selected.contains(candidate.id) },set:{ on in
                if on { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
            })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment:.leading,spacing:4) {
                Text("原文第 \(candidate.line) 行").font(.caption).foregroundStyle(.secondary)
                Text(candidate.values.map { Markdown.plainText(fromHTML:$0) }.joined(separator:" ｜ "))
                    .lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                ForEach(Array((item?.issues ?? []).enumerated()),id:\.offset) { _,issue in
                    Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                }
            }
            VStack(spacing:6) {
                Button("编辑") { editing = candidate }.handCursor()
                Button("预览") { openPreview(candidate) }.handCursor()
                if let existingID = item?.duplicateCardID {
                    Button("查看原卡") { openOriginal(candidate,id:existingID,append:false) }.handCursor()
                    if item?.duplicateIsDeleted == false {
                        if onEditOriginal != nil { Button("编辑原卡") { editOriginal(candidate,id:existingID) }.handCursor() }
                        Button("追加答案…") { openOriginal(candidate,id:existingID,append:true) }.handCursor()
                    }
                    Button("跳过此条") { selected.remove(candidate.id) }.handCursor()
                }
                Button("移除",role:.destructive) {
                    candidates.removeAll { $0.id == candidate.id };selected.remove(candidate.id);preview = nil
                }.handCursor()
            }.controlSize(.small)
        }.padding(10).background(.quaternary.opacity(0.25),in:RoundedRectangle(cornerRadius:8))
    }

    private func columnTitle(_ index: Int) -> String {
        if headers.indices.contains(index),!headers[index].isEmpty { return "第 \(index + 1) 列：" + String(headers[index].prefix(20)) }
        return "第 \(index + 1) 列"
    }

    private func load() {
        do {
            let library = try store.db.cardEntryPresetLibrary()
            presets = library.presets
            if let saved = try store.db.cardBulkEntryDraft() {
                draftID = saved.id;persistedDraft = saved;source = saved.source;format = saved.format
                firstRowIsHeader = saved.firstRowIsHeader;headers = saved.headers
                deck = saved.configuration.deck;tags = TagParser.format(saved.configuration.tags)
                presetSnapshot = saved.configuration.preset;presetID = presetSnapshot?.id
                mapping = saved.configuration.mapping;candidates = saved.candidates;selected = saved.selectedIDs
                page = min(max(1,saved.page),max(1,(saved.candidates.count + pageSize - 1) / pageSize))
                editing = saved.editingCandidate;editingWorkingCopy = saved.editingCandidate
                restoredNotice = "已恢复批量录入草稿；重复卡片、模板与字段将按当前资料重新检查。"
            } else {
                deck = initialDeck ?? store.cardEditor?.card.deck ?? store.study.lastDeck ?? "默认"
                presetSnapshot = library.preset(for:deck);presetID = presetSnapshot?.id
            }
            didLoad = true
            if !candidates.isEmpty { check() }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult private func persistDraft() -> Bool {
        guard didLoad,!didSave,!didDiscard,!store.fullBackupBusy else { return false }
        let value = draftSnapshot
        guard value.hasInput || persistedDraft != nil else { return true }
        guard value != persistedDraft else { return true }
        do { try store.db.saveCardBulkEntryDraft(value,expected:persistedDraft);persistedDraft = value;return true }
        catch { self.error = "草稿保存失败：" + error.localizedDescription;return false }
    }

    private func parse() {
        guard !blocked else { return }
        var result = CardBulkEntryParser.parse(source,format:format,firstRowIsHeader:firstRowIsHeader)
        parseIssues = result.issues;error = nil
        guard result.issues.isEmpty else { return }
        headers = []
        if format == .tabSeparated,firstRowIsHeader,!result.rows.isEmpty {
            headers = result.rows.removeFirst().values
        }
        guard !result.rows.isEmpty else { error = "表头下没有可创建的卡片，请补充数据。";return }
        do {
            candidates = try CardBulkEntryParser.candidates(result)
            mapping = configuration.defaultMapping(columnCount:result.columnCount)
            selected = Set(candidates.map(\.id));page = 1
            check()
        } catch { self.error = error.localizedDescription }
    }

    private func check() {
        guard !blocked else { return }
        busy = true;error = nil
        let requestedCandidates = candidates,requestedConfiguration = configuration,requestedSelection = selected,db = store.db
        Task {
            do {
                let value = try await Task.detached(priority:.userInitiated) {
                    try db.previewCardBulkEntry(candidates:requestedCandidates,configuration:requestedConfiguration,selectedIDs:requestedSelection)
                }.value
                guard candidates == requestedCandidates,configuration == requestedConfiguration,selected == requestedSelection else { busy = false;return }
                preview = value;busy = false
            } catch { self.error = error.localizedDescription;busy = false }
        }
    }

    private func save() {
        guard !blocked,!needsReview,let preview,preview.canSave else { return }
        guard persistDraft() else { return }
        let savingDraft = draftSnapshot
        busy = true;error = nil
        let db = store.db
        Task {
            do {
                let saved = try await Task.detached(priority:.userInitiated) { try db.saveCardBulkEntry(preview,draft:savingDraft) }.value
                didSave = true
                onSaved(saved)
                busy = false;dismiss()
            } catch {
                self.preview = nil;self.error = error.localizedDescription;busy = false
            }
        }
    }

    private func openPreview(_ candidate: CardBulkEntryCandidate) {
        do {
            let card = try configuration.makeCard(candidate,templates:store.noteTemplates)
            learningPreview = .init(draft:CardDraft(card:card),templates:store.noteTemplates)
        } catch { self.error = error.localizedDescription }
    }
    private func requestClose() {
        guard !busy else { return }
        if didSave || persistDraft() { dismiss() }
    }
    private func currentOriginal(_ candidate: CardBulkEntryCandidate,id: Int64) throws -> CardBulkOriginalRequest {
        let fresh = try store.db.previewCardBulkEntry(candidates:candidates,configuration:configuration,selectedIDs:selected)
        guard let item = fresh.items.first(where:{ $0.id == candidate.id }),item.duplicateCardID == id,
              let incoming = item.card,let existing = try store.db.card(id:id) else { throw CardBulkEntryError.changedSelection }
        preview = fresh
        return .init(candidateID:candidate.id,incoming:incoming,existing:existing)
    }
    private func openOriginal(_ candidate: CardBulkEntryCandidate,id: Int64,append: Bool) {
        do {
            let request = try currentOriginal(candidate,id:id)
            if append {
                guard request.existing.deletedAt == nil else { throw CardBulkEntryError.changedSelection }
                appending = request
            } else { originalPreview = request }
        } catch { self.error = error.localizedDescription;preview = nil }
    }
    private func editOriginal(_ candidate: CardBulkEntryCandidate,id: Int64) {
        do {
            let request = try currentOriginal(candidate,id:id)
            guard request.existing.deletedAt == nil,let onEditOriginal else { throw CardBulkEntryError.changedSelection }
            selected.remove(candidate.id)
            guard persistDraft() else { return }
            onEditOriginal(candidate.id,id);dismiss()
        } catch { self.error = error.localizedDescription;preview = nil }
    }
}

private struct CardBulkEntryCandidateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var candidate: CardBulkEntryCandidate
    let configuration: CardBulkEntryConfiguration
    let templates: [String:NoteTemplate]
    var onChanged: (CardBulkEntryCandidate)->Void = { _ in }
    var onApply: (CardBulkEntryCandidate)->Void
    @State private var formatting = CardFormattingState()
    @State private var busy = false
    @State private var error: String?
    @State private var preview: CardEditorPreviewSnapshot?

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("编辑候选 · 原文第 \(candidate.line) 行").font(.title2.bold())
            Text("修改只应用于这张候选，尚未保存到卡片库。点击字段右上角 <> 可编辑 HTML。").font(.caption).foregroundStyle(.secondary)
            CardFormattingToolbar(state:formatting)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(candidate.values.indices,id:\.self) { index in
                        HStack(alignment:.firstTextBaseline,spacing:8) {
                            Text(fieldTitle(index)).font(.headline)
                            if fieldRule(index)?.required == true { Text("必填").font(.caption).foregroundStyle(.red) }
                        }
                        if let hint = fieldRule(index)?.hint,!hint.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                            Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        RichEditor(text:Binding(get:{ candidate.values[index] },set:{ candidate.values[index] = $0 }),
                                   mode:.card,toolbar:false,autoHeight:true,slot:"bulk-\(candidate.id)-\(index)",
                                   formatting:formatting,fieldName:fieldTitle(index)).richEditorFrame()
                    }
                }.padding(.trailing,6)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("预览") { afterFlushing {
                    do {
                        let card = try configuration.makeCard(candidate,templates:templates)
                        preview = .init(draft:CardDraft(card:card),templates:templates)
                    } catch { self.error = error.localizedDescription }
                } }
                Button("应用修改") { afterFlushing { onApply(candidate);dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command)
            }
        }.padding(20).frame(minWidth:680,idealWidth:760,minHeight:600,idealHeight:720).disabled(busy)
            .interactiveDismissDisabled(busy)
            .onChange(of:candidate) { _,value in onChanged(value) }
            .sheet(item:$preview) { CardEditorPreviewView(snapshot:$0) }
    }

    private func fieldTitle(_ index: Int) -> String {
        guard configuration.mapping.indices.contains(index) else { return "第 \(index + 1) 列 · 未分配" }
        let name = configuration.destinations().first { $0.destination == configuration.mapping[index] }?.title ?? "未分配"
        return "第 \(index + 1) 列 · " + name
    }
    private func fieldRule(_ index: Int) -> CardEntryInputRule? {
        guard configuration.mapping.indices.contains(index),let preset = configuration.preset else { return nil }
        switch configuration.mapping[index] {
        case .front: return preset.frontRule
        case .back: return preset.backRule
        case .field(let field): return preset.fieldRules?.indices.contains(field) == true ? preset.fieldRules?[field] : nil
        case .section(let section): return preset.sections.indices.contains(section) ? preset.sections[section].rule : nil
        case .unassigned: return nil
        }
    }
    private func afterFlushing(_ action: @escaping ()->Void) {
        guard !busy else { return };busy = true
        formatting.flushEditors { success in
            busy = false
            guard success else { error = "编辑器尚未完成同步，请稍后重试。当前输入仍保留。";return }
            action()
        }
    }
}
