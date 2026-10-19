import SwiftUI

struct CardEntryOrganizationUndoBanner: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        let state = store.cardEntryOrganizationUndo
        if state.token != nil || state.message != nil {
            HStack(spacing:12) {
                Image(systemName:state.token == nil ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(state.token == nil ? Color.secondary : Color.accentColor)
                Text(state.message ?? state.token?.message ?? "")
                    .font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                if state.token != nil {
                    Button("撤销本次整理") { store.undoLastCardEntryOrganization() }
                        .disabled(store.fullBackupBusy || state.isBusy)
                        .handCursor().help("撤销最近一次批量移动牌组或增减标签，保留正文和学习进度")
                        .accessibilityIdentifier("card-entry-organization-undo")
                }
                Button { state.clear() } label: { Image(systemName:"xmark") }
                    .buttonStyle(.plain).handCursor().help("关闭整理提示")
                    .accessibilityLabel("关闭整理提示").disabled(state.isBusy)
            }.padding(.horizontal,16).padding(.vertical,10)
                .background(.quaternary.opacity(0.5))
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier("card-entry-organization-undo-banner")
        }
    }
}
