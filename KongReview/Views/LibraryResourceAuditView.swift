import SwiftUI
import KongReviewCore

struct LibraryResourceAuditView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var jump = "1"
    @State private var inspection: AuditIssue?
    private var audit: LibraryResourceAuditState { store.resourceAudit }
    static let kinds = [("","全部资料"),("highlight","摘录"),("card","记忆卡"),("article","网页"),("notebook_block","专题文字"),("source","出处"),("app_progress","个人成长")]
    var body: some View {
        @Bindable var audit = audit
        VStack(alignment:.leading,spacing:12) {
            Text("全库资料检查").font(.title2.bold())
            Text("检查正式摘录、卡片及模板字段、网页、专题文字、出处网址和成长记录。只核对链接写法与本地媒体；远程资源不联网测试，草稿／历史／最近删除不在本次范围。").font(.caption).foregroundStyle(.secondary)
            HStack {
                if audit.running { ProgressView().controlSize(.small); Button("暂停") { audit.pause() } }
                else if audit.finished { Label("扫描完成",systemImage:"checkmark.circle").foregroundStyle(.green) }
                else { Button(audit.startedAt == nil ? "开始检查" : "继续检查") { audit.start(db:store.db) }.buttonStyle(.borderedProminent) }
                Button("重新检查") { audit.reset(); audit.start(db:store.db) }.disabled(audit.running)
                Spacer(); Text("已检查 \(audit.examined)／\(audit.expected) 条目").monospacedDigit()
            }
            if audit.running && audit.expected>0 { ProgressView(value:Double(min(audit.examined,audit.expected)),total:Double(audit.expected)) }
            if let date = audit.startedAt { Text("开始于 \(date.formatted(date:.abbreviated,time:.shortened))；扫描期间修改过资料，处理后请重新检查。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Picker("范围",selection:$audit.kind) { ForEach(Self.kinds,id:\.0) { Text($0.1).tag($0.0) } }.frame(width:180)
                TextField("搜索条目、地址或问题",text:$audit.query)
                Text("\(audit.total) 项问题").font(.caption).monospacedDigit()
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(audit.items) { issue in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(Self.kinds.first { $0.0 == issue.kind }?.1 ?? "资料").font(.caption).foregroundStyle(.secondary); Text(issue.field).font(.caption); Spacer(); Button("查看并处理…") { inspection = issue }.controlSize(.small) }
                            Text(issue.title.isEmpty ? "（无标题）" : issue.title).font(.headline).lineLimit(2)
                            Label(issue.message,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                            Text(issue.value).font(.system(.caption,design:.monospaced)).lineLimit(3).textSelection(.enabled)
                        }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    }
                    if audit.items.isEmpty { Text(audit.startedAt == nil ? "开始检查后，问题会分页列在这里。" : (audit.running ? "正在检查，当前尚无符合条件的问题。" : "当前条件没有发现需核对的问题。")).foregroundStyle(.secondary).padding() }
                }
            }
            HStack {
                Button("上一页") { audit.page -= 1; audit.refreshPage() }.disabled(audit.page == 0)
                Text("第 \(audit.page+1)／\(audit.pageCount) 页 · 每页50项").font(.caption).monospacedDigit()
                Button("下一页") { audit.page += 1; audit.refreshPage() }.disabled(audit.page+1>=audit.pageCount)
                TextField("页码",text:$jump).frame(width:48).onSubmit(jumpPage)
                Button("跳转",action:jumpPage)
                Spacer(); Button("关闭") { dismiss() }
            }
            if let error = audit.error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(minWidth:680,minHeight:540)
        .onChange(of:audit.kind) { _,_ in audit.page = 0; audit.refreshPage() }
        .onChange(of:audit.query) { _,_ in audit.page = 0; audit.refreshPage() }
        .onChange(of:audit.page) { _,value in jump = String(value+1) }
        .onChange(of:store.growthGeneration) { _,_ in audit.reset() }
        .onDisappear { audit.pause() }
        .sheet(item:$inspection) { issue in AuditIssueInspectionView(issue:issue) { open(issue) } }
    }
    private func jumpPage() { guard let value = Int(jump) else { return }; audit.page = min(max(0,value-1),audit.pageCount-1); audit.refreshPage() }
    private func open(_ issue: AuditIssue) {
        inspection = nil; dismiss()
        let generation = store.growthGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            guard !store.fullBackupBusy,store.growthGeneration == generation else { return }
            switch issue.kind {
            case "highlight","card","article":
                guard let kind = GlobalSearchKind(rawValue:issue.kind) else { return }
                store.openGlobalSearchResult(.init(kind:kind,recordID:issue.recordID))
            case "source":
                Task { @MainActor in
                    do { if case .source(let source) = try await store.db.resolveGlobalSearchTarget(.init(kind:.source,recordID:issue.recordID)) { store.editingSource = source } }
                    catch { store.report(error) }
                }
            case "notebook_block": if let parent = issue.parentID { store.selection = .notebook(parent) }
            case "app_progress":
                store.selection = .growth
                if issue.key.hasPrefix("growth."),let reflection = try? store.db.progressValue(GrowthReflection.self,key:issue.key),let entry = GrowthHistoryEntry.parse(key:issue.key,reflection:reflection) {
                    store.journeyNavigation.tab = 0; store.journeyNavigation.period = entry.period; store.journeyNavigation.date = entry.date
                } else if issue.key.hasPrefix("topic-question.") { store.journeyNavigation.tab = 1; store.journeyNavigation.selectedNotebookID = issue.parentID; store.journeyNavigation.showTopicQuestions = true }
                else if issue.key.hasPrefix("weekly-schedule.") { store.journeyNavigation.tab = 8 }
                else if issue.key.hasPrefix("difficult-care.") { store.journeyNavigation.tab = 6 }
                else { store.journeyNavigation.tab = 5 }
            default: break
            }
        }
    }
}

struct AuditIssueInspectionView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let issue: AuditIssue
    let open: () -> Void
    @State private var field: AuditField?
    @State private var notice = "正在读取当前内容…"
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("核对资料问题").font(.title2.bold()); Text(issue.title).font(.headline); Text(issue.field).font(.caption)
            Text(notice).foregroundStyle(.secondary)
            Text(issue.value).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            if let field { ScrollView { Text(Markdown.plainText(fromHTML:field.text)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) } }
            Text("打开条目后，可在对应字段的“检查链接与媒体”中定位地址或替换媒体。专题／成长记录会打开所属页面。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("返回清单") { dismiss() }; Button("打开条目处理") { open() }.disabled(field == nil).buttonStyle(.borderedProminent) }
        }.padding(20).frame(minWidth:580,minHeight:360)
        .task {
            do {
                let scope = AuditScope(kind:issue.kind,maximum:issue.recordID,total:1,cursor:issue.recordID-1)
                let docs = try await store.db.resourceAuditBatch(scope,limit:1)
                field = docs.first?.fields.first { $0.name == issue.field }
                if let field {
                    let media = try await store.db.editorMediaNames()
                    let refs = EditorResourceCheck.references(HTMLSourceCodec.editable(field.text)) { media.contains($0) }
                    notice = refs.contains { $0.problem && $0.value == issue.value } ? "当前内容仍有这个问题。" : "这个问题已变化或已修复；下方显示最新内容，请重新检查清单。"
                } else { notice = "原条目或字段已删除，请重新检查清单。" }
            } catch { notice = "读取失败："+error.localizedDescription }
        }
    }
}
