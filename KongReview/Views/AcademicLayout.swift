import SwiftUI

// MARK: - 3.14：学术版式
//
// 个人成长页按论文的体例排版：节号＋标题、三线表（表题在上、注在下）、小节标题、引文块、附录。
// 只用墨色与细线区分层级，颜色仅用于“当前选中”和“已 / 待”状态。

enum AcademicType {
    static let title = Font.system(size: 24, weight: .semibold, design: .serif)
    static let section = Font.system(size: 17, weight: .semibold, design: .serif)
    static let subsection = Font.system(size: 14, weight: .semibold, design: .serif)
    static let caption = Font.system(size: 12.5, weight: .semibold, design: .serif)
    static let body = Font.system(size: 13.5)
    static let table = Font.system(size: 13)
    static let note = Font.system(size: 11.5)
}

/// 纸张：白底、细边，限制行宽，像一页报告
struct AcademicPaper<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 30) { content }
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
            .frame(maxWidth: 880, alignment: .leading)
            .background(ReviewPalette.card)
            .overlay(Rectangle().stroke(ReviewPalette.hair))
            .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.12).opacity(0.05), radius: 10, y: 4)
            .frame(maxWidth: .infinity)
    }
}

/// 报告题目：居中题目、副题与双细线
struct AcademicTitleBlock: View {
    let title: String
    let subtitle: String
    var note: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(AcademicType.title).foregroundStyle(ReviewPalette.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).monospacedDigit()
            if let note { Text(note).font(AcademicType.note).foregroundStyle(ReviewPalette.sub) }
            VStack(spacing: 2) {
                Rectangle().fill(ReviewPalette.ink.opacity(0.75)).frame(height: 1.2)
                Rectangle().fill(ReviewPalette.ink.opacity(0.75)).frame(height: 0.6)
            }
            .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// 一节：“一、数据概览”，下接一段导语
struct AcademicSection<Content: View>: View {
    let number: String
    let title: String
    var lead: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number)、\(title)").font(AcademicType.section).foregroundStyle(ReviewPalette.ink)
                Spacer(minLength: 8)
                if let trailing { trailing }
            }
            if let lead {
                Text(lead).font(AcademicType.body).foregroundStyle(ReviewPalette.ink.opacity(0.8))
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// 小节标题：“4.1 本期收获”
struct AcademicSubheading: View {
    let number: String
    let title: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(AcademicType.subsection).monospacedDigit().foregroundStyle(ReviewPalette.sub)
            Text(title).font(AcademicType.subsection).foregroundStyle(ReviewPalette.ink)
            if let hint { Text(hint).font(AcademicType.note).foregroundStyle(ReviewPalette.sub) }
        }
    }
}

/// 表题：“表 1  本期学习数据与上期同期比较”，居中，在表上方
struct AcademicCaption: View {
    let label: String
    let title: String

    var body: some View {
        Text("\(label)　\(title)")
            .font(AcademicType.caption)
            .foregroundStyle(ReviewPalette.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// 注：表下方的说明
struct AcademicNote: View {
    let text: String

    var body: some View {
        (Text("注：").fontWeight(.semibold) + Text(text))
            .font(AcademicType.note)
            .foregroundStyle(ReviewPalette.sub)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 三线表的横线：顶线、底线粗，栏目线细
struct AcademicRule: View {
    var heavy = false

    var body: some View {
        Rectangle().fill(ReviewPalette.ink.opacity(heavy ? 0.8 : 0.35)).frame(height: heavy ? 1.4 : 0.7)
            .gridCellUnsizedAxes(.horizontal)
    }
}

/// 三线表：表题、表头、表体与注。表体每一行用 `GridRow`。
struct AcademicTable<Header: View, Rows: View>: View {
    let label: String
    let title: String
    var note: String? = nil
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AcademicCaption(label: label, title: title)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                AcademicRule(heavy: true)
                AcademicGap()
                GridRow { header }
                    .font(AcademicType.table.weight(.semibold))
                    .foregroundStyle(ReviewPalette.ink)
                AcademicGap()
                AcademicRule()
                AcademicGap(height: 4)
                rows
                AcademicGap(height: 4)
                AcademicRule(heavy: true)
            }
            .font(AcademicType.table)
            .foregroundStyle(ReviewPalette.ink)
            if let note { AcademicNote(text: note).padding(.top, 2) }
        }
    }
}

/// 表格内的竖向留白（占满整行，不参与列宽）
struct AcademicGap: View {
    var height: CGFloat = 6
    var body: some View { Color.clear.frame(height: height).gridCellUnsizedAxes(.horizontal) }
}

extension View {
    /// 表体单元格的上下留白
    func academicCell() -> some View { padding(.vertical, 5) }
}

/// 引文块：左侧竖线，用于引用上期内容或引导语
struct AcademicQuote<Content: View>: View {
    var label: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(ReviewPalette.ink.opacity(0.25)).frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                if let label { Text(label).font(AcademicType.note.weight(.semibold)).foregroundStyle(ReviewPalette.sub) }
                content
            }
            .font(.system(size: 13.5, design: .serif))
            .foregroundStyle(ReviewPalette.ink.opacity(0.85))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 节与节之间的细线
struct AcademicDivider: View {
    var body: some View { Rectangle().fill(ReviewPalette.hair).frame(height: 1) }
}

/// 成长页里旧组件（计划、复盘）嵌入学术版式时，去掉 GroupBox 的灰底与标题
struct AcademicEmbeddedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var academicEmbedded: Bool {
        get { self[AcademicEmbeddedKey.self] }
        set { self[AcademicEmbeddedKey.self] = newValue }
    }
}

/// 未嵌入时照旧用 GroupBox；嵌入学术版式时只保留内容
struct GrowthBox<Content: View>: View {
    @Environment(\.academicEmbedded) private var embedded
    let title: String
    /// 嵌入时以引文块呈现（用于引导语）
    var quote = false
    @ViewBuilder var content: Content

    var body: some View {
        if embedded && quote {
            AcademicQuote(label: title) { content }
        } else if embedded {
            VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GroupBox(title) { content }
        }
    }
}
