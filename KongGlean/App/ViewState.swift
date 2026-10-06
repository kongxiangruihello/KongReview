import Foundation
import Observation
import KongGleanCore

// 说明：从 macOS 27 SDK 起，SwiftUI 的 @State 变成了宏，宏插件只随完整版 Xcode 提供，
// 仅装“命令行工具”时无法编译 @State。因此界面的局部状态改放在 @Observable 类里，
// 由 LibraryStore 持有。（@Observable 的宏插件随 Swift 工具链提供，不受影响。）

/// 每日回顾界面的状态
@MainActor
@Observable
final class ReviewState {
    /// 主题回顾：按标签限定范围；nil 为全库
    var theme: String?
    var cards: [ReviewCard] = []
    var position = 0
}

/// 摘录列表界面的状态
@MainActor
@Observable
final class ListState {
    var query = ""
    var items: [Highlight] = []
}

struct ReviewCard: Identifiable {
    var highlight: Highlight
    var isMastery: Bool
    var id: Int64 { highlight.id ?? -1 }
}
