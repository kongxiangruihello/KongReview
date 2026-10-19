import SwiftUI
import KongReviewCore

struct CardInputDuplicateNotice: View {
    @Environment(LibraryStore.self) private var store
    let card: Card
    /// A heading keeps the warning and actions above the scrolling card fields.
    var heading: String? = nil
    var presentPreview: ((Card, Bool) -> Void)? = nil
    let continueSaving: () -> Void
    @State private var preview: Card?
    @State private var appendReview = false
    @State private var message: String?
    @State private var restored = false
    @State private var performingAction = false
    private var warning: String { card.deletedAt == nil || restored ? "正面重复 · " + card.deck : "最近删除中有相同正面 · " + card.deck }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            if let heading {
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.firstTextBaseline,spacing:12) {
                        Text(heading).font(.headline).fixedSize()
                        warningLabel.fixedSize(horizontal:true,vertical:false)
                        Spacer(minLength:0)
                        actions.fixedSize()
                    }
                    VStack(alignment:.leading,spacing:6) {
                        HStack(alignment:.firstTextBaseline,spacing:12) {
                            Text(heading).font(.headline).fixedSize()
                            warningLabel
                            Spacer(minLength:0)
                        }
                        HStack { Spacer(minLength:0); actions }
                    }
                }
            } else {
                Text("相同正面 · 牌组：" + card.deck).font(.caption)
                actions
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .sheet(item:$preview) { value in
            if let draft = store.cardEditor {
                CardComparisonView(incoming:draft.card,existing:value,draftID:draft.id,appendReview:appendReview)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    Text("已有卡片 · " + value.deck).font(.headline)
                    let faces = store.faces(of:value)
                    CardWebView(front:faces.front,back:faces.back,store:store).frame(minHeight:300)
                    Button("关闭") { preview = nil }
                }.padding(20).frame(minWidth:600,minHeight:400)
            }
        }
    }
    private var warningLabel: some View {
        Label(warning,systemImage:"exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(.red).lineLimit(2).help(warning)
            .accessibilityIdentifier("card-front-duplicate-warning")
    }
    private var actions: some View {
        HStack(spacing:12) {
            if store.cardEditor != nil {
                Button("编辑原卡") {
                    afterFlushing {
                        if !store.editOriginalDuplicate(card) {
                            message = store.cardEditor?.error ?? store.draftSaveError ?? "暂时无法打开原卡，当前输入已保留。"
                        }
                    }
                }.buttonStyle(.link).handCursor()
                    .disabled(card.deletedAt != nil && !restored)
                    .help("保留当前输入为草稿，再编辑最新的原卡")
                    .accessibilityIdentifier("card-front-edit-original")
                if card.deletedAt == nil || restored {
                    Button("追加答案…") { afterFlushing { showPreview(append:true) } }
                        .buttonStyle(.link).handCursor()
                        .help("先对照当前答案与原卡，再确认追加并保存")
                        .accessibilityIdentifier("card-front-append-answer")
                }
            }
            Button(store.cardEditor == nil ? "查看已有卡片" : "对照") { afterFlushing { showPreview(append:false) } }
                .buttonStyle(.link).handCursor().accessibilityIdentifier("card-front-compare-original")
            if card.deletedAt != nil && !restored {
                Button("恢复原卡") {
                    guard let id = card.id else { return }
                    do {
                        try store.db.restoreInputDuplicate(id:id); store.reload()
                        restored = true; message = "已恢复原卡，学习进度保留。当前输入仍在编辑器中。"
                    } catch { message = error.localizedDescription }
                }
                Button("仍然新建") { continueSaving() }
            }
        }.controlSize(.small).disabled(store.fullBackupBusy || performingAction || store.cardWorkflow.actionBusy)
    }
    private func afterFlushing(_ action: @escaping ()->Void) {
        guard !store.fullBackupBusy,!performingAction,!store.cardWorkflow.actionBusy else { return }
        let draftID = store.cardEditor?.id
        guard draftID != nil else { action(); return }
        let generation = store.cardWorkflow.generation
        performingAction = true
        store.cardWorkflow.actionBusy = true
        store.cardFormatting.flushEditors { success in
            performingAction = false
            guard store.cardWorkflow.generation == generation else { return }
            store.cardWorkflow.actionBusy = false
            guard store.cardEditor?.id == draftID,store.cardWorkflow.generation == generation,!store.fullBackupBusy else { return }
            if success { action() }
            else { reportError("编辑器尚未完成同步，请稍后再试。当前输入仍保留。") }
        }
    }
    private func showPreview(append: Bool) {
        do {
            let current: Card
            if store.cardEditor != nil {
                current = try store.duplicateCardPreview(card,forAppend:append)
            } else {
                guard let id = card.id,let saved = try store.db.card(id:id) else { reportError("原卡已不存在，请重新检查。"); return }
                current = saved
            }
            message = nil
            if let presentPreview { presentPreview(current,append) }
            else { appendReview = append; preview = current }
        } catch { reportError(error.localizedDescription) }
    }
    private func reportError(_ text: String) {
        message = text
        // A pending field change can remove this notice while its action finishes.
        // Keep failures visible on the stable editor as well.
        store.cardEditor?.error = text
    }
}
