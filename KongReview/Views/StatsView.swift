import SwiftUI
import Charts
import KongReviewCore

/// 回顾统计：连续天数、最近 30 天每天回顾的摘录与记忆卡、记忆卡正确率、库存数字
struct StatsView: View {
    @Environment(LibraryStore.self) private var store

    private struct Bar: Identifiable {
        var day: Date
        var kind: String
        var count: Int
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        _ = store.revision
        _ = store.today
        let s = store.stats
        let cards = (try? store.db.cards()) ?? []
        let bars = s.lastDays.flatMap { d -> [Bar] in
            let date = Self.parse(d.key)
            return [Bar(day: date, kind: "摘录", count: d.highlights), Bar(day: date, kind: "记忆卡", count: d.cards)]
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    tile("今天", "\(s.today.highlights) 条摘录\n\(s.today.cards) 次记忆卡", "sun.max")
                    tile("连续回顾", "\(s.currentStreak) 天", "flame")
                    tile("最长连续", "\(s.longestStreak) 天", "trophy")
                    tile("回顾过的天数", "\(s.activeDays) 天", "calendar")
                    tile("累计回顾", "\(s.totalHighlights) 条摘录\n\(s.totalCards) 次记忆卡", "sum")
                    tile("记忆卡正确率", s.cardAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—", "checkmark.circle")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近 30 天").font(.headline)
                    Chart(bars) { b in
                        BarMark(x: .value("日期", b.day, unit: .day), y: .value("次数", b.count))
                            .foregroundStyle(by: .value("类别", b.kind))
                    }
                    .chartForegroundStyleScale(["摘录": Color.blue, "记忆卡": Color.purple])
                    .frame(height: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("库存").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { Text("摘录"); Text("\(store.highlightCounts.values.reduce(0, +)) 条（已归类）") }
                        GridRow { Text("出处"); Text("\(store.sources.count) 个") }
                        GridRow { Text("网页存档"); Text("\(store.articleCount) 篇") }
                        GridRow {
                            Text("记忆卡")
                            Text("\(cards.count) 张：新卡 \(cards.filter { $0.state == .new }.count)，学习中 \(cards.filter { $0.state == .learning || $0.state == .relearning }.count)，复习中 \(cards.filter { $0.state == .review }.count)，已暂停 \(cards.filter(\.isSuspended).count)")
                        }
                    }
                    .monospacedDigit()
                }

                Text("统计从 0.7 版开始记录：每日回顾里“下一条 / 收藏 / 弃置 / 做成记忆卡”算回顾一条摘录；记忆卡每评一次分算一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("回顾统计")
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
    }

    static func parse(_ key: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key) ?? Date()
    }
}
