import SwiftUI
import KongReviewCore

struct CareContentHistoryView: View {
    @Environment(LibraryStore.self) private var store
    let cardID: Int64
    var onOpenCard: ((Int64) -> Void)? = nil
    @State private var changes = GrowthPage<CareAdjustment>(items:[],total:0)
    @State private var related = GrowthPage<RelatedCareCard>(items:[],total:0)
    @State private var page = 0
    @State private var relatedPage = 0
    @State private var choosing = false
    @State private var query = ""
    @State private var choicePage = 0
    @State private var choices = GrowthPage<LearningPlanLink>(items:[],total:0)
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            DisclosureGroup("调整前后内容 · \(changes.total) 次") {
                if changes.items.isEmpty { Text("尚无内容调整记录。先保存处理原因，再编辑原卡；保存修改时会自动记录前后内容并开始观察。旧版本未留存的内容无法补录。").font(.caption).foregroundStyle(.secondary) }
                ForEach(changes.items) { change in
                    DisclosureGroup(change.at.formatted(date:.abbreviated,time:.shortened)) {
                        CareSnapshotComparison(change:change)
                    }
                }
                if changes.total > 50 { JourneyPager(page:$page,total:changes.total) }
            }
            DisclosureGroup("拆分卡关联 · \(related.total) 张") {
                Text("关联已创建的拆分卡。每张卡单独显示最近一次跟踪开始后、最长14天的正式评分，避免把不同问题混成一个改善比例。").font(.caption).foregroundStyle(.secondary)
                ForEach(related.items) { card in
                    VStack(alignment:.leading,spacing:4) {
                        Text(card.title).lineLimit(3)
                        Text("重来 \(card.again) / 评分 \(card.ratings)" + (card.available ? "" : " · 原卡已删除")).font(.caption)
                        HStack {
                            Button("查看卡片") { if let onOpenCard { onOpenCard(card.id) } else { store.learningExplorer = .init(route:.document(.init(kind:.card,recordID:card.id),"")) } }.disabled(!card.available)
                            Button("移除关联") { link(card.id,remove:true) }
                        }
                    }.padding(5)
                }
                if related.total > 50 { JourneyPager(page:$relatedPage,total:related.total) }
                Button(choosing ? "收起选择" : "关联拆分后的卡片…") { choosing.toggle() }
                if choosing {
                    TextField("搜索卡片正面",text:$query).textFieldStyle(.roundedBorder)
                    ForEach(choices.items.filter { $0.recordID != cardID }) { choice in
                        Button { link(choice.recordID); choosing = false } label: { Text(choice.title).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).handCursor()
                    }
                    JourneyPager(page:$choicePage,total:choices.total)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: query) { _,_ in choicePage = 0 }
        .task(id:"\(cardID)|\(page)|\(store.revision)|\(store.journeyRevision)") {
            do { let value = try await store.db.careAdjustments(cardID:cardID,offset:page*50); try Task.checkCancellation(); changes = value; if page > 0 && value.items.isEmpty { page = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .task(id:"\(cardID)|\(relatedPage)|\(store.revision)|\(store.journeyRevision)") {
            do { let value = try await store.db.careRelatedCards(cardID:cardID,offset:relatedPage*50); try Task.checkCancellation(); related = value; if relatedPage > 0 && value.items.isEmpty { relatedPage = max(0,(value.total-1)/50) } }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .task(id:"\(choosing)|\(query)|\(choicePage)|\(store.revision)") {
            guard choosing else { return }
            do { try await Task.sleep(for:.milliseconds(180)); let value = try await store.db.planLinkChoices(kind:.card,query:query,offset:choicePage*50); try Task.checkCancellation(); choices = value }
            catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    private func link(_ id: Int64, remove: Bool = false) {
        guard !store.fullBackupBusy else { return }
        do { try store.db.linkCareCard(parent:cardID,child:id,remove:remove); store.journeyRevision += 1; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
struct CareSnapshotComparison: View {
    let change: CareAdjustment
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            snapshot(change.before,title:"调整前")
            Divider()
            snapshot(change.after,title:"调整后")
        }.padding(8).textSelection(.enabled)
    }
    private func snapshot(_ card: Card, title: String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.headline)
            Text("问题：" + plain(card.front))
            Text("答案：" + plain(card.back))
            ForEach(Array((card.sections ?? []).enumerated()),id:\.offset) { _, section in Text(section.name + "：" + plain(section.text)) }
            ForEach(Array(card.fields.enumerated()),id:\.offset) { index, text in Text("字段 \(index+1)：" + plain(text)) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func plain(_ text: String) -> String { Markdown.plainText(fromHTML:Card.renderHTML(text)) }
}
