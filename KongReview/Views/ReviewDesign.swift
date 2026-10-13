import SwiftUI
import KongReviewCore

// 今日回顾与记忆卡共用的版式元素（参照 Readwise 的每日回顾：浅灰底、居中的白色卡片、卡片下方一排圆形按钮）

enum ReviewPalette {
    /// 页面底色：比窗口底色略深一点，衬出白色卡片
    static let page = Color(nsColor: .underPageBackgroundColor)
    /// 卡片底色：浅色模式为白，深色模式为深灰
    static let card = Color(nsColor: .textBackgroundColor)
    static let gradient = LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 0.98), Color(red: 0.36, green: 0.62, blue: 0.93)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 白色圆角卡片
struct ReviewCardContainer<Content: View>: View {
    var padding: CGFloat = 32
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

/// 出处的“封面”：没有封面图时，按出处类型着色，写上书名第一个字（网页显示地球图标）
struct SourceThumb: View {
    let source: Source?
    var size = CGSize(width: 54, height: 72)

    private var color: Color {
        switch source?.kind {
        case .book?: return Color(red: 0.55, green: 0.38, blue: 0.27)
        case .article?: return Color(red: 0.23, green: 0.45, blue: 0.70)
        case .web?: return Color(red: 0.20, green: 0.55, blue: 0.55)
        case .pdf?: return Color(red: 0.70, green: 0.27, blue: 0.27)
        case .ai?: return Color(red: 0.45, green: 0.35, blue: 0.75)
        default: return Color.gray
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            // 书脊的一道亮线
            HStack { Rectangle().fill(.white.opacity(0.18)).frame(width: 4); Spacer() }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            if source?.kind == .web {
                Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(.white.opacity(0.92))
            } else if source?.kind == .ai {
                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.white.opacity(0.92))
            } else {
                Text(String((source?.title ?? "摘").trimmingCharacters(in: CharacterSet(charactersIn: "《》〈〉“”\"' ")).prefix(1)))
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

/// 卡片下方的圆形按钮
struct CircleActionButton: View {
    enum Kind { case outline, filled, plain }
    let icon: String
    let title: String
    var hint: String? = nil
    var kind: Kind = .plain
    var tint: Color = .accentColor
    var diameter: CGFloat = 64
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    switch kind {
                    case .filled:
                        Circle().fill(tint == .accentColor ? AnyShapeStyle(ReviewPalette.gradient) : AnyShapeStyle(tint))
                            .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
                        Image(systemName: icon).font(.system(size: diameter * 0.36, weight: .bold)).foregroundStyle(.white)
                    case .outline:
                        Circle().strokeBorder(tint == .accentColor ? Color.primary.opacity(0.75) : tint, lineWidth: 2)
                            .background(Circle().fill(ReviewPalette.card))
                        Image(systemName: icon).font(.system(size: diameter * 0.32, weight: .medium))
                            .foregroundStyle(tint == .accentColor ? Color.primary.opacity(0.8) : tint)
                    case .plain:
                        Circle().fill(Color.primary.opacity(0.001))
                        Image(systemName: icon).font(.system(size: diameter * 0.36, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                }
                .frame(width: diameter, height: diameter)
                VStack(spacing: 1) {
                    Text(title).font(.callout).foregroundStyle(.secondary)
                    if let hint {
                        Text(hint).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 卡片右下角的小图标按钮
struct CardIconButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(active ? Color.pink : Color.accentColor.opacity(0.85))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
