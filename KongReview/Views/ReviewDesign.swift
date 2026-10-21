import SwiftUI
import AppKit
import KongReviewCore

// 今日回顾与记忆卡共用的版式元素。
// 设计：暖白“纸色”页面 + 白色卡片（细边 + 两层柔和阴影）；按钮为紧凑的圆角胶囊，主操作用 App 图标的蓝色，
// 右侧带键帽提示快捷键；深色模式下各色自动换成对应的暗色。

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// 随浅色 / 深色外观切换的颜色
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum ReviewPalette {
    /// 页面：暖白纸色
    static let page = Color.dynamic(NSColor(hex: 0xF6F4EF), NSColor(hex: 0x1C1B19))
    /// 卡片
    static let card = Color.dynamic(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x292826))
    /// 引文块等浅底
    static let soft = Color.dynamic(NSColor(hex: 0xFAF8F3), NSColor(hex: 0x23221F))
    /// 正文墨色、次要文字
    static let ink = Color.dynamic(NSColor(hex: 0x1F1E1C), NSColor(hex: 0xEDEBE6))
    static let sub = Color.dynamic(NSColor(hex: 0x8A857C), NSColor(hex: 0x9C978E))
    /// 细线
    static let hair = Color.dynamic(NSColor(hex: 0x1F1E1C, alpha: 0.08), NSColor(hex: 0xFFFFFF, alpha: 0.09))
    /// 主色：与 App 图标同一种蓝
    static let accent = Color.dynamic(NSColor(hex: 0x3B73EF), NSColor(hex: 0x5B8CF5))
    static let accentSoft = Color.dynamic(NSColor(hex: 0x3B73EF, alpha: 0.12), NSColor(hex: 0x5B8CF5, alpha: 0.18))
    static let again = Color.dynamic(NSColor(hex: 0xE5534B), NSColor(hex: 0xF0716A))
    static let hard = Color.dynamic(NSColor(hex: 0xE0913A), NSColor(hex: 0xEBA45A))
    static let easy = Color.dynamic(NSColor(hex: 0x3E9B6A), NSColor(hex: 0x5BB685))

    // 完成状态的两种颜色——“已”（已回顾、已学）用松绿，“待”（待回顾、待学）用醒目的朱红（3.15 起，此前为藤黄）。
    // 各处统一，颜色之外始终配文字标签。
    static let done = Color.dynamic(NSColor(hex: 0x2F7D57), NSColor(hex: 0x5BB685))
    static let doneSoft = Color.dynamic(NSColor(hex: 0x2F7D57, alpha: 0.12), NSColor(hex: 0x5BB685, alpha: 0.18))
    static let pending = Color.dynamic(NSColor(hex: 0xD93A2B), NSColor(hex: 0xFF6A5C))
    static let pendingSoft = Color.dynamic(NSColor(hex: 0xD93A2B, alpha: 0.12), NSColor(hex: 0xFF6A5C, alpha: 0.2))
}

/// 3.14：“已 / 待”的小圆点标签，如“● 已回顾”
struct ProgressStateLabel: View {
    enum Kind { case done, pending }
    let state: Kind
    let text: String
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .done ? ReviewPalette.done : ReviewPalette.pending)
                .frame(width: size * 0.5, height: size * 0.5)
            // 3.15：“待”的标签文字也用朱红，更醒目
            Text(text).font(.system(size: size, weight: state == .pending ? .medium : .regular))
                .foregroundStyle(state == .pending ? ReviewPalette.pending : ReviewPalette.sub)
        }
    }
}

/// 3.14：已完成（松绿）与待完成（朱红）并排的进度条；总数为 0 时只显示底线
struct DonePendingBar: View {
    let done: Int
    let pending: Int
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let total = done + pending
            let width = geometry.size.width
            let doneWidth = total == 0 ? 0 : width * CGFloat(done) / CGFloat(total)
            HStack(spacing: done > 0 && pending > 0 ? 2 : 0) {
                if done > 0 { Capsule().fill(ReviewPalette.done).frame(width: max(height, doneWidth - (pending > 0 ? 1 : 0))) }
                if pending > 0 { Capsule().fill(ReviewPalette.pending.opacity(0.85)) }
                if total == 0 { Capsule().fill(ReviewPalette.hair) }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已完成 \(done)，待完成 \(pending)")
    }
}

