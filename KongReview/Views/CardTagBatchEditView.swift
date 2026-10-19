import SwiftUI

struct CardTagBatchEditView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let request = store.study.cardTagEdit
        return VStack(alignment: .leading, spacing: 16) {
            Text(request?.mode.title ?? "批量修改标签").font(.title2.bold())
            Text("牌组「\(request?.deck ?? "")」· 本页选中的 \(request?.cardIDs.count ?? 0) 张卡片")
                .font(.callout).foregroundStyle(.secondary)
            TextField("输入标签，用空格或逗号分隔", text: Binding(
                get: { store.study.cardTagEdit?.text ?? "" },
                set: { store.study.cardTagEdit?.text = $0 }
            )).textFieldStyle(.roundedBorder).onSubmit { store.applyCardTagEdit() }
                .disabled(request?.processing == true)
            Text(request?.mode == .remove ? "只移除名称完全相同的标签，其他标签和学习进度保留。" : "已有标签保留，相同标签只添加一次，学习进度保留。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = request?.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if request?.processing == true { ProgressView().controlSize(.small) }
                Text("完成后可用 ⌘Z 撤销。" ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { store.study.cardTagEdit = nil }.keyboardShortcut(.cancelAction)
                    .disabled(request?.processing == true)
                Button("确认\(request?.mode == .remove ? "移除" : "添加")") { store.applyCardTagEdit() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(request?.processing == true)
            }
        }.padding(24).frame(width: 510)
            .interactiveDismissDisabled(request?.processing == true)
    }
}
