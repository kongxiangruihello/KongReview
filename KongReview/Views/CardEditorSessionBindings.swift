import SwiftUI
import KongReviewCore

/// Pending WebKit/native callbacks may outlive a sheet's old draft.
@MainActor enum CardEditorSessionBindings {
    static func value<T>(_ store: LibraryStore,_ keyPath: WritableKeyPath<CardDraft,T>,fallback: T) -> Binding<T> {
        make(store,fallback:fallback,read:{ $0[keyPath:keyPath] },write:{ $0[keyPath:keyPath] = $1 })
    }
    static func field(_ store: LibraryStore,index: Int) -> Binding<String> {
        make(store,fallback:"",read:{ $0.card.fields.indices.contains(index) ? $0.card.fields[index] : "" },write:{ draft,value in
            guard draft.card.fields.indices.contains(index) else { return }; draft.card.fields[index] = value
        })
    }
    static func section<T>(_ store: LibraryStore,id: String,keyPath: WritableKeyPath<CardSection,T>,fallback: T) -> Binding<T> {
        make(store,fallback:fallback,read:{ $0.card.sections?.first { $0.id == id }?[keyPath:keyPath] ?? fallback },write:{ draft,value in
            guard let index = draft.card.sections?.firstIndex(where: { $0.id == id }) else { return }
            draft.card.sections?[index][keyPath:keyPath] = value
        })
    }
    private static func make<T>(_ store: LibraryStore,fallback: T,read: @escaping (CardDraft)->T,write: @escaping (inout CardDraft,T)->Void) -> Binding<T> {
        let sessionID = store.cardEditor?.id
        let generation = store.cardWorkflow.generation
        return Binding(get:{ [weak store] in
            guard let store,store.cardWorkflow.generation == generation,
                  let id = sessionID,let draft = store.cardEditor,draft.id == id else { return fallback }
            return read(draft)
        },set:{ [weak store] value in
            guard let id = sessionID,let store,store.cardWorkflow.generation == generation,
                  var draft = store.cardEditor,draft.id == id else { return }
            write(&draft,value); store.cardEditor = draft
        })
    }
}
