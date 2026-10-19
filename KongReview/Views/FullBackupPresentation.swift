import SwiftUI

struct FullBackupPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { store.fullBackupRestore }, set: { value in
                if value == nil { store.cancelFullBackupRestore() }
            })) { prepared in
                FullBackupRestoreView(prepared: prepared,
                                      onCancel: store.cancelFullBackupRestore,
                                      onRestore: store.confirmFullBackupRestore)
                    .interactiveDismissDisabled(store.fullBackupBusy)
            }
    }
}
