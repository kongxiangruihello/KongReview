import SwiftUI

struct DeckEntryPresetRequest: Identifiable {
    var deck: String
    var id: String { deck }
}

struct DeckEntryPresetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var deck: String
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("牌组录入模板").font(.title2.bold())
            Text(deck).font(.headline)
            CardEntryPresetDeckBindingView(deck:deck)
            Text("选择后立即保存；此后在该牌组新建卡片时使用。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer();Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(minWidth:560,idealWidth:640,minHeight:240)
    }
}

struct DeckEntryPresetPresentation: ViewModifier {
    enum Host { case main, cardEditor, options }
    @Environment(LibraryStore.self) private var store
    var host: Host
    private var active: Bool {
        switch host {
        case .main: store.cardEditor == nil && store.deckOptionsEditor == nil
        case .cardEditor: store.cardEditor != nil
        case .options: store.deckOptionsEditor != nil
        }
    }
    func body(content: Content) -> some View {
        content.sheet(item:Binding(get:{ active ? store.deckEntryPresetEditor : nil },set:{ if active { store.deckEntryPresetEditor = $0 } })) {
            DeckEntryPresetSettingsView(deck:$0.deck)
        }
    }
}

struct CardEntryPresetPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    var insideEditor: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented:Binding(get:{ store.showsCardEntryPresetManager && (store.cardEditor != nil) == insideEditor },
            set:{ if !$0 { store.showsCardEntryPresetManager = false } })) {
            CardEntryPresetManagerView()
        }
    }
}
