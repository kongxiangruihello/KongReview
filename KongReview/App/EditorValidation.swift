import SwiftUI
import GRDB
import KongReviewCore

/// A separately identified test bundle uses only an in-memory library and temporary drafts.
/// The normal application never enters this path.
@MainActor enum EditorValidation {
    static var isEnabled: Bool { Bundle.main.bundleIdentifier == "com.kongxiangrui.KongReview.EditorCheck" }
    static func makeStore() -> LibraryStore {
        do {
            let db = try AppDatabase(DatabaseQueue())
            try db.writer.write { sql in
                let pixel = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1xoAAAAASUVORK5CYII=")!
                try sql.execute(sql:"INSERT INTO card_media(name,data) VALUES (?,?)",arguments:["exists.png",pixel])
            }
            let source = try db.save(Source(title:"独立测试出处"))
            let h = try db.save(Highlight(sourceId:source.id,text:"测试原文"))
            var card = try db.save(Card(deck:"示例牌组",front:"<p>Hello World</p>",back:"<p>已有答案</p>",highlightId:h.id))
            card.back = "<p>已有答案第二版</p>"
            card.sections = [.init(name:"例句",text:"<p>原卡例句</p>",folded:true)]
            _ = try db.save(card)
            let preset = CardEntryPreset(name:"示例名词解释",deck:"测试输入",tags:["示例标签"],sections:[.init(name:"释义"),.init(name:"例句",folded:true)],frontRule:.init(hint:"写出需要解释的问题",required:true),backRule:.init(hint:"先概括定义，再补充说明",required:true))
            try db.saveCardEntryPreset(preset)
            try db.setDeckEntryPreset(deck:"测试输入",presetID:preset.id)
            try db.writer.write { sql in
                for index in 0..<55 {
                    var example = Card(deck:"历史分页示例",front:"录入历史示例 \(index)",back:"示例答案 \(index)")
                    try example.save(sql)
                    try AppDatabase.recordCardEntry(example,in:sql)
                }
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KongReview-editor-validation-" + UUID().uuidString)
            let persistence = try EditorDraftPersistence(directory:dir)
            for index in 0..<55 {
                try persistence.recordCard(CardDraft(card:Card(deck:index % 2 == 0 ? "测试输入" : "其他牌组",front:"草稿示例 \(index)",back:"完整草稿内容 \(index)")))
            }
            let store = LibraryStore(db:db,draftPersistence:persistence,positionDefaults:nil)
            store.newCard(deck:"测试输入")
            store.cardEditor?.card.front = "<p> hello WORLD </p>"
            store.cardEditor?.card.back = "<p>准备追加的答案</p>"
            store.cardEditor?.card.sections = [.init(name:"补充解释",text:"<p>本次独立的补充解释</p>",folded:true)]
            return store
        } catch { fatalError("独立测试库创建失败：\(error)") }
    }
}

struct EditorValidationView: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        VStack(alignment:.leading) {
            Text("KongReview · 独立编辑器验证（示例数据）").font(.headline)
            CardAppendUndoBanner()
            CardEntryOrganizationUndoBanner()
            HStack {
                Button("新建示例卡") { store.newCard(deck:"测试输入") }
                Button("编辑已有示例卡") {
                    do { if let card = try store.db.cards().first { store.editCard(card) } } catch { store.report(error) }
                }
                Button("窄窗口") { NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" })?.setContentSize(NSSize(width:720,height:680)) }
                Button("宽窗口") { NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" })?.setContentSize(NSSize(width:1100,height:720)) }
                Menu("恢复测试草稿") {
                    ForEach(store.savedCardDrafts) { draft in
                        Button(draft.title) { store.scheduleDraftRecovery(id:draft.id,kind:.card); store.performPendingDraftRecovery() }
                    }
                }
            }
            HStack {
                Button("出处识别样例") { store.newHighlight(); store.editorDraft?.highlight.text = "<p><strong>学习正文</strong>——钱穆《国史大纲》第12页</p>" }
                Button("资料检查") { store.showsResourceAudit = true }
                Button("快速录入样例") { QuickCaptureController.shared.store = store; QuickCaptureController.shared.show(prefill:CaptureRequest(text:"正文——作者《测试书》第23页")) }
                Button("草稿管理") { store.showsDraftRecovery = true }
                Button("录入预设") { store.showsCardEntryPresetManager = true }
                Button("批量粘贴") { store.showsCardBulkEntry = true }
                Button("录入历史") { store.cardEntryHistory.isPresented = true }
                if store.cardWorkflow.addedCount > 0 { Button("本次清单") { store.cardWorkflow.showsBatch = true } }
            }
            if store.cardEditor != nil { CardEditorView().modifier(EditorDraftCloseConfirmation(kind:.card)) }
            else { Text("编辑已关闭。选择上方按钮继续验证。").frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .sheet(item:Bindable(store).editorDraft) { _ in HighlightEditorView().modifier(EditorDraftCloseConfirmation(kind:.highlight)) }
        .sheet(isPresented:Bindable(store).showsResourceAudit) { LibraryResourceAuditView() }
        .modifier(EditorDraftRecoverySheets())
        .modifier(CardEntryPresetPresentation(insideEditor:false))
        .modifier(DeckEntryPresetPresentation(host:.main))
        .modifier(CardEntryBatchPresentation(insideEditor:false))
        .modifier(CardEntryHistoryPresentation(insideEditor:false))
        .modifier(CardBulkEntryPresentation(insideEditor:false))
        .padding(12).frame(minWidth:720,minHeight:680)
    }
}
