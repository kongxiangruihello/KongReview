import AppKit
import SwiftUI

// MARK: - 可点击的地方显示手形光标（1.2 起，1.3 改为逐个控件设置）

/// 设置项：“设置 → 快速录入”里可关闭
@MainActor
enum PointerCursor {
    static let enabledKey = "ui.handCursor"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// 鼠标在控件上时显示手形光标，离开时恢复箭头。
///
/// 1.2 用“辅助功能命中测试”统一判断，但 SwiftUI 只在有辅助功能客户端（如旁白）连接时才生成按钮的辅助信息，
/// 平时命中不到按钮，所以回顾页的胶囊按钮没有变手形。1.3 改为在各个按钮上直接加这个修饰符。
struct HandCursor: ViewModifier {
    /// nil 表示看环境里的 isEnabled（外层 .disabled）
    var enabled: Bool? = nil
    @Environment(\.isEnabled) private var envEnabled

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            guard PointerCursor.isEnabled else { return }
            switch phase {
            case .active:
                if enabled ?? envEnabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// 鼠标悬停时显示手形光标
    func handCursor(enabled: Bool? = nil) -> some View { modifier(HandCursor(enabled: enabled)) }
}
