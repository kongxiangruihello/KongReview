import SwiftUI
import KongReviewCore

// MARK: - 5.2.1：在线更新面板与首页提示

/// 检查更新、下载进度、安装并重新打开
struct UpdatePanel: View {
    @Bindable var updater = AppUpdater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.system(size: 22)).foregroundStyle(ReviewPalette.accent)
                Text(title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
            }
            Text("当前版本 \(updater.currentVersionText)" + (updater.release.map { " · 最新版本 \($0.version.description)" } ?? ""))
                .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            content
            if let r = updater.release, updater.isNewer, !r.notes.isEmpty { notes(r) }
            HStack(spacing: 10) { buttons }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: "检查更新"
        case .upToDate: "已是最新版本"
        case .available: "有新版本"
        case .downloading: "正在下载新版本"
        case .verifying: "正在校验"
        case .ready: "新版本已下载好"
        case .installing: "正在安装"
        case .failed: "更新没有完成"
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在查询 GitHub 上的最新发布…").font(.system(size: 13)) }
        case .upToDate(let v):
            Label("KongReview \(v) 是最新版本。", systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(ReviewPalette.done)
        case .available:
            if let r = updater.release {
                Text("KongReview \(r.version.description)" + (r.publishedAt.map { "（\(Self.date($0)) 发布）" } ?? "") + " · 安装包 \(UpdateProgressText.megabytes(r.dmgSize)) MB")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.ink)
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                if let p = updater.progress { ProgressView(value: p) } else { ProgressView() }
                HStack {
                    Text(updater.progressLine).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                    Spacer()
                    if let p = updater.progress {
                        Text("\(Int(p * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
                    }
                }
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: 1)
                Text("下载完成，正在核对文件大小与校验码…").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            }
        case .ready:
            Label("已下载并校验。安装时会先备份学习库，再退出、换上新版并重新打开（旧版留在缓存目录作后备）。",
                  systemImage: "checkmark.seal").font(.system(size: 13)).foregroundStyle(ReviewPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .installing(let step):
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(step).font(.system(size: 13)) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(ReviewPalette.pending)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notes(_ r: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本版改动").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            ScrollView {
                Text(Self.markdown(r.notes))
                    .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("跳过这个版本") { updater.skipThisVersion() }
            Spacer()
            Button("以后再说") { dismiss() }
            Button("下载并安装") { updater.download() }.keyboardShortcut(.defaultAction)
        case .downloading, .verifying:
            Spacer()
            Button("取消下载") { updater.cancelDownload() }
            Button("在后台下载") { dismiss() }
        case .ready:
            Button("打开安装包") { updater.revealDownloadedDMG() }
            Spacer()
            Button("以后再说") { dismiss() }
            Button("安装并重新打开") { updater.installAndRelaunch() }
                .keyboardShortcut(.defaultAction)
                .disabled(!updater.canInstall)
                .help(updater.canInstall ? "" : "预览版或开发构建不能就地更新")
        case .installing:
            Spacer()
        case .failed:
            Button("在网页上查看") { NSWorkspace.shared.open(updater.release?.pageURL ?? AppUpdater.releasesPage) }
            Spacer()
            Button("关闭") { dismiss() }
            Button("重试") { updater.release != nil && updater.isNewer ? updater.download() : updater.check(manual: true) }
                .keyboardShortcut(.defaultAction)
        case .idle, .checking, .upToDate:
            Spacer()
            Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        return f.string(from: d)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 首页顶部：有新版本、正在下载或已下载好时显示一行
struct UpdateHomeBanner: View {
    var updater = AppUpdater.shared

    var body: some View {
        if let line = text {
            Button { updater.showsPanel = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(ReviewPalette.accent)
                    Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    if updater.phase == .downloading, let p = updater.progress {
                        ProgressView(value: p).frame(width: 120)
                    }
                    Spacer()
                    Text("查看").font(.system(size: 12, weight: .semibold)).foregroundStyle(ReviewPalette.accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(ReviewPalette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    private var text: String? {
        guard let r = updater.release, updater.isNewer else { return nil }
        switch updater.phase {
        case .available: return "KongReview \(r.version.description) 可以更新了"
        case .downloading: return "正在下载 \(r.version.description) · " + updater.progressLine
        case .verifying: return "正在校验 \(r.version.description)"
        case .ready: return "\(r.version.description) 已下载好，可以安装"
        default: return nil
        }
    }
}
