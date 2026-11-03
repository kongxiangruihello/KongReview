import SwiftUI
import AppKit
import KongReviewCore

/// 6.0.5：考场门口——今天的卷子、上次成绩、打卡。原首页的学习统计、今日一句、复盘卡片由成绩册代替。
struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @State private var last: GradebookDay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                DraftRecoveryBanner(highlights: store.savedHighlightDrafts, cards: store.savedCardDrafts,
                                    onOpen: { store.showsDraftRecovery = true })

                // 5.2.1：有新版本时提示一行
                UpdateHomeBanner()

                TodayWorkBar(summary: store.homeLearningSummary, revisit: store.revisitCounts,
                             annotate: DailyCheckCount(done: store.annotate.done, left: store.annotate.left),
                             capped: ExamSettings.minutes() > 0 ? store.dailyCheckCounts() : nil,
                             gains: store.todayGains, focus: nil,
                             check: store.dailyCheck, checkedIn: store.checkin.todayChecked,
                             onStart: { store.startTodayWork() },
                             onCheck: { store.openExam() },
                             onFocus: {})

                // 5.2.2：连续打卡中断时记一句原因
                StreakBreakPrompt()

                CheckinStatusStrip()

                lastScoreCard
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("考场门口")
        .onAppear {
            store.checkDayChange()
            store.refreshDerived()
        }
        .task(id: "\(store.today)|\(store.dailyCheckRevision)") { last = try? store.db.lastGradedDay() }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ExamDate.line())
                .font(.system(size: 12.5, weight: .medium)).tracking(0.8)
                .foregroundStyle(ReviewPalette.sub)
            Text("考场").font(.system(size: 32, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
            Text("每天来考一次：先作答、后对照、再判分；考完写一句日评就算打卡，错的题会再回到卷子上。")
                .font(.system(size: 13.5)).foregroundStyle(ReviewPalette.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 上次成绩

    @ViewBuilder private var lastScoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("上次成绩").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                if let last {
                    Text(GradebookFormat.day(last.day) + " " + GradebookFormat.weekday(last.day))
                        .font(.system(size: 12)).foregroundStyle(ReviewPalette.sub)
                }
                Spacer()
                Button("打开成绩册") { store.openGradebook() }.buttonStyle(.link).font(.system(size: 12.5)).handCursor()
            }
            if let last {
                HStack(alignment: .top, spacing: 10) {
                    figure("已做 / 应做", last.due > 0 || last.done > 0 ? "\(last.done) / \(last.due)" : "—")
                    figure("完成度", GradebookFormat.percent(last.score.completion))
                    figure("掌握度", GradebookFormat.percent(last.score.mastery.ratio))
                    figure("总分", last.score.total.map(String.init) ?? "—")
                    figure("打卡", last.checkin == nil ? "没打" : last.checkin == .makeup ? "补签" : "已打")
                }
                if !last.score.note.isEmpty {
                    Text("“\(last.score.note)”").font(.system(size: 13, design: .serif)).foregroundStyle(ReviewPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("最近 30 天还没有成绩。答完今天的卷子、写一句日评，这里就会出现。")
                    .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(ReviewPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
