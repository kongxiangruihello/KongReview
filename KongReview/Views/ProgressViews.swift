import SwiftUI
import AppKit
import KongReviewCore

// 6.0.5：每周自测（6.0.3 起并入今日试卷）、首页“本周进展”、复盘第一步的页面代码已拿掉；数据层照旧（ProgressDatabase）。

// MARK: - 问题页“经过”

struct QuestionTimelinePanel: View {
    @Environment(LibraryStore.self) private var store
    let questionId: Int64
    @State private var steps: [QuestionStep] = []

    var body: some View {
        ProjectPanel(title: "经过", subtitle: steps.isEmpty ? "" : "\(steps.count) 步") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: s.symbol).font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.text).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                            Text(Self.day(s.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                        }
                    }
                }
            }
        }
        .task(id: "\(questionId)|\(store.questionRevision)") { steps = (try? store.db.questionTimeline(id: questionId)) ?? [] }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}
