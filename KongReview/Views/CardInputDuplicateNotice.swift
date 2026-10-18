import SwiftUI
import KongReviewCore

struct CardInputDuplicateNotice: View {
    @Environment(LibraryStore.self) private var store
    let card: Card
    let continueSaving: () -> Void
    @State private var preview: Card?
    @State private var message: String?
    @State private var restored = false
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("相同正面 · 牌组：" + card.deck).font(.caption)
            HStack {
                Button(store.cardEditor == nil ? "查看已有卡片" : "并排对照已有卡片") {
                    do { preview = try card.id.flatMap { try store.db.card(id:$0) } ?? card }
                    catch { message = error.localizedDescription }
                }
                if card.deletedAt != nil && !restored {
                    Button("恢复已删除卡片") {
                        guard let id = card.id, !store.fullBackupBusy else { return }
                        do {
                            try store.db.restoreInputDuplicate(id:id); store.reload()
                            restored = true; message = "已恢复原卡，学习进度保留。当前输入仍保留在编辑器中。"
                        } catch { message = error.localizedDescription }
                    }
                    Button("仍然新建") { continueSaving() }
                }
            }.controlSize(.small).disabled(store.fullBackupBusy)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item:$preview) { value in
            if let draft = store.cardEditor {
                CardComparisonView(incoming:draft.card,existing:value,draftID:draft.id)
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
}
