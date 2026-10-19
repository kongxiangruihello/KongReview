import Foundation
import Observation

@MainActor @Observable final class LibraryResourceAuditState {
    var scopes: [AuditScope] = []
    var scopeIndex = 0
    var examined = 0
    var expected = 0
    var found = 0
    var running = false
    var finished = false
    var startedAt: Date?
    var error: String?
    var page = 0
    var kind = ""
    var query = ""
    var total = 0
    var items: [AuditIssue] = []
    @ObservationIgnored var results: AuditResultStore?
    @ObservationIgnored var task: Task<Void,Never>?
    @ObservationIgnored var token = UUID()
    @ObservationIgnored var pageToken = UUID()
    var pageCount: Int { max(1,(total+49)/50) }
    func reset() {
        pause(); pageToken = UUID(); scopes = []; scopeIndex = 0; examined = 0; expected = 0; found = 0; finished = false
        startedAt = nil; error = nil; results = nil; items = []; total = 0; page = 0
    }
    func pause() { token = UUID(); task?.cancel(); task = nil; running = false }
    func start(db: AppDatabase) {
        guard !running,!finished else { return }
        let run = UUID(); token = run; running = true; error = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if results == nil {
                    let scopes = try await db.resourceAuditScopes()
                    guard token == run else { return }
                    self.scopes = scopes; expected = scopes.reduce(0) { $0+$1.total }; results = try AuditResultStore(); startedAt = Date()
                }
                guard let results else { return }
                let media = try await db.editorMediaNames()
                guard token == run else { return }
                while scopeIndex < scopes.count {
                    try Task.checkCancellation()
                    let documents = try await db.resourceAuditBatch(scopes[scopeIndex])
                    guard token == run else { return }
                    if documents.isEmpty { scopeIndex += 1; continue }
                    let count = try await Task.detached(priority:.utility) { try results.append(documents,mediaNames:media) }.value
                    guard token == run else { return }
                    scopes[scopeIndex].cursor = documents.last!.recordID
                    examined += documents.count; found += count; refreshPage()
                    await Task.yield()
                }
                guard token == run else { return }
                finished = true; running = false; refreshPage()
            } catch is CancellationError { if token == run { running = false } }
            catch { if token == run { self.error = error.localizedDescription; running = false; refreshPage() } }
        }
    }
    func refreshPage() {
        guard let results else { return }
        let request = UUID(); pageToken = request
        let page = page,kind = kind,query = query
        Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority:.utility) { try results.page(page,kind:kind,query:query) }.value
                guard let self,self.pageToken == request else { return }
                total = result.total; self.page = min(max(0,page),max(0,(total-1)/50)); items = result.items
            } catch { if self?.pageToken == request { self?.error = error.localizedDescription } }
        }
    }
}
