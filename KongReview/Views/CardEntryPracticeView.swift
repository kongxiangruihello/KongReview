import SwiftUI
import KongReviewCore

struct CardEntryPracticeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var session: CardEntryPracticeSession
    @State private var invalidation: String?
    @State private var editingAnswer = false

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("额外练习 · 先作答再对照").font(.title2.bold())
                Spacer()
                Button("退出练习") { dismiss() }.keyboardShortcut(.cancelAction).handCursor()
            }
            Text("本次回答和自评仅在当前窗口保留。退出后清除，不写入正式复习、排程或成长统计。")
                .font(.caption).foregroundStyle(.secondary)
            if let invalidation {
                ContentUnavailableView("本次练习已停止",systemImage:"exclamationmark.triangle",description:Text(invalidation))
            } else if session.isFinished {
                Spacer()
                ContentUnavailableView("本次练习完成",systemImage:"checkmark.circle",description:Text("共 \(session.cards.count) 张，已写回答 \(session.answeredCount) 张，已自评 \(session.assessedCount) 张。"))
                HStack { Spacer();Button("查看本次回答") { perform { session.revisit() } }.handCursor();Spacer() }
                Spacer()
            } else if let card = session.current {
                let faces = card.faces(using:card.noteType.flatMap { session.templates[$0] })
                Text("第 \(session.position + 1) / \(session.cards.count) 张 · \(card.deck)").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text("题目").font(.headline)
                        RichWebText(text:faces.front,slot:"entry-practice-\(session.id)-\(card.id ?? 0)-front")
                        Divider()
                        CardSelfAnswerPanel(draft:Binding(get:{ session.responses[card.id ?? 0] ?? .init() },set:{ value in
                            // A disappearing editor can still deliver its final native
                            // callback. Never let that write into the next card's answer.
                            guard invalidation == nil,session.current?.id == card.id else { return }
                            session.setResponse(value)
                        }),
                                            showingAnswer:session.showingAnswer,referenceHTML:faces.back,
                                            slot:"entry-practice-\(session.id)-\(card.id ?? 0)",allowsAssessment:true,
                                            onEditingChanged:{ editingAnswer = $0 })
                    }.padding(12)
                }
                .id(card.id)
                .disabled(store.fullBackupBusy)
                HStack {
                    Button("上一张") { perform { session.previous() } }.disabled(session.position == 0)
                    Spacer()
                    if !session.showingAnswer {
                        Button("显示答案") { perform { session.revealAnswer() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(editingAnswer ? nil : KeyboardShortcut(.space,modifiers:[]))
                            .handCursor().accessibilityIdentifier("entry-practice-reveal")
                    }
                    Button(session.position + 1 == session.cards.count ? "完成练习" : "下一张") { perform { session.next() } }
                        .handCursor()
                }.disabled(store.fullBackupBusy)
            }
        }
        .padding(20).frame(minWidth:600,idealWidth:900,minHeight:560,idealHeight:720)
        .onAppear { validate() }
        .onChange(of:store.revision) { _,_ in validate() }
        .onChange(of:store.cardEntryHistory.generation) { _,_ in validate() }
        .onChange(of:store.fullBackupBusy) { _,_ in validate() }
    }

    @discardableResult private func validate() -> Bool {
        guard invalidation == nil else { return false }
        do { try store.validateCardEntryPractice(session);return true }
        catch { invalidation = error.localizedDescription;return false }
    }
    private func perform(_ action: () -> Void) { if validate() { action() } }
}
