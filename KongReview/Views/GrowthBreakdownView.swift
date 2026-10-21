import SwiftUI

/// 学习小结第三节：当前指标按出处、专题或牌组的分布（表 3）。点选一行，在表下列出该组明细。
struct GrowthBreakdownView: View {
    @Environment(LibraryStore.self) private var store
    let window: GrowthWindow
    let metric: GrowthMetric
    /// 本期该指标的总数，用于计算占比；专题可重叠，按专题时不计占比
    var total: Int = 0
    @State private var grouping: GrowthGrouping = .source
    @State private var groups = GrowthPage<GrowthBreakdownGroup>(items:[],total:0)
    @State private var selected: GrowthBreakdownGroup?
    @State private var details = LearningExplorerPage(rows:[],total:0)
    @State private var groupPage = 0
    @State private var detailPage = 0
    @State private var loading = false
    @State private var detailsLoading = false
    @State private var error: String?

    private var groupLabel: String { switch grouping { case .source: "出处"; case .notebook: "专题"; case .deck: "牌组" } }
    private var showsShare: Bool { grouping != .notebook && total > 0 }

    var body: some View {
        if metric != .days {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("汇总方式").font(AcademicType.note).foregroundStyle(ReviewPalette.sub)
                    Picker("汇总方式",selection:$grouping) {
                        ForEach(GrowthGrouping.allCases.filter { $0 != .deck || metric.isCardMetric }) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
                if let error { Text(error).foregroundStyle(.red) }
                if loading && groups.items.isEmpty { ProgressView() }
                AcademicTable(label: "表 3", title: "本期“\(metric.title)”\(grouping.title)分布",
                              note: "按资料当前的归属汇总。卡片通过原摘录关联出处和专题；同一条内容可属于多个专题，因此按专题时各行不能直接相加，也不计占比。删除或未关联的内容单列。点选一行查看该组明细。") {
                    Text("序号").gridColumnAlignment(.trailing)
                    Text(groupLabel)
                    Text("数量").gridColumnAlignment(.trailing)
                    if showsShare { Text("占比").gridColumnAlignment(.trailing) }
                } rows: {
                    if groups.items.isEmpty && !loading {
                        GridRow {
                            Text("—").foregroundStyle(ReviewPalette.sub)
                            Text("本期暂无这一类记录。").foregroundStyle(ReviewPalette.sub)
                                .gridCellColumns(showsShare ? 3 : 2)
                        }
                        .academicCell()
                    }
                    ForEach(Array(groups.items.enumerated()), id: \.element.id) { index, group in
                        let on = selected?.id == group.id
                        GridRow {
                            Text("\(groupPage * 50 + index + 1)").foregroundStyle(ReviewPalette.sub)
                            HStack(spacing: 6) {
                                Text(group.title).lineLimit(2)
                                if on { Text("▾").foregroundStyle(ReviewPalette.accent) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(group.count)").fontWeight(.semibold)
                            if showsShare {
                                Text(String(format: "%.1f%%", Double(group.count) / Double(total) * 100)).foregroundStyle(ReviewPalette.sub)
                            }
                        }
                        .monospacedDigit()
                        .foregroundStyle(on ? ReviewPalette.accent : ReviewPalette.ink)
                        .academicCell()
                        .contentShape(Rectangle())
                        .onTapGesture { selected = on ? nil : group; detailPage = 0 }
                        .handCursor()
                    }
                }
                if groups.total > 50 { JourneyPager(page:$groupPage,total:groups.total).disabled(loading).controlSize(.small) }
                if let selected {
                    AcademicQuote(label: "表 3 第“\(selected.title)”组明细 · 共 \(details.total) 项") {
                        if detailsLoading { ProgressView() }
                        else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(details.rows.enumerated()), id: \.element.id) { index, row in
                                    Button { if let target = row.target { store.learningExplorer = .init(route:.document(target,"")) } } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text("(\(detailPage * 50 + index + 1))").font(AcademicType.note).monospacedDigit().foregroundStyle(ReviewPalette.sub)
                                            VStack(alignment:.leading,spacing:2) {
                                                Text(row.title).lineLimit(4)
                                                Text(row.detail).font(AcademicType.note).foregroundStyle(ReviewPalette.sub)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain).handCursor().disabled(row.target == nil)
                                }
                                HStack {
                                    JourneyPager(page:$detailPage,total:details.total)
                                    Button("收起明细") { self.selected = nil }
                                }
                                .font(AcademicType.note).controlSize(.small)
                            }
                        }
                    }
                }
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
