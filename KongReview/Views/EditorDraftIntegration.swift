import SwiftUI

struct EditorDraftCloseConfirmation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    let kind: EditorDraftSelection.Kind
    private var presented: Binding<Bool> {
        Binding(get: { kind == .highlight ? store.closingHighlightEditor : store.closingCardEditor },
                set: { if kind == .highlight { store.closingHighlightEditor = $0 } else { store.closingCardEditor = $0 } })
    }
    func body(content: Content) -> some View {
        content.confirmationDialog("关闭前如何处理这次修改？", isPresented: presented, titleVisibility: .visible) {
            Button("保留草稿并关闭") { store.keepAndCloseEditor(kind) }
                .disabled(store.draftPersistence == nil || store.draftSaveError != nil)
            Button("放弃修改", role: .destructive) { store.discardAndCloseEditor(kind) }
            Button("继续编辑", role: .cancel) { presented.wrappedValue = false }
        } message: {
            Text("保留的草稿可从首页继续编辑。点击保存后才会更新正式数据。")
        }
    }
}

struct EditorDraftRecoverySheets: ViewModifier {
    @Environment(LibraryStore.self) private var store
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { store.showsDraftRecovery }, set: { store.showsDraftRecovery = $0 }),
                      onDismiss: { store.performPendingDraftRecovery() }) {
            EditorDraftRecoverySheet(highlights: store.savedHighlightDrafts, cards: store.savedCardDrafts,
                onRestoreHighlight: { store.scheduleDraftRecovery(id: $0, kind: .highlight) },
                onRestoreCard: { store.scheduleDraftRecovery(id: $0, kind: .card) },
                onDiscardHighlight: { store.draftPendingDiscard = EditorDraftSelection(id: $0, kind: .highlight) },
                onDiscardCard: { store.draftPendingDiscard = EditorDraftSelection(id: $0, kind: .card) },
                onClose: { store.showsDraftRecovery = false })
            .confirmationDialog("放弃这份未保存的草稿？", isPresented: Binding(
                get: { store.draftPendingDiscard != nil }, set: { if !$0 { store.draftPendingDiscard = nil } }), titleVisibility: .visible) {
                Button("放弃草稿", role: .destructive) { store.discardSavedDraft() }
                Button("取消", role: .cancel) { store.draftPendingDiscard = nil }
            } message: { Text("只移除这份草稿，正式数据保持原样。") }
        }
    }
}
