import SwiftUI
import AppKit
import KongReviewCore

/// 启动页：分开呈现今日回顾与记忆卡的进度，再引导到各自的学习入口。
struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(SidebarLayout.showResearchKey) private var showResearch = true
    /// 5.0.3：去年今日（空时不放卡片）
    @State private var onThisDay: [OnThisDayItem] = []

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
                Button("查看个人成长 · 日／周／月／年小结") { store.selection = .growth }.handCursor()
                HomeLearningHeader(summary: store.homeLearningSummary, day: store.today)
                SidebarRegroupNotice()

                DraftRecoveryBanner(highlights: store.savedHighlightDrafts, cards: store.savedCardDrafts,
                                    onOpen: { store.showsDraftRecovery = true })

                // 5.2.1：有新版本时提示一行
                UpdateHomeBanner()

                TodayWorkBar(summary: store.homeLearningSummary, revisit: store.revisitCounts, gains: store.todayGains, focus: nil,
                             check: store.dailyCheck, checkedIn: store.checkin.todayChecked,
                             onStart: { store.startTodayWork() },
                             onCheck: { store.openDailyCheck() },
                             onFocus: { store.selection = store.currentProjectID.map(SidebarItem.project) ?? .projects })

                // 5.0.1：本周复盘——未做时“去复盘”，做过显示写下的三句话
                // 5.2.2：连续打卡中断时记一句原因
                StreakBreakPrompt()

                ReflectionHomeCard()

                // 5.0.2：本周进展——记下的小胜与本周自测
                ProgressHomeCard()

                // 5.0.3：常念的问题（前三个）、去年今日
                PinnedQuestionsHomeCard()
                if !onThisDay.isEmpty { OnThisDayHomeCard(items: onThisDay) }

                HomeLearningDashboard(summary: store.homeLearningSummary,
                                      quote: store.dailyReviewQuote(),
                                      onReview: { store.openTodayReview() },
                                      onCards: { store.openCardsHome() })
                }
                DailyArrangementView().id("\(store.today)|\(store.growthGeneration)")
                HomeTodayPlans().id(store.growthGeneration)
                // 4.0：当前项目——5.0.3 起放在最下方；隐藏“研究与写作”组时一并隐藏
                if showResearch { CurrentProjectCard() }
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("首页")
        .task(id: "\(store.today)|\(store.revision)|\(store.ideaNoteRevision)|\(store.questionRevision)") {
            onThisDay = (try? store.db.onThisDay()) ?? []
        }
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
