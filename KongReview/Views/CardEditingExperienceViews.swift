import SwiftUI
import KongReviewCore

struct CardComparisonView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let incoming: Card
    let existing: Card
    var draftID: UUID? = nil
    @State private var confirming = false
    @State private var showsTextDifference = true
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(draftID == nil ? "修改前后对照" : "重复卡片对照").font(.title2.bold())
            Toggle("标出文字差异（绿色新增、红色删除、橙色改动）",isOn:$showsTextDifference).toggleStyle(.checkbox)
            Text("按段落比较正文文字；排版和媒体变化请关闭此选项查看原排版。").font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:16) {
                pane(incoming,title:"当前输入")
                Divider()
                pane(existing,title:draftID == nil ? "上次保存" : "已有卡片")
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("正面、背面及出处分别对照；当前输入尚未保存。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                if draftID != nil, existing.deletedAt == nil {
                    Button("追加当前答案到已有卡片…") { confirming = true }.disabled(store.fullBackupBusy)
                }
            }
        }.padding(20).frame(minWidth:760,minHeight:550)
        .confirmationDialog("确认追加答案？",isPresented:$confirming,titleVisibility:.visible) {
            Button("确认追加并保存") { append() }
        } message: { Text("把左侧答案追加到右侧卡片，保留原答案及学习进度，不新建卡片。成功后关闭当前草稿。") }
    }
    private func pane(_ card: Card,title: String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.headline)
            Text("牌组：" + card.deck).font(.caption)
            Text(context(card)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            let faces = store.faces(of:card)
            Text("正面").font(.caption.bold())
            faceView(faces.front,front:true,current:title == "当前输入").frame(minHeight:120)
            Text("背面").font(.caption.bold())
            faceView(faces.back,front:false,current:title == "当前输入").frame(minHeight:180)
        }.frame(maxWidth:.infinity)
    }
    @ViewBuilder private func faceView(_ html: String,front: Bool,current: Bool) -> some View {
        if showsTextDifference {
            let old = store.faces(of:existing), new = store.faces(of:incoming)
            let difference = ParagraphDifference.make(before:front ? old.front : old.back,after:front ? new.front : new.back)
            VStack(alignment:.leading,spacing:4) {
                if difference.coarse { Text("长文采用区块比较").font(.caption).foregroundStyle(.secondary) }
                ParagraphDifferenceView(rows:current ? difference.after : difference.before)
            }
        } else { CardWebView(front:html,back:nil,store:store) }
    }
    private func context(_ card: Card) -> String {
        guard let id = card.highlightId else { return "出处：未关联摘录" }
        do {
            guard let h = try store.db.highlight(id:id) else { return "出处：原摘录已删除" }
            let source = try store.db.source(id:h.sourceId)
            return "出处：" + (source?.title ?? "未归类") + (h.location.map { " · " + $0 } ?? "")
        } catch { return "出处读取失败：" + error.localizedDescription }
    }
    private func append() {
        guard !store.fullBackupBusy else { return }
        do {
            guard let id = draftID, store.cardEditor?.id == id, store.cardEditor?.card == incoming else { throw CardComparisonError.noDraft }
            let saved = try store.db.appendCardAnswer(from:incoming,to:existing)
            if store.study.current?.id == saved.id { store.study.current = saved }
            store.finishCardEditorDraft(id:id); store.cardEditor = nil; store.reload(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct CardHistoryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: Int64
    @State private var versions: [CardContentVersion] = []
    @State private var selected: UUID?
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("正文修改历史").font(.title2.bold())
            Text("保留最近 100 个版本，从本版开始记录；恢复只替换编辑器里的正文，学习进度、牌组与标签保持当前值，点击保存后生效。").font(.caption).foregroundStyle(.secondary)
            HStack {
                List(versions,selection:$selected) { version in
                    Text(version.date.formatted(date:.abbreviated,time:.standard)).tag(version.id)
                }.frame(width:210)
                if let version = versions.first(where:{$0.id == selected}) {
                    let faces = store.faces(of:version.card)
                    CardWebView(front:faces.front,back:faces.back,store:store)
                } else { Text("选择一个版本查看内容").frame(maxWidth:.infinity) }
            }.frame(minHeight:320)
            if versions.isEmpty { Text("还没有正文修改历史；旧版未记录的历史无法追补。").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("关闭") { dismiss() }
                Button("恢复此版本到编辑器") {
                    guard let v = versions.first(where:{$0.id == selected}), let current = store.cardEditor?.card, current.id == cardID else { return }
                    store.cardEditor?.card = v.applying(to:current); dismiss()
                }.disabled(selected == nil || store.fullBackupBusy)
            }
        }.padding(20).frame(minWidth:740,minHeight:500)
        .onAppear { do { versions = try store.db.cardContentHistory(id:cardID); selected = versions.first?.id } catch { self.error = error.localizedDescription } }
    }
}
