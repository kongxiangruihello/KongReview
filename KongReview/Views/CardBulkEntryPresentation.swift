import SwiftUI

struct CardBulkEntryPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    var insideEditor: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented:Binding(get:{ store.showsCardBulkEntry && (store.cardEditor != nil) == insideEditor },set:{ if !$0 { store.showsCardBulkEntry = false } })) {
            CardBulkEntryView { cards in
                for card in cards { store.cardWorkflow.recordAddedCard(card.id) }
                store.showsCardBulkEntry = false
                store.reload()
            }
        }
    }
}
