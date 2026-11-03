import Foundation
import KongReviewCore

/// 录入时的提示与必填（只在编辑器里显示，不进卡片正文）；6.0.7 起另有“起始内容”（HTML），新建卡片时先填进这一栏。
struct CardEntryInputRule: Codable, Equatable, Sendable {
    var hint = ""
    var required = false
    /// 6.0.7：起始内容（HTML）。新建卡片时先填进这一栏，作格式与结构的起点；没改动过的起始内容不算填写
    var html: String? = nil

    var startHTML: String? { html.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }

    /// 这一栏还是原样的起始内容（按纯文字比较，编辑器改写了标签写法也认得出）
    func isUntouchedStart(_ value: String) -> Bool {
        guard let start = startHTML else { return false }
        // 文字相同、图片与声音的个数也相同，才算原样
        func signature(_ s: String) -> String {
            let text = Markdown.plainText(fromHTML: s).components(separatedBy: .whitespacesAndNewlines).joined()
            let images = s.components(separatedBy: "<img").count, sounds = s.components(separatedBy: "[sound:").count
            return text + "|\(images)|\(sounds)"
        }
        return signature(value) == signature(start)
    }
}

struct CardEntryValidationIssue: Equatable, Sendable {
    var key: String
    var title: String
    var message: String
}

/// A snapshot taken when applying a preset. Later preset edits do not change an open draft.
struct CardEntryGuidance: Codable, Equatable, Sendable {
    struct Section: Codable, Equatable, Sendable {
        var cardSectionID: String
        var name: String
        var rule: CardEntryInputRule
    }
    var presetName: String
    var noteType: String?
    var fieldNames: [String]
    var front: CardEntryInputRule?
    var back: CardEntryInputRule?
    var fields: [CardEntryInputRule]?
    var sections: [Section]

    func rule(for key: String) -> CardEntryInputRule? {
        if key == "front" { return front }
        if key == "back" { return back }
        if key.hasPrefix("field:"), let index = Int(key.dropFirst(6)), let fields, fields.indices.contains(index) { return fields[index] }
        if key.hasPrefix("section:") { return sections.first { $0.cardSectionID == String(key.dropFirst(8)) }?.rule }
        return nil
    }

    func validationIssues(card: Card, templates: [String: NoteTemplate]) -> [CardEntryValidationIssue] {
        if card.noteType != noteType {
            return [.init(key: "structure", title: "录入模板", message: "当前笔记类型与录入模板不一致，请重新套用合适的录入模板后填写。")]
        }
        if let type = noteType {
            guard let template = templates[type], template.fieldNames == fieldNames, card.fields.count == fieldNames.count,
                  fields == nil || fields?.count == fieldNames.count else {
                return [.init(key: "structure", title: "录入模板", message: "笔记类型「\(type)」的字段已变化。当前输入仍保留，请先恢复或调整笔记类型，避免把内容对应到错误字段。")]
            }
        }
        var issues: [CardEntryValidationIssue] = []
        func inspect(_ key: String, _ title: String, _ value: String, _ rule: CardEntryInputRule?) {
            if rule?.required == true, !Self.hasContent(value) || rule?.isUntouchedStart(value) == true {
                issues.append(.init(key: key, title: title, message: "请填写「\(title)」（必填）。"))
            }
        }
        if noteType == nil {
            inspect("front", "正面", card.front, front)
            inspect("back", "背面", card.back, back)
        } else {
            for (index, name) in fieldNames.enumerated() where card.fields.indices.contains(index) {
                inspect("field:\(index)", name, card.fields[index], fields?[index])
            }
        }
        for section in sections where section.rule.required {
            let current = card.sections?.first { $0.id == section.cardSectionID }
            inspect("section:\(section.cardSectionID)", current?.name.nilIfBlank ?? section.name, current?.text ?? "", section.rule)
        }
        return issues
    }

    /// Rebind only to the fresh, empty structure created by continuous entry.
    /// Refuses a different structure rather than guessing which instruction belongs to which field.
    func rebased(from original: Card, to next: Card) -> Self? {
        guard original.noteType == noteType, next.noteType == noteType,
              original.fields.count == next.fields.count,
              !CardEntryPreset.hasInput(next) else { return nil }
        let old = original.sections ?? [], fresh = next.sections ?? []
        guard old.count == fresh.count,
              zip(old, fresh).allSatisfy({ $0.name == $1.name }) else { return nil }
        var value = self
        value.sections = sections.compactMap { section in
            guard let index = old.firstIndex(where: { $0.id == section.cardSectionID }) else { return nil }
            var mapped = section
            mapped.cardSectionID = fresh[index].id
            mapped.name = fresh[index].name
            return mapped
        }
        return value
    }

    /// 6.0.7：把空着的栏目填上起始内容（新建、保存并新增时）
    func prefilled(_ card: Card) -> Card {
        var c = card
        func fill(_ value: String, _ rule: CardEntryInputRule?) -> String {
            guard let start = rule?.startHTML, !Self.hasContent(value) else { return value }
            return start
        }
        if noteType == nil {
            c.front = fill(c.front, front)
            c.back = fill(c.back, back)
        } else if let fields {
            for i in c.fields.indices where fields.indices.contains(i) { c.fields[i] = fill(c.fields[i], fields[i]) }
        }
        if var secs = c.sections {
            for i in secs.indices { secs[i].text = fill(secs[i].text, rule(for: "section:" + secs[i].id)) }
            c.sections = secs
        }
        return c
    }

    /// 除了原样的起始内容以外，有没有填过东西
    func hasInput(_ card: Card) -> Bool {
        var c = card
        func clear(_ value: String, _ key: String) -> String { rule(for: key)?.isUntouchedStart(value) == true ? "" : value }
        c.front = clear(c.front, "front")
        c.back = clear(c.back, "back")
        for i in c.fields.indices { c.fields[i] = clear(c.fields[i], "field:\(i)") }
        if var secs = c.sections {
            for i in secs.indices { secs[i].text = clear(secs[i].text, "section:" + secs[i].id) }
            c.sections = secs
        }
        return CardEntryPreset.hasInput(c)
    }

    static func hasContent(_ value: String) -> Bool {
        HTMLSourceCodec.hasContent(value) || value.range(of: #"\[sound:[^\]]+\]"#, options: .regularExpression) != nil
    }
}

extension CardDraft {
    func entryValidationIssues(templates: [String: NoteTemplate]) -> [CardEntryValidationIssue] {
        entryGuidance?.validationIssues(card: card, templates: templates) ?? []
    }
}