/// 白色卡片：圆角 16、细边、两层柔和阴影
struct ReviewCardContainer<Content: View>: View {
    var padding: CGFloat = 32
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ReviewPalette.hair))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.07), radius: 14, y: 8)
    }
}

/// 出处的“封面”：按出处类型着色，写书名首字（网页为地球、人工智能为星光）
struct SourceThumb: View {
    let source: Source?
    var size = CGSize(width: 40, height: 54)
    @Environment(LibraryStore.self) private var store

    private var color: Color {
        switch source?.kind {
        case .book?: return Color(red: 0.60, green: 0.41, blue: 0.31)
        case .article?: return Color(red: 0.27, green: 0.45, blue: 0.68)
        case .web?: return Color(red: 0.22, green: 0.55, blue: 0.53)
        case .pdf?: return Color(red: 0.69, green: 0.31, blue: 0.29)
        case .ai?: return Color(red: 0.46, green: 0.38, blue: 0.74)
        default: return Color(red: 0.55, green: 0.53, blue: 0.50)
        }
    }

    var body: some View {
        let _ = store.coverRevision
        if let id = source?.id, let img = CoverCache.shared.image(for: id, store: store) {
            // 有封面图：显示封面
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.88), color], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.12)).frame(width: 3)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if source?.kind == .web {
                Image(systemName: "globe").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.92))
            } else if source?.kind == .ai {
                Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.92))
            } else {
                Text(String((source?.title ?? "摘").trimmingCharacters(in: CharacterSet(charactersIn: "《》〈〉“”\"' ")).prefix(1)))
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.96))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
    }
}

/// 键帽：显示快捷键
struct KeyCap: View {
    let text: String
    var onAccent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(onAccent ? Color.white.opacity(0.85) : ReviewPalette.sub)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(onAccent ? Color.clear : ReviewPalette.soft))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(onAccent ? Color.white.opacity(0.35) : ReviewPalette.hair))
    }
}

/// 胶囊按钮：图标 + 文字 + 键帽
struct PillButton: View {
    enum Style { case normal, primary, ghost }
    var icon: String? = nil
    let title: String
    var key: String? = nil
    var style: Style = .normal
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12.5, weight: .semibold))
                }
                Text(title).font(.system(size: 13.5, weight: style == .primary ? .semibold : .regular))
                if let key { KeyCap(text: key, onAccent: style == .primary) }
            }
            .foregroundStyle(style == .primary ? Color.white : (style == .ghost ? ReviewPalette.sub : ReviewPalette.ink))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background {
                switch style {
                case .primary:
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ReviewPalette.accent)
                        .shadow(color: Color(red: 0.23, green: 0.45, blue: 0.94).opacity(0.28), radius: 6, y: 2)
                case .normal:
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ReviewPalette.card)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReviewPalette.hair))
                        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                case .ghost:
                    Color.clear
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .handCursor(enabled: !disabled)
    }
}

/// 按钮组之间的竖线
struct BarSeparator: View {
    var body: some View {
        Rectangle().fill(ReviewPalette.hair).frame(width: 1, height: 20).padding(.horizontal, 6)
    }
}

/// 记忆卡评分按钮：名称（带色点）+ 下次间隔与数字键
struct GradeButton: View {
    let title: String
    let detail: String
    let dot: Color
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    if !primary { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(title).font(.system(size: 13.5, weight: primary ? .semibold : .medium))
                }
                Text(detail).font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(primary ? Color.white.opacity(0.82) : ReviewPalette.sub)
            }
            .foregroundStyle(primary ? Color.white : ReviewPalette.ink)
            .frame(width: 96, height: 50)
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReviewPalette.accent)
                        .shadow(color: Color(red: 0.23, green: 0.45, blue: 0.94).opacity(0.28), radius: 6, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReviewPalette.card)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
                        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

/// 卡片里的小图标按钮
struct CardIconButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? ReviewPalette.again : ReviewPalette.sub)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .help(help)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .handCursor()
    }
}

/// 顶部的一枚小统计：标签 + 数字
struct StatChip: View {
    var icon: String? = nil
    var iconColor: Color = ReviewPalette.sub
    let label: String
    let value: String
    var valueColor: Color = ReviewPalette.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(iconColor)
            }
            Text(label).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(valueColor)
        }
    }
}
