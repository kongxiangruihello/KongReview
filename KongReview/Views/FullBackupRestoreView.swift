import SwiftUI

struct FullBackupRestoreView: View {
    let prepared: PreparedFullBackup
    let onCancel: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("恢复完整备份", systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text(prepared.source.lastPathComponent).font(.headline).lineLimit(2)
            Text("备份于 \(prepared.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)) · KongReview \(prepared.manifest.appVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow { count("摘录", prepared.counts.highlights); count("记忆卡", prepared.counts.cards) }
                GridRow { count("出处", prepared.counts.sources); count("网页存档", prepared.counts.articles) }
                GridRow { count("学习与回顾记录", prepared.counts.reviewEvents); count("图片／音频等资源", prepared.counts.media) }
                GridRow { count("摘录草稿", prepared.counts.highlightDrafts); count("记忆卡草稿", prepared.counts.cardDrafts) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Label("文件校验和、数据库结构与完整性、草稿及设置均已校验。", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            Text("恢复会替换当前数据库、编辑草稿和学习设置，包括今日回顾进度。已保存到应用的图片、音频、封面、网页缓存、个人成长复盘和扫描进度随数据库恢复。恢复前会先保存一份完整备份；若恢复失败，会自动回滚。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("外部同步文件夹、收件箱、尚未存档的远程资源及系统权限不随备份迁移。旧的自动数据库备份保持保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("恢复这份备份…", role: .destructive) { prepared.confirmsRestore = true }
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog("用这份完整备份替换当前资料？", isPresented: Binding(
            get: { prepared.confirmsRestore }, set: { prepared.confirmsRestore = $0 }
        ), titleVisibility: .visible) {
            Button("保存当前完整备份并恢复", role: .destructive, action: onRestore)
            Button("取消", role: .cancel) { prepared.confirmsRestore = false }
        } message: {
            Text("当前数据库、草稿和学习设置会被替换。恢复前会保留一份完整安全备份。")
        }
    }

    private func count(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value.formatted()).monospacedDigit().bold()
        }.font(.callout)
    }
}
