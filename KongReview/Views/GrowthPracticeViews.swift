import SwiftUI

/// 4.1.1：专题页“问题与解答”——问题簿中归入本专题的问题（数据在问题簿，入口保留）
struct TopicQuestionsView: View {
    @Environment(LibraryStore.self) private var store
    let notebookID: Int64
    private var solved: Bool { get { store.journeyNavigation.questionSolved[notebookID] ?? false } nonmutating set { store.journeyNavigation.questionSolved[notebookID] = newValue } }
    private var query: String { get { store.journeyNavigation.questionQueries[notebookID] ?? "" } nonmutating set { store.journeyNavigation.questionQueries[notebookID] = newValue } }
    private var page: Int { get { store.journeyNavigation.questionPages[notebookID] ?? 0 } nonmutating set { store.journeyNavigation.questionPages[notebookID] = newValue } }
    @State private var anchor: Int64?
    @State private var result = GrowthPage<QuestionSummary>(items:[],total:0)
    @State private var drafts: [QuestionDraft] = []
    @State private var error: String?
    @State private var loading = false
    private var filter: QuestionFilter { QuestionFilter(state: solved ? .solved : .unsolved, query: query, notebookID: notebookID) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("状态",selection:Binding(get:{solved},set:{solved=$0})) { Text("待解决").tag(false); Text("已解决").tag(true) }.pickerStyle(.segmented)
                Button("记录问题") { store.newQuestion(notebookID:notebookID) }
                Button("在问题簿中查看") { store.openQuestionBook(QuestionFilter(state: solved ? .solved : .unsolved, notebookID: notebookID)) }
            }
            TextField("搜索问题、说明或解答",text:Binding(get:{query},set:{query=$0})).textFieldStyle(.roundedBorder)
            Text("问题收在问题簿里：一个问题可同时归入几个专题与项目，可挂多条材料。这里列出归入本专题的问题。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    if !drafts.isEmpty {
                        DisclosureGroup("未保存的输入 · \(drafts.count)") {
                            ForEach(drafts) { d in QuestionDraftRow(draft:d) }
                        }
                    }
                    ForEach(result.items) { item in QuestionRow(q:item).id(item.id) }
                    if result.items.isEmpty && !loading { Text(solved ? "还没有已解决的问题。" : "暂时没有待解决的问题。").foregroundStyle(.secondary) }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page:Binding(get:{page},set:{page=$0}),total:result.total).disabled(loading)
        }
        .onChange(of:anchor) { _,value in store.journeyNavigation.anchors["questions.\(notebookID)"] = value.map(String.init) }
        .onChange(of:solved) { _,_ in page = 0; anchor = nil; store.journeyNavigation.anchors["questions.\(notebookID)"] = nil }
        .onChange(of:query) { _,_ in page = 0; anchor = nil; store.journeyNavigation.anchors["questions.\(notebookID)"] = nil }
        .task(id:"\(notebookID)|\(solved)|\(query)|\(page)|\(store.questionRevision)|\(store.journeyRevision)|\(store.growthGeneration)") {
            loading = true
            do {
                let value = try await store.db.questionPage(filter,offset:page*50); try Task.checkCancellation()
                result = value; error = nil; loading = false
                if anchor == nil { anchor = store.journeyNavigation.anchors["questions.\(notebookID)"].flatMap { Int64($0) } }
                if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) }
                drafts = try store.db.questionDrafts(notebookID:notebookID)
            }
            catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}
