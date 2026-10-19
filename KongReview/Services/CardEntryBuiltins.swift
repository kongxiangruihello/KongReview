import Foundation

/// Examples are separate preview text; copying a builtin always creates empty inputs.
struct CardEntryBuiltin: Identifiable, Sendable {
    var id: String
    var preset: CardEntryPreset
    var examples: [(title: String, text: String)]

    func editableCopy() -> CardEntryPreset {
        var value = preset
        value.id = UUID()
        value.sections = value.sections.map { section in
            var section = section; section.id = UUID(); return section
        }
        return value
    }
}

enum CardEntryBuiltins {
    static let all: [CardEntryBuiltin] = [
        .init(id: "term", preset: .init(name: "名词解释", sections: [
            .init(name: "背景", rule: .init(hint: "交代提出背景、时间或适用范围")),
            .init(name: "意义", rule: .init(hint: "说明历史地位、影响或概念边界"))
        ], frontRule: .init(hint: "填写需要解释的概念或名词", required: true),
           backRule: .init(hint: "先用一句话概括，再列出关键要素", required: true)),
              examples: [("正面", "洋务运动"), ("背面", "19世纪60至90年代，清政府部分官员以自强、求富为目标开展的近代化探索。"), ("背景", "内忧外患下寻求维护清朝统治。"), ("意义", "推动近代工业与新式教育的发展。")]),
        .init(id: "event", preset: .init(name: "历史事件", sections: [
            .init(name: "背景", rule: .init(hint: "分别考虑国内、国际及直接原因")),
            .init(name: "经过", rule: .init(hint: "按时间顺序记录关键节点", required: true)),
            .init(name: "影响", rule: .init(hint: "区分直接结果、长期影响与局限"))
        ], frontRule: .init(hint: "事件名称或围绕事件提出的问题", required: true),
           backRule: .init(hint: "事件发生的时间、地点与核心内容")),
              examples: [("正面", "戊戌变法"), ("背面", "1898年，维新派推动清政府开展的政治改革。"), ("经过", "公车上书 → 百日维新 → 戊戌政变。"), ("影响", "促进思想启蒙，也暴露改革条件与力量的限制。")]),
        .init(id: "person", preset: .init(name: "人物", sections: [
            .init(name: "主要活动", rule: .init(hint: "围绕相关主题，按时间列出代表性活动", required: true)),
            .init(name: "思想与主张", rule: .init(hint: "概括核心主张，可补充原文出处")),
            .init(name: "评价", folded: true, rule: .init(hint: "结合时代条件，说明贡献与局限"))
        ], frontRule: .init(hint: "人物姓名或研究问题", required: true),
           backRule: .init(hint: "时代、身份及一句话定位")),
              examples: [("正面", "严复"), ("背面", "中国近代思想家、翻译家。"), ("主要活动", "译介《天演论》等著作。"), ("思想与主张", "通过译著传播进化论等西方近代思想。")]),
        .init(id: "source", preset: .init(name: "史料分析", sections: [
            .init(name: "出处", rule: .init(hint: "作者、篇名、时间与页码；无法确定时注明待核")),
            .init(name: "分析", rule: .init(hint: "作者立场—写作语境—核心信息—史料价值与局限", required: true)),
            .init(name: "相关问题", folded: true, rule: .init(hint: "记录可与此材料相互印证或比较的问题"))
        ], frontRule: .init(hint: "粘贴史料或写出分析问题", required: true),
           backRule: .init(hint: "先概括史料反映的主要观点")),
              examples: [("正面", "如何理解“师夷长技以制夷”？"), ("出处", "魏源《海国图志》。"), ("分析", "联系鸦片战争后的时代背景，分析学习西方技术与抵御外侮之间的关系。")]),
        .init(id: "essay", preset: .init(name: "论述题", sections: [
            .init(name: "论据", rule: .init(hint: "每个分论点配一至两个史实，并交代其证明作用", required: true)),
            .init(name: "结论", rule: .init(hint: "回应题目，概括主要判断及适用范围")),
            .init(name: "补充阅读", folded: true, rule: .init(hint: "记录可继续阅读的著作、论文或待核出处"))
        ], frontRule: .init(hint: "完整题目，并保留时间、范围和设问限制", required: true),
           backRule: .init(hint: "中心论点—分论点一—分论点二—分论点三", required: true)),
              examples: [("正面", "试论晚清新式教育发展的特点。"), ("背面", "围绕教育目标、办学主体与制度变化组织论点。"), ("论据", "可从新式学堂、留学教育与科举制度变动等方面选择史实。")])
    ]
}
