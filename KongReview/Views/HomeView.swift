import SwiftUI
import AppKit
import KongReviewCore

/// 启动页：统计和今日行动共享一个滚动区域。
struct HomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        StatsView(showsHomeActions: true)
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
        return VStack(alignment: .leading, spacing: 14) {
            Text("今天的安排")
                .font(.title3.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions(counts: counts) }
                VStack(alignment: .leading, spacing: 12) { actions(counts: counts) }
            }
            Text(counts.highlights + counts.cards > 0 ? "接着上次的进度，完成今天的回顾。" : "今天的回顾已完成，可以继续浏览摘录或整理记忆卡。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
    }

    @ViewBuilder
    private func actions(counts: (highlights: Int, cards: Int)) -> some View {
        PillButton(icon: "brain", title: "去学习记忆卡·\(counts.cards)", style: counts.cards > 0 ? .primary : .normal) {
            startSuggestedDeck()
        }
        .help("继续上次的牌组；上次的牌组已学完时，学习待学最多的牌组")
        PillButton(icon: "sun.max", title: "去今日回顾·\(counts.highlights)") {
            // 首页显示的是全库今日队列，保留已记录的进度。
            store.review.theme = nil
            store.review.sessionToken += 1
            store.selection = .review
        }
    }

    private func startSuggestedDeck() {
        store.checkDayChange()
        store.refreshDerived()
        let due = store.deckSummaryCache.filter { $0.counts.total > 0 }
        let suggested = store.study.lastDeck.flatMap { last in due.first { $0.name == last } }
            ?? due.max { $0.counts.total < $1.counts.total }
        if let suggested {
            store.startStudy(deck: suggested.name)
        } else {
            store.study.deck = nil
            store.study.browsingDeck = nil
        }
        store.selection = .cards
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
