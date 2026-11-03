import SwiftUI
import Charts
import KongReviewCore

struct JourneyPager: View {
    @Binding var page: Int
    let total: Int
    var pageSize = 50
    var body: some View {
        HStack {
            Text("共 \(total) 项 · 第 \(page+1) / \(max(1,(total+pageSize-1)/pageSize)) 页").font(.caption)
            Spacer()
            Button("上一页") { page -= 1 }.disabled(page == 0)
            Button("下一页") { page += 1 }.disabled((page+1)*pageSize >= total)
        }
    }
}

struct DifficultCarePanel: View {
    @Environment(LibraryStore.self) private var store
    let cardID: Int64
    var onOpenCard: ((Int64) -> Void)? = nil
    @State private var care: DifficultCardCare?
    @State private var reason: DifficultReason = .split
    @State private var note = ""
    @State private var comparison: CardCareComparison?
    @State private var error: String?
    @State private var loaded = false
    @State private var generation = -1
    var body: some View {
        DisclosureGroup("困难卡处理与跟踪") {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("处理原因", selection: $reason) { ForEach(DifficultReason.allCases) { Text($0.title).tag($0) } }.disabled(!loaded)
                RichEditor(text:$note,placeholder:"难卡处理说明",autoHeight:true,minHeight:90,slot:"care-note").richEditorFrame().disabled(!loaded)
                Text("暂缓只作标记。需要暂停正式学习时，请在记忆卡中设置暂停。处理原因自动保存。打开原卡编辑，保存内容修改后会自动记录前后快照并开始跟踪。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存处理记录") { persist() }
                    Button(care?.adjustedAt == nil ? "已调整，开始跟踪" : "重新开始跟踪") { persist(startTracking: true) }
                    if care != nil { Button(care?.resolvedAt == nil ? "标记已解决" : "恢复观察") { persist(toggleResolved: true) } }
                }.disabled(!loaded || store.fullBackupBusy)
                if let care {
                    Text(care.resolvedAt == nil ? "状态：\(care.adjustedAt == nil ? "待调整" : "观察中")" : "状态：已解决（手动标记）").font(.caption)
                    if let adjusted = care.adjustedAt { Text("跟踪开始：\(adjusted.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                if let comparison {
                    Text("前后等长观察（最长14天，当前约\(comparison.days)天）")
                    Text("调整前：重来 \(comparison.beforeAgain) / 评分 \(comparison.beforeRatings)（\(rate(comparison.beforeAgain, comparison.beforeRatings))）；调整后：重来 \(comparison.afterAgain) / 评分 \(comparison.afterRatings)（\(rate(comparison.afterAgain, comparison.afterRatings))）")
                    Text(comparison.interpretation).font(.caption).foregroundStyle(.secondary)
                    Text("仅比较这张卡的正式评分；拆出的新卡独立统计。重新跟踪会以新的开始时间计算。").font(.caption).foregroundStyle(.secondary)
                }
                if care != nil { CareContentHistoryView(cardID:cardID,onOpenCard:onOpenCard) }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(.top, 8).disabled(store.fullBackupBusy)
            }.frame(height: 210)
        }
        .onAppear { generation = store.growthGeneration }
        .onChange(of: reason) { _,_ in saveIfChanged() }
        .onChange(of: note) { _,_ in saveIfChanged() }
        .onDisappear { saveIfChanged() }
        .task(id: "\(cardID)|\(store.revision)|\(store.journeyRevision)") {
            do {
                let value = try store.db.progressValue(DifficultCardCare.self, key: "difficult-care.\(cardID)")
                let stats = try await value.asyncComparison(db: store.db)
                try Task.checkCancellation()
                care = value; comparison = stats
                if !loaded { reason = value?.reason ?? .split; note = value?.note ?? "" }
                loaded = true; error = nil
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    private func rate(_ count: Int, _ total: Int) -> String {
        total == 0 ? "暂无评分" : String(format: "%.0f%%", Double(count) / Double(total) * 100)
    }
    private func saveIfChanged() {
        guard loaded, generation == store.growthGeneration, !store.fullBackupBusy,
              reason != (care?.reason ?? .split) || note != (care?.note ?? "") else { return }
        persist()
    }
    private func persist(startTracking: Bool = false, toggleResolved: Bool = false) {
        guard generation == store.growthGeneration, !store.fullBackupBusy else { return }
        do {
            care = try store.db.saveCare(cardID:cardID,reason:reason,note:note,startTracking:startTracking,toggleResolved:toggleResolved)
            store.journeyRevision += 1; error = nil
        } catch { self.error = error.localizedDescription; store.errorMessage = self.error }
    }

}
private extension Optional where Wrapped == DifficultCardCare {
    func asyncComparison(db: AppDatabase) async throws -> CardCareComparison? {
        guard let value = self else { return nil }
        return try await db.cardCareComparison(value)
    }
}

