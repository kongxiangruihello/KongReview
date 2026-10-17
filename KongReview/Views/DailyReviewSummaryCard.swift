import SwiftUI
import KongReviewCore

/// 今日回顾完成页的日课卡：统计、近七天、今日一句和下一步。
struct DailyReviewSummaryCard<Actions: View>: View {
    @Environment(LibraryStore.self) private var store
    let title: String
    var quoteOverride: (text: String, source: String)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        let _ = store.revision
        let s = store.stats
        let due = store.dueCardCount()
        let week = Array(s.lastDays.suffix(7))
        let peak = max(1, week.map(\.total).max() ?? 1)
        let quote = quoteOverride ?? store.dailyReviewQuote()

        VStack(spacing: 0) {
            Text(Self.longDate(store.today))
                .font(.system(size: 12.5))
                .tracking(1)
                .foregroundStyle(ReviewPalette.sub)
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(ReviewPalette.ink)
                .padding(.top, 10)
                .padding(.bottom, 26)

            HStack(spacing: 0) {
                bigStat("\(s.today.highlights)", unit: "条", label: s.today.cards > 0 ? "今日回顾 · 记忆卡 \(s.today.cards) 次" : "今日回顾摘录")
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                bigStat("\(s.currentStreak)", unit: "天", label: "连续回顾 · 最长 \(s.longestStreak) 天")
                Rectangle().fill(ReviewPalette.hair).frame(width: 1)
                bigStat("\(due)", unit: "张", label: due > 0 ? "记忆卡待学" : "记忆卡今天学完了", accent: due > 0)
            }
            .frame(height: 104)
            .overlay(alignment: .top) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(week.enumerated()), id: \.offset) { i, day in
                    let isToday = i == week.count - 1
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isToday ? ReviewPalette.accent : ReviewPalette.accentSoft)
                            .frame(width: 16, height: max(6, 52 * CGFloat(day.total) / CGFloat(peak)))
                        Text(isToday ? "今天" : Self.weekday(day.key))
                            .font(.system(size: 11))
                            .foregroundStyle(isToday ? ReviewPalette.ink : ReviewPalette.sub)
                    }
                    .help("\(day.key)：摘录 \(day.highlights) 条，记忆卡 \(day.cards) 次")
                }
            }
            .frame(height: 82, alignment: .bottom)
            .padding(.top, 22)

            if let quote {
                VStack(alignment: .leading, spacing: 8) {
                    Text("“\(quote.text)”")
                        .font(.system(size: 16, design: .serif))
                        .lineSpacing(6)
                        .foregroundStyle(ReviewPalette.ink.opacity(0.88))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("今日一句" + (quote.source.isEmpty ? "" : " · " + quote.source))
                        .font(.system(size: 12.5))
                        .foregroundStyle(ReviewPalette.sub)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReviewPalette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 24)
            }

            actions
                .padding(.top, 26)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 34)
        .frame(maxWidth: 640)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ReviewPalette.hair))
        .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.08), radius: 20, y: 10)
    }

    private func bigStat(_ number: String, unit: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ? ReviewPalette.accent : ReviewPalette.ink)
                Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(ReviewPalette.sub)
            }
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(ReviewPalette.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private static func longDate(_ key: String) -> String {
        let date = parseDay(key) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter.string(from: date)
    }

    private static func weekday(_ key: String) -> String {
        guard let date = parseDay(key) else { return "" }
        return ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1]
    }

    private static func parseDay(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}
