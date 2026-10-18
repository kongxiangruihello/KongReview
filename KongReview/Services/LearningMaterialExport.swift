import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongReviewCore
struct LearningMaterialExportRequest: Identifiable {
    let id = UUID()
    let scope: LearningMaterialScope
}
@MainActor enum LearningMaterialExport {
    static func saveSummary(window: GrowthWindow, summary: GrowthSummary, reflection: GrowthReflection, store: LibraryStore) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "\(window.period.title)学习小结.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "# \(window.period.title)学习小结\n\n\(window.start.formatted()) — \(window.end.formatted())\n\n" + GrowthMetric.allCases.map { "- \($0.title)：\(summary[$0])" }.joined(separator:"\n") + "\n\n## 目标\n\n摘录 \(reflection.goalHighlights) 条；记忆卡 \(reflection.goalCards) 张\n\n## 收获\n\n\(reflection.gains)\n\n## 困难\n\n\(reflection.challenges)\n\n## 下一步\n\n\(reflection.nextSteps)"
        let generation = store.growthGeneration
        Task { @MainActor in
            do {
                var plans: [LearningPlan] = [], offset = 0
                while true {
                    let batch = try await store.db.learningPlans(completed:true,start:window.start,end:window.end,offset:offset)
                    guard generation == store.growthGeneration, !store.fullBackupBusy else { return }
                    plans.append(contentsOf:batch.items); offset += batch.items.count
                    if batch.items.isEmpty || offset >= batch.total { break }
                }
                var guide = ""
                if window.period == .month || window.period == .year {
                    let facts = try await store.db.periodReviewFacts(window:window)
                    guard generation == store.growthGeneration, !store.fullBackupBusy else { return }
                    guide = "\n\n## 复盘参考\n\n完成 \(facts.completed) 项计划，留下 \(facts.outcomes) 项成果，解决 \(facts.solvedQuestions) 个专题问题。\n\n- 哪些理解加深了？\n- 哪些问题仍未解决？\n- 下一阶段关注什么？"
                }
                let outcomes = plans.map { plan in
                    "### " + plan.title + "\n\n" + (plan.outcome?.gains ?? "") + (plan.outcome?.evidence.map { "\n\n关联成果：" + $0.title } ?? "")
                }.joined(separator:"\n\n")
                try (text + guide + "\n\n## 完成的计划与收获\n\n" + outcomes).write(to:url,atomically:true,encoding:.utf8)
            } catch { store.report(error) }
        }
    }
}
struct LearningMaterialExportPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get:{store.learningMaterialExport},set:{store.learningMaterialExport=$0})) { request in
            LearningMaterialExportView(initialScope:request.scope)
        }
    }
}
struct LearningMaterialExportView: View {
    @Environment(LibraryStore.self) private var store
    var initialScope: LearningMaterialScope? = nil
    @State private var scope: LearningMaterialScope?
    @State private var options = LearningMaterialOptions()
    @State private var pdf = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("导出学习资料").font(.title2.bold())
            Picker("专题或出处",selection:$scope) {
                Text("请选择").tag(Optional<LearningMaterialScope>.none)
                ForEach(store.notebooks) { n in if let id=n.id { Text("专题 · "+n.title).tag(Optional(LearningMaterialScope.notebook(id))) } }
                ForEach(store.sources) { s in if let id=s.id { Text("出处 · "+s.title).tag(Optional(LearningMaterialScope.source(id))) } }
            }
            Toggle("摘录原文与译文",isOn:$options.text)
            Toggle("摘录按语与专题笔记",isOn:$options.notes)
            Toggle("关联记忆卡问答",isOn:$options.cards)
            Toggle("引文出处",isOn:$options.citations)
            Picker("格式",selection:$pdf) { Text("Markdown").tag(false); Text("PDF（打印讲义）").tag(true) }.pickerStyle(.segmented)
            Text("仅导出当前范围内未删除的摘录及关联卡片。按文字排版；图片、音频和附件请使用完整备份保存。").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if initialScope != nil { Button("关闭") { store.learningMaterialExport=nil }.disabled(busy) }
                Button("选择保存位置并导出…") { export() }.disabled(scope == nil || busy || !(options.text || options.notes || options.cards || options.citations))
            }
        }.padding(24).frame(minWidth:560).disabled(busy).interactiveDismissDisabled(busy)
            .onAppear { if scope == nil { scope=initialScope } }
    }
    private func export() {
        guard let scope else { return }
        let panel=NSSavePanel(); panel.allowedContentTypes=pdf ? [.pdf] : [UTType(filenameExtension:"md") ?? .plainText]
        panel.nameFieldStringValue="学习资料."+(pdf ? "pdf":"md")
        guard panel.runModal() == .OK, let url=panel.url else { return }
        busy=true; message=nil
        let options=options, wantsPDF=pdf
        Task { @MainActor in
            do {
                let material=try await store.db.learningMaterial(scope:scope)
                let markdown=material.markdown(options:options)
                if wantsPDF {
                    // 转义为纯文字HTML，导出不执行资料中的脚本或加载远程媒体。
                    let html=material.printHTML(options:options)
                    PDFExporter.export(html:html,title:material.title,to:url) { error in
                        busy=false; message=error.map { "导出失败："+$0.localizedDescription } ?? "PDF 已保存。"
                    }
                } else {
                    try markdown.write(to:url,atomically:true,encoding:.utf8)
                    busy=false; message="Markdown 已保存。"
                }
            } catch { busy=false; message="导出失败："+error.localizedDescription }
        }
    }
}
