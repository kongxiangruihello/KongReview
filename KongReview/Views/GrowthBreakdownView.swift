import SwiftUI

struct GrowthBreakdownView: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    let metric: GrowthMetric
    @State private var grouping: GrowthGrouping = .source
    @State private var groups = GrowthPage<GrowthBreakdownGroup>(items:[],total:0)
    @State private var selected: GrowthBreakdownGroup?
    @State private var details = LearningExplorerPage(rows:[],total:0)
    @State private var groupPage = 0
    @State private var detailPage = 0
    @State private var loading = false
    @State private var detailsLoading = false
    @State private var error: String?
    var body: some View {
        if metric != .days {
            GroupBox("本期主要学了什么 · \(metric.title)") {
                VStack(alignment:.leading,spacing:12) {
                    Picker("汇总方式",selection:$grouping) {
                        ForEach(GrowthGrouping.allCases.filter { $0 != .deck || metric.isCardMetric }) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("按资料当前的归属汇总。卡片通过原摘录关联出处和专题；同一条内容可属于多个专题，因此专题数量不能直接相加。删除或未关联的内容单列。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    if loading { ProgressView() }
                    if groups.items.isEmpty && !loading { Text("本期暂无这一类记录。").foregroundStyle(.secondary) }
                    ForEach(groups.items) { group in
                        Button { selected = group; detailPage = 0 } label: {
                            HStack { Text(group.title).lineLimit(3); Spacer(); Text("\(group.count)").monospacedDigit(); Image(systemName:"chevron.right") }
                                .padding(8).background(selected?.id == group.id ? ReviewPalette.accentSoft : ReviewPalette.card,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).handCursor()
                    }
                    if groups.total > 50 { JourneyPager(page:$groupPage,total:groups.total).disabled(loading) }
                    if let selected {
                        Divider()
                        HStack { Text("\(selected.title) · \(details.total) 项").font(.headline); Spacer(); Button("收起明细") { self.selected = nil } }
                        if detailsLoading { ProgressView() }
                        else {
                            ForEach(details.rows) { row in
                                Button { if let target = row.target { store.learningExplorer = .init(route:.document(target,"")) } } label: {
                                    VStack(alignment:.leading,spacing:4) { Text(row.title).lineLimit(4); Text(row.detail).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                                }.buttonStyle(.plain).handCursor().disabled(row.target == nil)
                            }
                            JourneyPager(page:$detailPage,total:details.total)
                        }
                    }
                }.padding(8)
            }
            .onChange(of: grouping) { _,_ in groupPage = 0; selected = nil; detailPage = 0 }
            .task(id:"\(grouping)|\(groupPage)|\(store.revision)") {
                loading = true
                do { let value = try await store.db.growthBreakdown(metric:metric,grouping:grouping,start:window.start,end:window.end,offset:groupPage*50); try Task.checkCancellation(); groups = value; loading = false; error = nil; if groupPage > 0 && value.items.isEmpty { groupPage = max(0,(value.total-1)/50) } }
                catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
            }
            .task(id:"\(selected?.id ?? "none")|\(grouping)|\(detailPage)|\(store.revision)") {
                guard let selected else { return }; detailsLoading = true
                do { let value = try await store.db.growthBreakdownDetails(metric:metric,grouping:grouping,key:selected.key,start:window.start,end:window.end,offset:detailPage*50); try Task.checkCancellation(); details = value; detailsLoading = false; if detailPage > 0 && value.rows.isEmpty { detailPage = max(0,(value.total-1)/50) } }
                catch is CancellationError { } catch { self.error = error.localizedDescription; detailsLoading = false }
            }
        }
    }
}
