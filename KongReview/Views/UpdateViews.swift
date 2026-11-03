import SwiftUI
import KongReviewCore

// MARK: - 6.0.2：点一下就更新——面板与首页提示

/// 检查更新、改动说明、一步步的更新进度
struct UpdatePanel: View {
    @Bindable var updater = AppUpdater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(ReviewPalette.accent)
                Text(title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                Spacer()
            }
            Text("当前：" + updater.currentVersionText)
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
            if let p = updater.progress {
                ProgressSteps(progress: p)
            } else {
                content
            }
            HStack(spacing: 10) { buttons }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var icon: String {
        if updater.welcome != nil { return "checkmark.seal" }
        if updater.progress?.failure != nil { return "exclamationmark.triangle" }
        return "arrow.triangle.2.circlepath.circle"
    }

    private var title: String {
        if let w = updater.welcome { return "已从 \(w.from) 更新到 \(AppUpdater.version)" }
        if let p = updater.progress { return p.failure != nil ? "更新没有完成" : p.title }
        switch updater.phase {
        case .idle, .checking: return "检查更新"
        case .upToDate: return "已是最新版本"
        case .available: return updater.remoteVersion.map { "可以更新到 \($0)" } ?? "GitHub 上有新的改动"
        case .updating: return "正在更新"
        case .failed: return "没有完成"
        }
    }

    @ViewBuilder private var content: some View {
        if let w = updater.welcome {
            if w.notes.isEmpty {
                Text("新版本已经装好。").font(.system(size: 13))
            } else {
                NotesView(sections: w.notes)
            }
        } else {
            switch updater.phase {
            case .idle:
                Text("点“检查更新”，看看 GitHub 上有没有新版本。").font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            case .checking(let step):
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(step).font(.system(size: 13)) }
            case .upToDate:
                Label("已是最新：GitHub 上 main 分支没有比这一版新的代码。", systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.done)
            case .available:
                VStack(alignment: .leading, spacing: 10) {
                    Text("点“立即更新”后，应用会取下 GitHub 上的新代码，跑完全部测试再编译（约几分钟，可以照常使用）；测试不通过就停下，当前版本不动。装之前先备份学习库，旧版本留作回退。完成后 KongReview 自动重新打开。")
                        .font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !updater.notes.isEmpty {
                        NotesView(sections: updater.notes)
                    } else if !updater.pending.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("新的改动").font(.system(size: 12, weight: .medium)).foregroundStyle(ReviewPalette.sub)
                            ForEach(updater.pending.prefix(12), id: \.self) { s in
                                Text("· " + s).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                            }
                        }
                    }
                }
            case .updating:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在更新…").font(.system(size: 13)) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(ReviewPalette.pending)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if updater.welcome != nil {
            Spacer()
            Button("好") { updater.welcome = nil; dismiss() }.keyboardShortcut(.defaultAction)
        } else if let p = updater.progress {
            if p.failure != nil {
                Button("查看构建日志") { AppUpdaterLinks.openBuildLog() }
                Spacer()
                Button("关闭") { updater.dismissProgress(); dismiss() }
                Button("重试") { updater.dismissProgress(); updater.update() }.keyboardShortcut(.defaultAction)
            } else if p.finished {
                Spacer()
                Text("马上重新打开…").font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
            } else {
                Spacer()
                Button("在后台继续") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        } else {
            switch updater.phase {
            case .available:
                Spacer()
                Button("以后再说") { dismiss() }
                Button("立即更新") { updater.update() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("查看更新日志") { NSWorkspace.shared.open(AppUpdater.logURL) }
                Spacer()
                Button("关闭") { dismiss() }
                Button("重试") { updater.check(manual: true) }.keyboardShortcut(.defaultAction)
            case .checking:
                Spacer()
                Button("关闭") { dismiss() }
            case .idle, .upToDate, .updating:
                Spacer()
                Button("关闭") { dismiss() }
                Button("检查更新") { updater.check(manual: true) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

enum AppUpdaterLinks {
    static func openBuildLog() {
        let build = AppUpdater.buildLogURL
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: build.path) ? build : AppUpdater.logURL)
    }
}

/// 进度条、各步（✓ ● ○ ✕）、此刻在做什么、用时；失败时说明原因与“当前版本没有改动”
struct ProgressSteps: View {
    let progress: AppUpdater.Progress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if progress.failure == nil {
                    HStack(spacing: 8) {
                        ProgressView(value: progress.fraction)
                        Text("\(Int((progress.fraction * 100).rounded()))%")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub).frame(width: 40, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(progress.steps, id: \.self) { step in
                        HStack(spacing: 8) {
                            Text(mark(step)).font(.system(size: 13, weight: .bold)).foregroundStyle(color(step)).frame(width: 16)
                            Text(step.title).font(.system(size: 13))
                                .foregroundStyle(state(step) == .later ? ReviewPalette.sub : ReviewPalette.ink)
                        }
                    }
                }
                if let failure = progress.failure {
                    Text("⚠︎ " + failure).font(.system(size: 12.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Text(progress.detail).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(2)
                    Text(progress.finished ? "更新成功。KongReview 会自动退出并重新打开，不用做什么。"
                         : "通常要几分钟。可以关掉这个窗口照常使用，更新在后台继续；完成后 KongReview 自动重新打开。")
                        .font(.system(size: 12)).foregroundStyle(progress.finished ? ReviewPalette.done : ReviewPalette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let elapsed = Int(context.date.timeIntervalSince(progress.started))
                Text((progress.failure != nil || progress.finished ? "用时 " : "已用 ") + String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private enum StepState { case done, now, later }

    private func state(_ step: AppUpdater.Step) -> StepState {
        if step.rawValue < progress.current.rawValue || (progress.finished && step.rawValue <= progress.current.rawValue) { return .done }
        return step == progress.current ? .now : .later
    }

    private func mark(_ step: AppUpdater.Step) -> String {
        switch state(step) {
        case .done: "✓"
        case .now: progress.failure != nil ? "✕" : "●"
        case .later: "○"
        }
    }

    private func color(_ step: AppUpdater.Step) -> Color {
        switch state(step) {
        case .done: ReviewPalette.done
        case .now: progress.failure != nil ? .red : ReviewPalette.accent
        case .later: ReviewPalette.sub
        }
    }
}

/// README 里的版本说明
private struct NotesView: View {
    let sections: [ReleaseNotes.Section]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections, id: \.version) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(s.version) \(s.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.ink)
                        Text(Self.markdown(s.body)).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .padding(10)
        .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 首页顶部：有更新或正在更新时显示一行
struct UpdateHomeBanner: View {
    var updater = AppUpdater.shared

    var body: some View {
        if let line = text {
            Button { updater.showsPanel = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(ReviewPalette.accent)
                    Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(ReviewPalette.ink)
                    if let p = updater.progress, p.failure == nil {
                        ProgressView(value: p.fraction).frame(width: 120)
                    }
                    Spacer()
                    Text(updater.progress == nil ? "更新" : "查看").font(.system(size: 12, weight: .semibold)).foregroundStyle(ReviewPalette.accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(ReviewPalette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    private var text: String? {
        if let p = updater.progress {
            return p.failure != nil ? "更新没有完成，当前版本没有改动" : "正在更新 · " + p.detail
        }
        guard updater.phase == .available else { return nil }
        return updater.remoteVersion.map { "KongReview \($0) 可以更新了，点一下即可" } ?? "GitHub 上有新的改动，点一下即可更新"
    }
}
