import SwiftUI
import KongReviewCore
struct TopicLearningView: View {
    @Environment(LibraryStore.self) private var store
    let notebookID: Int64
    private var timeline: Binding<Bool> { Binding(get:{ store.journeyNavigation.topicTimelineIDs.contains(notebookID) },set:{ if $0 { store.journeyNavigation.topicTimelineIDs.insert(notebookID) } else { store.journeyNavigation.topicTimelineIDs.remove(notebookID) } }) }
    @State private var section: TopicSection = .highlights
    @State private var page = 0
    @State private var snapshot: TopicSnapshot?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = snapshot {
                Text("\(s.highlights) 条摘录 · \(s.cards) 张卡片 · \(s.sources) 个出处").font(.headline)
                Text("\(s.studied) / \(s.cards) 张卡片已有学习次数记录（包括导入记录）").font(.callout).foregroundStyle(.secondary)
                if s.cards > 0 { ProgressView(value: Double(s.studied), total: Double(s.cards)) }
            }
            HStack {
                Button("继续阅读／编排") { store.selection = .notebook(notebookID) }
                Button("回顾本专题") {
                    store.review.theme = ReviewScope.notebook(notebookID)
                    store.review.sessionToken += 1
                    store.selection = .review
                }.disabled(snapshot?.highlights == 0)
                Button("学习关联记忆卡") { store.startNotebookStudy(notebookID) }.disabled(snapshot?.cards == 0)
                Button("导出学习资料…") { store.learningMaterialExport = .init(scope: .notebook(notebookID)) }
            }.handCursor()
            Picker("专题内容",selection:Binding(get:{store.journeyNavigation.showTopicQuestions ? 2 : timeline.wrappedValue ? 1 : 0},set:{ store.journeyNavigation.showTopicQuestions = $0 == 2; timeline.wrappedValue = $0 == 1 })) {
                Text("资料").tag(0); Text("成长轨迹").tag(1); Text("问题与解答").tag(2)
            }.pickerStyle(.segmented)
            if store.journeyNavigation.showTopicQuestions { TopicQuestionsView(notebookID:notebookID).id(notebookID) } else if timeline.wrappedValue { TopicTimelineView(notebookID:notebookID) } else {
            Picker("资料",selection:$section) { ForEach(TopicSection.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                .onChange(of: section) { _,_ in page = 0 }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(snapshot?.page.rows ?? []) { row in
                        Button { if let target = row.target { store.learningExplorer = .init(route:.document(target,"")) } } label: {
                            Text(row.title).frame(maxWidth:.infinity,alignment:.leading).padding(12)
                                .background(ReviewPalette.card,in:RoundedRectangle(cornerRadius:10))
                        }.buttonStyle(.plain).handCursor()
                    }
                }
            }
            HStack {
                Text("第 \(page+1) / \(max(1,((snapshot?.page.total ?? 0)+49)/50)) 页")
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0 || loading)
                Button("下一页") { page += 1 }.disabled((page+1)*50 >= (snapshot?.page.total ?? 0) || loading)
            }
            }
        }.task(id:"\(notebookID)|\(section)|\(page)|\(store.revision)") {
            loading = true
            do {
                let value = try await store.db.topicSnapshot(scope:.notebook(notebookID),section:section,offset:page*50)
                try Task.checkCancellation(); snapshot = value; error = nil; loading = false; if page > 0 && value.page.rows.isEmpty { page = max(0,(value.page.total-1)/50) }
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}
