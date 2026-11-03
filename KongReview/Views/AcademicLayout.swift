import SwiftUI

// MARK: - 3.14：学术版式
//
// 个人成长页按论文的体例排版：节号＋标题、三线表（表题在上、注在下）、小节标题、引文块、附录。
// 只用墨色与细线区分层级，颜色仅用于“当前选中”和“已 / 待”状态。

/// 成长页里旧组件（计划、复盘）嵌入学术版式时，去掉 GroupBox 的灰底与标题
struct AcademicEmbeddedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var academicEmbedded: Bool {
        get { self[AcademicEmbeddedKey.self] }
        set { self[AcademicEmbeddedKey.self] = newValue }
    }
}

