import SwiftUI
import KongReviewCore

struct RelatedCardsInline: View {
    @Environment(LibraryStore.self) private var store
    let highlightID: Int64
    @State private var page = 0
    @State private var result = LearningExplorerPage(rows: [], total: 0)
    @State private var error: String?
    @State private var expanded = false
    var body: some View {
        Section {
            DisclosureGroup("已有 \(result.total) 张关联记忆卡", isExpanded: $expanded) {
                Text("可从摘录列表右键“查看关联记忆卡”，或回顾页的脑形图标打开比较和编辑。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(result.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).lineLimit(3)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if result.total > 50 {
                    HStack {
                        Button("上一页") { page -= 1 }.disabled(page == 0)
                        Text("第 \(page+1) 页")
                        Button("下一页") { page += 1 }.disabled((page+1)*50 >= result.total)
                    }
                }
            }
        }
        .task(id: "\(highlightID)|\(page)|\(store.revision)") {
            do {
                let next = try await store.db.learningExplorerPage(.related(highlightID), offset: page*50)
                try Task.checkCancellation(); result = next; error = nil
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
