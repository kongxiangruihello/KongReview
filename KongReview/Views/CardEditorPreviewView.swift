import SwiftUI
import KongReviewCore

/// Freeze exactly the fields and template used when the user opens the preview.
struct CardEditorPreviewSnapshot: Identifiable {
    let id = UUID()
    let draftID: UUID
    let card: Card
    let front: String
    let back: String

    init(draft: CardDraft, templates: [String: NoteTemplate]) {
        draftID = draft.id
        card = draft.card
        let faces = draft.card.faces(using:draft.card.noteType.flatMap { templates[$0] })
        front = faces.front
        back = faces.back
    }
}

struct CardEditorPreviewView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let snapshot: CardEditorPreviewSnapshot
    var savedCard = false
    @State private var showingAnswer = false

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("卡片学习效果预览").font(.title2.bold())
                Spacer()
                Text(showingAnswer ? "背面" : "正面").font(.headline).foregroundStyle(.secondary)
            }
            Text("牌组：" + snapshot.card.deck + (snapshot.card.noteType.map { " · 模板：" + $0 } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
            Text(savedCard ? "显示打开预览时已保存的内容；预览不计入学习记录。" : "显示当前未保存内容；折叠栏目、图片和链接可直接查看。预览不计入学习记录。")
                .font(.caption).foregroundStyle(.secondary)
            CardWebView(front:snapshot.front,back:showingAnswer ? snapshot.back : nil,store:store,css:store.cardCSS(for:snapshot.card))
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .accessibilityIdentifier("card-editor-learning-preview")
            HStack {
                Button("继续编辑") { dismiss() }.keyboardShortcut(.cancelAction).handCursor()
                Spacer()
                Button(showingAnswer ? "返回正面" : "显示答案") { showingAnswer.toggle() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.space,modifiers:[]).handCursor()
                    .accessibilityIdentifier("card-editor-preview-flip")
            }
        }.padding(20).frame(minWidth:660,idealWidth:760,minHeight:500,idealHeight:650)
    }
}
