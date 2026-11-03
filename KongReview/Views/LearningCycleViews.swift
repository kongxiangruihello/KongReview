import SwiftUI

struct TopicTimelineView: View {
    @Environment(LibraryStore.self) private var store
    let notebookID: Int64
    @State private var result = GrowthPage<TopicTimelineEntry>(items:[],total:0)
    @State private var error: String?
    @State private var anchor: String?
    private var page: Binding<Int> { Binding(get:{store.journeyNavigation.topicPages[notebookID] ?? 0},set:{store.journeyNavigation.topicPages[notebookID] = $0}) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("摘录按当前专题归属；笔记／按语显示最近修改时间。卡片修改从3.3起记录修改时的专题归属，删除原卡后仍保留轨迹。旧版未保存的修改过程无法追补。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(result.items) { item in
                        VStack(alignment:.leading,spacing:6) {
                            Text("\(item.at.formatted(date:.abbreviated,time:.shortened)) · \(item.kind)").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup {
                                Text(item.title).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                            } label: { Text(item.title).lineLimit(3) }
                            if let target = item.target { Button("打开原条目") { anchor = item.id; store.learningExplorer = .init(route:.document(target,"")) } }
                            Divider()
                        }.id(item.id)
                    }
                    if result.items.isEmpty { Text("本专题暂无成长记录。").foregroundStyle(.secondary) }
                }.scrollTargetLayout()
            }.scrollPosition(id:$anchor,anchor:.top)
            JourneyPager(page:page,total:result.total)
        }
        .onChange(of:anchor) { _,value in store.journeyNavigation.anchors["topic.\(notebookID)"] = value }
        .task(id:"\(notebookID)|\(page.wrappedValue)|\(store.revision)|\(store.journeyRevision)|\(store.growthGeneration)") {
            do { let value = try await store.db.topicTimeline(notebookID:notebookID,offset:page.wrappedValue*50); try Task.checkCancellation(); result = value; error = nil; if page.wrappedValue > 0 && value.items.isEmpty { page.wrappedValue = max(0,(value.total-1)/50) }; if anchor == nil { anchor = store.journeyNavigation.anchors["topic.\(notebookID)"] } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

