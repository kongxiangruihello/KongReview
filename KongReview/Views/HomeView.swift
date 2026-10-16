import SwiftUI
import AppKit
import KongReviewCore

/// 启动页：日课概览与今日的两个入口。
struct HomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView {
            DailyReviewSummaryCard(title: store.todayReviewIsComplete ? "今日回顾完成" : "今日功课") {
                HomeActionsView()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("首页")
        .onAppear {
            store.checkDayChange()
            store.refreshDerived()
        }
        .task {
            // 学习中的卡片会在几分钟后到期；首页停留期间同步日期与队列。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                store.checkDayChange()
                store.refreshDerived()
            }
        }
    }
}

struct HomeActionsView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let _ = store.revision
        let _ = store.today
        let counts = store.todayCounts()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions(counts: counts) }
            VStack(spacing: 12) { actions(counts: counts) }
        }
    }

    @ViewBuilder
    private func actions(counts: (highlights: Int, cards: Int)) -> some View {
        PillButton(icon: "brain", title: "去学习记忆卡 · \(counts.cards)", style: counts.cards > 0 ? .primary : .normal) {
            store.openCardsHome()
        }
        .help("打开记忆卡首页，选择牌组后开始学习")
        PillButton(icon: "sun.max", title: "去今日回顾 · \(counts.highlights)", style: counts.cards == 0 && counts.highlights > 0 ? .primary : .normal) {
            store.openTodayReview()
        }
        .help(counts.highlights > 0 ? "继续今天的摘录回顾" : "查看今天的回顾统计")
    }
}

/// 使用应用包里的图标，兼容 Xcode 资源目录与 SwiftPM 的 DMG 打包。
struct SidebarBrandView: View {
    private static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: NSImage.Name("AppIcon")) ?? NSApplication.shared.applicationIconImage
    }()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    }

    var body: some View {
        VStack(spacing: 5) {
            Divider()
                .padding(.bottom, 8)
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityLabel("KongReview 标志")
            }
            Text("KongReview")
                .font(.system(size: 12, weight: .semibold))
            Text("开发者：孔祥瑞")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("版本 \(version)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background(.bar)
    }
}
