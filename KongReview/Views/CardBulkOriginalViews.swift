import SwiftUI
import KongReviewCore

struct CardBulkOriginalRequest: Identifiable {
    var candidateID: UUID
    var incoming: Card
    var existing: Card
    var id: UUID { candidateID }
}

struct CardBulkOriginalPreview: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: CardBulkOriginalRequest
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("查看原卡").font(.title2.bold())
            Text("牌组：" + request.existing.deck + (request.existing.deletedAt == nil ? "" : " · 最近删除"))
                .font(.caption).foregroundStyle(.secondary)
            Text("这里是只读预览；批量候选和原卡均未修改。").font(.caption).foregroundStyle(.secondary)
            let faces = store.faces(of:request.existing)
            CardWebView(front:faces.front,back:faces.back,store:store)
            HStack { Spacer();Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth:720,minHeight:600)
    }
}

/// Separate from the single-card comparison sheet: it never closes or replaces the main editor.
struct CardBulkAppendView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: CardBulkOriginalRequest
    var onAppended: () -> Void
    @State private var incomingTemplate: NoteTemplate?
    @State private var existingTemplate: NoteTemplate?
    @State private var selectedSources: Set<CardAppendLocation> = []
    @State private var target: CardAppendLocation?
    @State private var prepared = false
    @State private var busy = false
    @State private var didAppend = false
    @State private var error: String?

    private var sources: [CardAppendContentBlock] { CardAnswerAppendComposer.sources(for:request.incoming,template:incomingTemplate) }
    private var destinations: [CardAppendContentBlock] { CardAnswerAppendComposer.destinations(for:request.existing,template:existingTemplate) }
    private var previewResult: Result<CardAnswerAppendPreview,Error> {
        Result {
            guard let target else { throw CardComparisonError.noAnswerField }
            return try CardAnswerAppendComposer.preview(from:request.incoming,to:request.existing,
                incomingTemplate:incomingTemplate,existingTemplate:existingTemplate,
                selection:.init(sourceIDs:selectedSources,target:target))
        }
    }
    private var validPreview: CardAnswerAppendPreview? { try? previewResult.get() }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("追加到已有卡片").font(.title2.bold())
            Text("只追加勾选的答案，原卡正面、牌组、标签和学习进度保留；确认后本条候选取消勾选，返回整批继续。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:12) {
                    Text("1. 选择要追加的内容").font(.headline)
                    HStack {
                        Button("全选") { selectedSources = Set(sources.map(\.id)) }
                        Button("清空") { selectedSources = [] }
                    }.controlSize(.small)
                    ScrollView {
                        VStack(alignment:.leading,spacing:10) {
                            ForEach(sources) { block in
                                Toggle(isOn:Binding(get:{ selectedSources.contains(block.id) },set:{ enabled in
                                    if enabled { selectedSources.insert(block.id) } else { selectedSources.remove(block.id) }
                                })) {
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(block.title).font(.body.bold())
                                        Text(Markdown.plainText(fromHTML:block.content).isEmpty ? "图片或音视频内容" : Markdown.plainText(fromHTML:block.content))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(minHeight:100,maxHeight:240)
                    if sources.isEmpty { Text("这条候选没有可追加的答案。").foregroundStyle(.red) }
                    Text("2. 选择追加位置").font(.headline)
                    Picker("追加到",selection:$target) {
                        ForEach(destinations) { block in Text(block.title).tag(Optional(block.id)) }
                    }
                    if destinations.isEmpty { Text("原卡没有独立背面字段，请编辑原卡补充。").font(.caption).foregroundStyle(.red) }
                    if prepared,case .failure(let validation) = previewResult {
                        Text(validation.localizedDescription).font(.caption).foregroundStyle(.red)
                    }
                    Spacer(minLength:0)
                }.frame(width:270)
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    Text("3. 保存后的完整卡片").font(.headline)
                    if let preview = validPreview {
                        let faces = preview.result.faces(using:existingTemplate)
                        CardWebView(front:faces.front,back:faces.back,store:store)
                    } else { Text("选择有效内容和位置后查看预览。").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Text("追加后可在整批窗口中撤销最近一次追加。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("返回整批") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认追加并保存") { append() }.buttonStyle(.borderedProminent)
                    .disabled(!prepared || validPreview == nil || store.fullBackupBusy || didAppend)
                    .accessibilityIdentifier("card-bulk-append-confirm")
            }
        }.padding(20).frame(minWidth:760,minHeight:640).disabled(busy)
            .interactiveDismissDisabled(busy)
            .onAppear { prepare() }
    }
    private func prepare() {
        guard !prepared else { return }
        do {
            let templates = try store.db.noteTemplates()
            incomingTemplate = request.incoming.noteType.flatMap { templates[$0] }
            existingTemplate = request.existing.noteType.flatMap { templates[$0] }
            selectedSources = Set(sources.map(\.id));target = destinations.first?.id;prepared = true
        } catch { self.error = error.localizedDescription }
    }
    private func append() {
        guard !busy,!didAppend,!store.fullBackupBusy else { return }
        busy = true
        defer { busy = false }
        do {
            guard store.cardEditor?.card.id != request.existing.id else {
                error = "原卡正在编辑，请先保存或关闭原卡，再追加答案。整批输入仍保留。";return
            }
            let preview = try previewResult.get()
            _ = try store.appendCardAnswerWithUndo(preview)
            didAppend = true;onAppended();store.reload();dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
