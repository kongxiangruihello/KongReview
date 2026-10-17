import SwiftUI
import AppKit
import KongReviewCore

/// 启动页：分开呈现今日回顾与记忆卡的进度，再引导到各自的学习入口。
struct HomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.learningActivitySummary.recentDays.isEmpty && store.derivedIsLoading {
                    ProgressView("正在读取学习统计…").frame(maxWidth: .infinity, minHeight: 280)
                } else if store.learningActivitySummary.recentDays.isEmpty, let error = store.derivedStatisticsError {
                    VStack(spacing: 16) {
                        Text(error).foregroundStyle(.secondary)
                        Button("重新读取") { store.refreshDerived() }
                    }.frame(maxWidth: .infinity, minHeight: 280)
                } else {
                HomeLearningHeader(summary: store.homeLearningSummary, day: store.today)

                DraftRecoveryBanner(highlights: store.savedHighlightDrafts, cards: store.savedCardDrafts,
                                    onOpen: { store.showsDraftRecovery = true })

                HomeLearningDashboard(summary: store.homeLearningSummary,
                                      quote: store.dailyReviewQuote(),
                                      onReview: { store.openTodayReview() },
                                      onCards: { store.openCardsHome() })
                }
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 40)
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
