import SwiftUI
import KongReviewCore

struct CardComparisonView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let incoming: Card
    let existing: Card
    var draftID: UUID? = nil
    var appendReview = false
    @State private var showsTextDifference = true
    @State private var choosingAppend = false
    @State private var appendPrepared = false
    @State private var incomingTemplate: NoteTemplate?
    @State private var existingTemplate: NoteTemplate?
    @State private var selectedSources: Set<CardAppendLocation> = []
    @State private var target: CardAppendLocation?
    @State private var error: String?

    private var sources: [CardAppendContentBlock] {
        CardAnswerAppendComposer.sources(for:incoming,template:incomingTemplate)
    }
    private var destinations: [CardAppendContentBlock] {
        CardAnswerAppendComposer.destinations(for:existing,template:existingTemplate)
    }
    private var previewResult: Result<CardAnswerAppendPreview, Error> {
        Result {
            guard let target else { throw CardComparisonError.noAnswerField }
            return try CardAnswerAppendComposer.preview(from:incoming,to:existing,
                incomingTemplate:incomingTemplate,existingTemplate:existingTemplate,
                selection:.init(sourceIDs:selectedSources,target:target))
        }
    }
    private var validPreview: CardAnswerAppendPreview? { try? previewResult.get() }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(choosingAppend ? "选择追加内容与位置" : (draftID == nil ? "修改前后对照" : "重复卡片对照")).font(.title2.bold())
            if choosingAppend { appendComposer }
            else {
                Toggle("标出文字差异（绿色新增、红色删除、橙色改动）",isOn:$showsTextDifference).toggleStyle(.checkbox)
                Text("按段落比较正文文字；排版和媒体变化请关闭此选项查看原排版。").font(.caption).foregroundStyle(.secondary)
                HStack(alignment:.top,spacing:16) {
                    pane(incoming,title:"当前输入")
                    Divider()
                    pane(existing,title:draftID == nil ? "上次保存" : "已有卡片")
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(choosingAppend ? "只追加所选内容；原卡正面、牌组、标签、关联和学习进度保持原样。" : "正面、背面及出处分别对照；当前输入尚未保存。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if choosingAppend { Button("返回对照") { choosingAppend = false; error = nil } }
                Button("关闭") { dismiss() }
                if draftID != nil, existing.deletedAt == nil {
                    if choosingAppend {
                        Button("确认追加并保存") { append() }.buttonStyle(.borderedProminent)
                            .disabled(store.fullBackupBusy || validPreview == nil)
                            .accessibilityIdentifier("card-append-confirm")
                    } else {
                        Button("选择内容并追加…") { prepareAppend(); choosingAppend = true }
                            .disabled(store.fullBackupBusy)
                    }
                }
            }
        }.padding(20).frame(minWidth:720,minHeight:620)
        .onAppear {
            if appendReview { prepareAppend(); choosingAppend = true }
        }
    }

    private var appendComposer: some View {
        HStack(alignment:.top,spacing:16) {
            VStack(alignment:.leading,spacing:12) {
                GroupBox {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text("1. 选择要追加的内容").font(.headline)
                            Spacer()
                            Button("全选") { selectedSources = Set(sources.map(\.id)); error = nil }.buttonStyle(.link)
                            Button("清空") { selectedSources = []; error = nil }.buttonStyle(.link)
                        }
                        if sources.isEmpty { Text("当前输入没有可追加的独立答案内容。").foregroundStyle(.secondary) }
                        ScrollView {
                            VStack(alignment:.leading,spacing:12) {
                                ForEach(sources) { block in
                                    Toggle(isOn:Binding(get:{ selectedSources.contains(block.id) },set:{ selected in
                                        if selected { selectedSources.insert(block.id) } else { selectedSources.remove(block.id) }
                                        error = nil
                                    })) {
                                        VStack(alignment:.leading,spacing:3) {
                                            Text(block.title).font(.body.bold())
                                            Text(Markdown.plainText(fromHTML:block.content).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "图片或音视频内容" : Markdown.plainText(fromHTML:block.content))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.frame(minHeight:100,maxHeight:240)
                    }.padding(6)
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:10) {
                        Text("2. 选择追加位置").font(.headline)
                        if destinations.isEmpty { Text("原卡没有独立背面字段，请编辑原卡补充。").foregroundStyle(.red) }
                        else {
                            Picker("追加到",selection:$target) {
                                ForEach(destinations) { block in Text(block.title).tag(Optional(block.id)) }
                            }.pickerStyle(.menu)
                            Text("原有内容保留，所选内容按上面的顺序加在末尾。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6).frame(maxWidth:.infinity,alignment:.leading)
                }
                Text("模板卡片只提供独立背面字段，正面字段不参与追加。成功后关闭当前草稿。").font(.caption).foregroundStyle(.secondary)
                if case .failure(let validationError) = previewResult {
                    Label(validationError.localizedDescription,systemImage:"exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("card-append-validation")
                }
                Spacer(minLength:0)
            }.frame(width:260)
            Divider()
            VStack(alignment:.leading,spacing:10) {
                Text("3. 最终卡片预览").font(.headline)
                if let preview = validPreview {
                    let faces = preview.result.faces(using:existingTemplate)
                    CardWebView(front:faces.front,back:faces.back,store:store)
                } else {
                    Text("选择有效内容和追加位置后，在这里查看将保存的完整卡片。")
                        .foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.frame(minHeight:440)
    }

    private func prepareAppend() {
        guard !appendPrepared else { return }
        do {
            let templates = try store.db.noteTemplates()
            incomingTemplate = incoming.noteType.flatMap { templates[$0] }
            existingTemplate = existing.noteType.flatMap { templates[$0] }
            selectedSources = Set(sources.map(\.id))
            target = destinations.first?.id
            appendPrepared = true
        } catch { self.error = error.localizedDescription }
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
            let preview = try previewResult.get()
            let saved = try store.db.appendCardAnswer(preview)
            if store.study.current?.id == saved.id { store.study.current = saved }
            store.cardWorkflow.duplicateReturn = nil
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
