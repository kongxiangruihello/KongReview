import Foundation

extension LibraryStore {
    func editCardTags(_ mode: CardTagBatchMode, ids: [Int64], deck: String) {
        guard !study.browseIsLoading, study.browsingDeck == deck else { return }
        let visible = Set(study.browseItems.compactMap(\.id))
        let selected = Array(Set(ids).intersection(visible)).sorted()
        guard !selected.isEmpty else { return }
        study.cardTagEdit = CardTagEditRequest(cardIDs: selected, deck: deck, mode: mode)
    }

    func applyCardTagEdit() {
        guard let request = study.cardTagEdit, !request.processing else { return }
        let tags = AppDatabase.parsedCardTags(request.text)
        guard !tags.isEmpty else {
            study.cardTagEdit?.error = CardTagBatchError.emptyTags.localizedDescription
            return
        }
        study.cardTagEdit?.processing = true
        study.cardTagEdit?.error = nil
        let db = self.db
        Task.detached(priority: .userInitiated) {
            do {
                let snapshot = try db.updateCardTags(ids: request.cardIDs, deck: request.deck,
                                                     tags: tags, mode: request.mode)
                await MainActor.run {
                    guard self.study.cardTagEdit?.id == request.id else { return }
                    self.study.cardTagEdit = nil
                    if !snapshot.cardIds.isEmpty {
                        if self.study.browsingDeck == request.deck {
                            self.study.browseLoadID = UUID()
                            self.study.browseSelection = []
                            self.study.browseIsLoading = true
                        }
                        self.recordCardTagUndo(snapshot)
                        self.reload()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.study.cardTagEdit?.id == request.id else { return }
                    self.study.cardTagEdit?.processing = false
                    self.study.cardTagEdit?.error = error.localizedDescription
                }
            }
        }
    }
}
