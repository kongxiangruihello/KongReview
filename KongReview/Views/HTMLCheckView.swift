import SwiftUI
import KongReviewCore

struct HTMLCheckView: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    let original: String
    let storedOriginal: String
    @State private var error: String?
    var body: some View {
        let check = HTMLDiagnostics.inspect(original)
        VStack(alignment:.leading,spacing:12) {
            Text("HTML 检查与修正预览").font(.title2.bold())
            Text("检查常见的标签、引号和链接写法；复杂模板和 HTML 可选闭合语法请人工核对。不会自动修改原文。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    if check.issues.isEmpty { Label("未发现常见写法问题",systemImage:"checkmark.circle").foregroundStyle(.green) }
                    ForEach(Array(check.issues.enumerated()),id:\.offset) { _, issue in Text(issue).foregroundStyle(.red) }
                    if check.proposed != original {
                        Text("建议修改后的源码").font(.headline)
                        Text(check.proposed).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        Text("文字预览").font(.headline)
                        // Attributed preview does not execute user scripts or load remote resources.
                        Text(RichText.attributed(check.proposed)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("返回手动编辑") { dismiss() }
                Button("采用此修正") {
                    guard text == storedOriginal else { error = "原文已变化，请重新检查。"; return }
                    text = check.proposed; dismiss()
                }.disabled(check.proposed == original)
            }
        }.padding(20).frame(minWidth:600,minHeight:420)
    }
}
