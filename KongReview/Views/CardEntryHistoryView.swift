import SwiftUI
import KongReviewCore

private struct CardEntryHistoryLoadKey: Equatable {
    var query: CardEntryHistoryQuery
    var page: Int
    var revision: Int
    var generation: UUID
}

struct CardEntryHistoryView: View {
    @Environment(LibraryStore.self) private var store
    let generation: UUID
    @State private var date = Date()
    @State private var allDates = false
    @State private var usesDateRange = false
    @State private var endDate = Date()
    @State private var search = ""
    @State private var filterDeck = ""
    @State private var page = 1
    @State private var pageInput = "1"
    @State private var result: CardEntryHistoryPage?
    @State private var loadedKey: CardEntryHistoryLoadKey?
    @State private var loading = true
    @State private var selected = Set<Int64>()
    @State private var deck = ""
    @State private var tags = ""
    @State private var removeTags = false
    @State private var error: String?
    @State private var message: String?
    @State private var preview: CardEditorPreviewSnapshot?
    @State private var practice: CardEntryPracticeSession?
    private var query: CardEntryHistoryQuery { .init(date:allDates ? nil : date,endDate:!allDates && usesDateRange ? max(date,endDate) : nil,text:search,deck:filterDeck) }
    private var loadKey: CardEntryHistoryLoadKey { .init(query:query,page:page,revision:store.revision,generation:generation) }
    private var active: Bool { generation == store.cardEntryHistory.generation }
    private var blocked: Bool { loading || loadedKey != loadKey || !active || store.fullBackupBusy }
    private var visibleIDs: Set<Int64> { Set(result?.items.map(\.id) ?? []) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("今日录入与录入历史").font(.title2.bold())
            Text("记录从 3.11 起在本应用新建的卡片，重复保存和导入不计入。删除的卡片暂不显示，恢复后仍归原录入日期。")
                .font(.caption).foregroundStyle(.secondary)
            CardEntryOrganizationUndoBanner()
            HStack {
                Toggle("全部日期",isOn:$allDates).toggleStyle(.checkbox)
                Toggle("日期范围",isOn:$usesDateRange).toggleStyle(.checkbox).disabled(allDates)
                DatePicker("录入日期",selection:$date,displayedComponents:.date).labelsHidden().disabled(allDates)
                if usesDateRange && !allDates { Text("至");DatePicker("结束日期",selection:$endDate,in:date...,displayedComponents:.date).labelsHidden() }
                Button("今天") { allDates = false;usesDateRange = false;date = Date() }.handCursor()
                Spacer()
            }.disabled(store.fullBackupBusy || !active)
            HStack {
                TextField("搜索题面、答案、标签或牌组",text:$search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("card-entry-history-search")
                Picker("牌组",selection:$filterDeck) {
                    Text("全部牌组").tag("")
                    ForEach((try? store.db.deckNames()) ?? [],id:\.self) { Text($0).tag($0) }
                }.frame(maxWidth:210)
            }.disabled(store.fullBackupBusy || !active)
            if !active { Text("资料已重新载入，请关闭后重新打开录入历史。").foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("当前页全选") { selected = visibleIDs }.disabled(visibleIDs.isEmpty)
                Button("清空选择") { selected = [] }.disabled(selected.isEmpty)
                Text("已选 \(selected.count) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("额外练习所选卡片") { startPractice() }.disabled(selected.isEmpty).handCursor()
                if loading { ProgressView().controlSize(.small) }
            }.controlSize(.small).disabled(blocked)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(result?.items ?? []) { item in
                        HStack(alignment:.top,spacing:10) {
                            Toggle("选择卡片",isOn:Binding(get:{ selected.contains(item.id) },set:{ if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                                .labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment:.leading,spacing:4) {
                                Text(Markdown.plainText(fromHTML:Card.renderHTML(store.faces(of:item.card).front))).lineLimit(3)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                Text(item.card.deck + (item.card.tags.isEmpty ? "" : " · " + TagParser.format(item.card.tags)))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(item.recordedAt,format:.dateTime.year().month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                                learningStatus(item.card)
                            }
                            Button("预览") { preview = .init(draft:CardDraft(card:item.card),templates:store.noteTemplates) }.handCursor()
                            Button("编辑") { store.scheduleCardEntryHistoryEdit(id:item.id,query:query,generation:generation) }.handCursor()
                        }.padding(12).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
                    }
                    if result?.items.isEmpty == true { ContentUnavailableView("没有符合条件的录入记录",systemImage:"calendar",description:Text("可选择其他日期，或查看全部日期。")) }
                }.padding(.trailing,6)
            }.frame(minHeight:180).disabled(blocked)
            Text("状态按当前排程显示；正式作答次数包含学习、复习和重学，额外练习不计入。")
                .font(.caption2).foregroundStyle(.secondary)
            VStack(spacing:8) {
                HStack {
                    TextField("目标牌组",text:$deck).textFieldStyle(.roundedBorder)
                    Menu("选择牌组") { ForEach((try? store.db.deckNames()) ?? [],id:\.self) { value in Button(value) { deck = value } } }.fixedSize()
                    Button("移动所选卡片") { apply(.move(deck)) }.disabled(selected.isEmpty || deck.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    TextField("标签，用空格或逗号分隔",text:$tags).textFieldStyle(.roundedBorder)
                    Picker("标签操作",selection:$removeTags) { Text("添加标签").tag(false);Text("移除标签").tag(true) }.labelsHidden().fixedSize()
                    Button("应用到所选卡片") { apply(.tags(TagParser.parse(tags),removeTags ? .remove : .add)) }.disabled(selected.isEmpty || TagParser.parse(tags).isEmpty)
                }
            }.controlSize(.small).disabled(blocked)
            HStack(spacing:10) {
                Text("共 \(result?.total ?? 0) 张").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page <= 1 || blocked)
                Text("第 \(result?.page ?? page) / \(result?.pageCount ?? 1) 页").font(.caption)
                Button("下一页") { page += 1 }.disabled(page >= (result?.pageCount ?? 1) || blocked)
                TextField("页码",text:$pageInput).textFieldStyle(.roundedBorder).frame(width:44).onSubmit { jump() }.disabled(blocked)
                Button("跳转") { jump() }.disabled(blocked)
                Button("关闭") { store.cardEntryHistory.isPresented = false }.keyboardShortcut(.cancelAction)
            }.controlSize(.small)
        }.padding(20).frame(minWidth:740,idealWidth:830,minHeight:620,idealHeight:720)
            .task(id:loadKey) { await load() }
            .onChange(of:query) { _,_ in page = 1;pageInput = "1";selected = [] }
            .onChange(of:date) { _,value in if endDate < value { endDate = value } }
            .onChange(of:page) { _,_ in pageInput = String(page);selected = [] }
            .sheet(item:$preview) { CardEditorPreviewView(snapshot:$0,savedCard:true) }
            .sheet(item:$practice) { CardEntryPracticeView(session:$0) }
    }

    @ViewBuilder private func learningStatus(_ card: Card) -> some View {
        let status = CardEntryLearningStatus(card:card)
        HStack(spacing:8) {
            Text(status.rawValue).fontWeight(.medium)
            Text("正式作答 \(max(0,card.reps)) 次")
            if let due = status.nextDue(for:card) {
                Text(due <= Date() ? "已到期" : "下次到期")
                Text(due,format:.dateTime.year().month().day().hour().minute())
            } else {
                Text(status == .suspended ? "排程已暂停" : "等待首次学习")
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private func startPractice() {
        guard !blocked,let result else { return }
        let key = loadKey
        do {
            let value = try store.db.cardEntryPracticeSession(ids:Array(selected),allowedIDs:Array(visibleIDs),query:key.query,page:result.page,generation:generation)
            guard key == loadKey,active else { throw CardEntryPracticeError.selectionChanged }
            try store.validateCardEntryPractice(value)
            practice = value;error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func jump() { page = min(max(1,Int(pageInput) ?? page),result?.pageCount ?? 1);pageInput = String(page) }
    private func apply(_ change: CardEntryBatchChange) {
        do {
            try store.changeCardEntryHistory(ids:Array(selected.intersection(visibleIDs)),allowedIDs:Array(visibleIDs),query:query,generation:generation,change:change)
            selected = [];error = nil;message = "已更新所选卡片，可撤销最近一次操作。"
        } catch { self.error = error.localizedDescription }
    }
    private func load() async {
        guard active else { loading = false; return }
        loading = true
        let key = loadKey,db = store.db
        do {
            let value = try await Task.detached(priority:.userInitiated) { try db.cardEntryHistoryPage(query:key.query,page:key.page) }.value
            try Task.checkCancellation()
            guard active,loadKey == key else { return }
            result = value;page = value.page;pageInput = String(value.page);selected.formIntersection(Set(value.items.map(\.id)))
            loadedKey = .init(query:key.query,page:value.page,revision:key.revision,generation:key.generation)
            loading = false;error = nil
        } catch is CancellationError { }
        catch { loading = false;self.error = error.localizedDescription }
    }
}

struct CardEntryHistoryPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    var insideEditor: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented:Binding(get:{ store.cardEntryHistory.isPresented && (store.cardEditor != nil) == insideEditor },set:{ if !$0 { store.cardEntryHistory.isPresented = false } }),onDismiss:{ store.performPendingCardEntryHistoryEdit() }) {
            CardEntryHistoryView(generation:store.cardEntryHistory.generation)
        }
    }
}
