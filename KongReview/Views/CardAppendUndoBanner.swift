import SwiftUI

struct CardAppendUndoBanner: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if store.cardAppendUndo.token != nil || store.cardAppendUndo.message != nil {
            HStack(alignment:.center,spacing:12) {
                Image(systemName:store.cardAppendUndo.token == nil ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(store.cardAppendUndo.token == nil ? Color.secondary : Color.accentColor)
                Text(store.cardAppendUndo.message ?? "答案已追加到原卡，学习进度保持原样。")
                    .font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                if store.cardAppendUndo.token != nil {
                    Button("撤销本次追加") { store.undoLastCardAppend() }
                        .disabled(store.fullBackupBusy || store.cardAppendUndo.isBusy)
                        .handCursor().help("只恢复本次追加前的正文，保留最新学习进度、牌组和标签")
                        .accessibilityIdentifier("card-append-undo")
                        .accessibilityHint("撤销最近一次追加的答案内容")
                }
                Button { store.cardAppendUndo.clear() } label: { Image(systemName:"xmark") }
                    .buttonStyle(.plain).handCursor().help("关闭追加提示")
                    .accessibilityLabel("关闭追加提示")
                    .disabled(store.cardAppendUndo.isBusy)
            }.padding(.horizontal,16).padding(.vertical,10)
                .background(.quaternary.opacity(0.5))
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier("card-append-undo-banner")
        }
    }
}
