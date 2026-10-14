import SwiftUI
import AppKit
import KongReviewCore

// MARK: - 1.9：日课卡（提醒通知里附的小图）

/// 纸色底、宋体日期、今天的功课与约需分钟数、一枚“日课”朱印
struct DailyCardArt: View {
    let date: Date
    let highlights: Int
    let cards: StudyQueue.Counts
    let streak: Int

    var body: some View {
        let minutes = DailyCard.minutes(highlights: highlights, cards: cards)
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(DeckOverview.chineseDate(date))
                    .font(.system(size: 15, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(red: 0x8A / 255, green: 0x85 / 255, blue: 0x7C / 255))
                Text(highlights + cards.total == 0 ? "今日无课" : "今日功课")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1C / 255))
                HStack(spacing: 22) {
                    stat("\(highlights)", "条摘录", DeckColors.all[0].color)
                    stat("\(cards.total)", "张记忆卡", DeckColors.all[2].color)
                    if minutes > 0 { stat("\(minutes)", "分钟", DeckColors.all[5].color) }
                }
                .padding(.top, 4)
                if streak > 1 {
                    Text("已连续 \(streak) 天")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0x8A / 255, green: 0x85 / 255, blue: 0x7C / 255))
                }
                Spacer(minLength: 0)
                Text("学而时习之，不亦说乎？")
                    .font(.custom("Kaiti SC", size: 15))
                    .foregroundStyle(Color(red: 0x8A / 255, green: 0x85 / 255, blue: 0x7C / 255))
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            SealStamp(text: "日课", size: 24)
                .padding(28)
        }
        .frame(width: 560, height: 320)
        .background(Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xEF / 255))
        .overlay(alignment: .leading) {
            Rectangle().fill(DeckColors.all[1].color).frame(width: 8)
        }
        .environment(\.colorScheme, .light)
    }

    private func stat(_ n: String, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(n).font(.system(size: 30, weight: .medium, design: .serif).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 14)).foregroundStyle(Color(red: 0x5A / 255, green: 0x56 / 255, blue: 0x50 / 255))
        }
    }
}

@MainActor
enum DailyCardImage {
    /// 画成 PNG 写到临时文件夹，返回文件地址（通知系统会把它搬走）
    static func write(date: Date, highlights: Int, cards: StudyQueue.Counts, streak: Int) -> URL? {
        let renderer = ImageRenderer(content: DailyCardArt(date: date, highlights: highlights, cards: cards, streak: streak))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kongreview-dailycard-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
