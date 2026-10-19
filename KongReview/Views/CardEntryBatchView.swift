import SwiftUI
import KongReviewCore

struct CardEntryBatchView: View {
    @Environment(LibraryStore.self) private var store
    let batchID: UUID
    @State private var result: CardEntryBatchPage?
    @State private var page = 1
    @State private var pageInput = "1"
    @State private var selected = Set<Int64>()
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?
    @State private var deck = ""
    @State private var tags = ""
    @State private var removeTags = false
    @State private var preview: CardEditorPreviewSnapshot?

    private var active: Bool { store.cardWorkflow.batchID == batchID }
    private var blocked: Bool { !active || store.fullBackupBusy || loading }
    private var visibleIDs: Set<Int64> { Set(result?.cards.compactMap(\.id) ?? []) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("本次录入清单").font(.title2.bold())
            CardEntryOrganizationUndoBanner()
            Text("本次新建 \(store.cardWorkflow.addedCardIDs.count) 张，当前可查看 \(result?.total ?? 0) 张。已删除的卡片不在列表中。")
                .font(.caption).foregroundStyle(.secondary)
            if !active { Text("本次录入已结束，请关闭后打开新的录入清单。").foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("当前页全选") { selected = visibleIDs }.disabled(visibleIDs.isEmpty)
                Button("清空选择") { selected = [] }.disabled(selected.isEmpty)
                Text("已选 \(selected.count) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.controlSize(.small).disabled(blocked)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(result?.cards ?? []) { card in
                        HStack(alignment:.top,spacing:12) {
                            Toggle("选择卡片",isOn:Binding(get:{ selected.contains(card.id!) },set:{ on in
                                if on { selected.insert(card.id!) } else { selected.remove(card.id!) }
                            })).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment:.leading,spacing:4) {
                                Text(Markdown.plainText(fromHTML:Card.renderHTML(store.faces(of:card).front))).lineLimit(3)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                Text(card.deck + (card.tags.isEmpty ? "" : " · " + TagParser.format(card.tags)))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Button("预览") { preview = .init(draft:CardDraft(card:card),templates:store.noteTemplates) }.handCursor()
                            Button("编辑") { store.scheduleCardEntryBatchEdit(id:card.id!,batchID:batchID) }.handCursor()
                        }.padding(12).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
                    }
                    if result?.cards.isEmpty == true {
                        ContentUnavailableView("本次暂无可查看的卡片",systemImage:"rectangle.stack")
                    }
                }.padding(.trailing,6)
            }.frame(minHeight:200).disabled(blocked)
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    TextField("目标牌组",text:$deck).textFieldStyle(.roundedBorder)
                    Menu("选择牌组") {
                        ForEach((try? store.db.deckNames()) ?? [],id:\.self) { value in Button(value) { deck = value } }
                    }.fixedSize()
                    Button("移动所选卡片") { apply(.move(deck)) }.disabled(selected.isEmpty || deck.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    TextField("标签，用空格或逗号分隔",text:$tags).textFieldStyle(.roundedBorder)
                    Picker("标签操作",selection:$removeTags) { Text("添加标签").tag(false); Text("移除标签").tag(true) }
                        .labelsHidden().fixedSize()
                    Button("应用到所选卡片") { apply(.tags(TagParser.parse(tags),removeTags ? .remove : .add)) }
                        .disabled(selected.isEmpty || TagParser.parse(tags).isEmpty)
                }
            }.controlSize(.small).disabled(blocked)
            HStack(spacing:10) {
                Button("上一页") { page = max(1,page - 1) }.disabled(page <= 1 || blocked)
                Text("第 \(result?.page ?? page) / \(result?.pageCount ?? 1) 页").font(.caption)
                Button("下一页") { page += 1 }.disabled(page >= (result?.pageCount ?? 1) || blocked)
                TextField("页码",text:$pageInput).frame(width:44).textFieldStyle(.roundedBorder)
                    .onSubmit { jump() }.disabled(blocked)
                Button("跳转") { jump() }.disabled(blocked)
                Spacer()
                Button("关闭") { store.cardWorkflow.showsBatch = false }.keyboardShortcut(.cancelAction)
            }.controlSize(.small)
            Text("编辑其他卡片前会保留当前输入。重新开始录入后清空本次清单，正式卡片仍保留。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth:720,idealWidth:800,minHeight:560,idealHeight:650)
        .task(id:"\(batchID)|\(page)|\(store.revision)") { await load() }
        .onChange(of:page) { _,_ in selected = [];pageInput = String(page) }
        .sheet(item:$preview) { CardEditorPreviewView(snapshot:$0,savedCard:true) }
    }

    private func jump() {
        page = min(max(1,Int(pageInput) ?? page),result?.pageCount ?? 1)
        pageInput = String(page)
    }
    private func apply(_ change: CardEntryBatchChange) {
        do {
            try store.changeCurrentCardEntryBatch(ids:Array(selected.intersection(visibleIDs)),batchID:batchID,change:change)
            selected = [];error = nil;message = "已更新所选卡片。"
        } catch { self.error = error.localizedDescription }
    }
    private func load() async {
        guard active else { loading = false; return }
        loading = true
        let db = store.db,ids = store.cardWorkflow.addedCardIDs,requested = page
        do {
            let value = try await Task.detached(priority:.userInitiated) { try db.cardEntryBatchPage(ids:ids,page:requested) }.value
            try Task.checkCancellation()
            guard active,page == requested else { return }
            result = value; page = value.page;pageInput = String(value.page)
            selected.formIntersection(Set(value.cards.compactMap(\.id)))
            error = nil;loading = false
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription;loading = false }
    }
}

struct CardEntryBatchPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    var insideEditor: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented:Binding(get:{ store.cardWorkflow.showsBatch && (store.cardEditor != nil) == insideEditor },
            set:{ if !$0 { store.cardWorkflow.showsBatch = false } }),onDismiss:{ store.performPendingCardEntryBatchEdit() }) {
            CardEntryBatchView(batchID:store.cardWorkflow.batchID)
        }
    }
}
