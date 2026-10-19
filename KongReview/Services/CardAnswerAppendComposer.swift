import Foundation
import KongReviewCore

enum CardAppendLocation: Hashable, Identifiable, Sendable {
    case back
    case field(Int)
    case section(String)

    var id: String {
        switch self {
        case .back: "back"
        case .field(let index): "field:\(index)"
        case .section(let id): "section:\(id)"
        }
    }
}

struct CardAppendContentBlock: Identifiable, Equatable, Sendable {
    var id: CardAppendLocation
    var title: String
    var content: String
}

struct CardAppendSelection: Equatable, Sendable {
    var sourceIDs: Set<CardAppendLocation>
    var target: CardAppendLocation
}

struct CardAnswerAppendPreview: Equatable, Sendable {
    let incoming: Card
    let existing: Card
    let incomingTemplate: NoteTemplate?
    let existingTemplate: NoteTemplate?
    let selection: CardAppendSelection
    /// Only content changes here. The database supplies the save time in its transaction.
    let result: Card
}

enum CardAnswerAppendError: LocalizedError, Equatable {
    case noSelection, invalidSelection, duplicateContent(String)

    var errorDescription: String? {
        switch self {
        case .noSelection: "请至少选择一项要追加的内容。"
        case .invalidSelection: "追加的内容或位置已经变化，请重新选择。"
        case .duplicateContent(let title): "「\(title)」的完整内容已经存在，不能重复追加。请取消该项或修改内容。"
        }
    }
}

/// Preview and persistence share this pure composition so that the confirmed content is what is saved.
enum CardAnswerAppendComposer {
    static func sources(for card: Card, template: NoteTemplate?) -> [CardAppendContentBlock] {
        blocks(for:card,template:template).filter { hasContent($0.content) }
    }

    static func destinations(for card: Card, template: NoteTemplate?) -> [CardAppendContentBlock] {
        blocks(for:card,template:template)
    }

    static func preview(from incoming: Card, to existing: Card,
                        incomingTemplate: NoteTemplate?, existingTemplate: NoteTemplate?,
                        selection: CardAppendSelection) throws -> CardAnswerAppendPreview {
        let available = sources(for:incoming,template:incomingTemplate)
        guard !available.isEmpty else { throw CardComparisonError.noAnswer }
        guard !selection.sourceIDs.isEmpty else { throw CardAnswerAppendError.noSelection }
        guard selection.sourceIDs.isSubset(of:Set(available.map(\.id))) else {
            throw CardAnswerAppendError.invalidSelection
        }
        let targets = destinations(for:existing,template:existingTemplate)
        guard !targets.isEmpty else { throw CardComparisonError.noAnswerField }
        guard let target = targets.first(where: { $0.id == selection.target }) else {
            throw CardAnswerAppendError.invalidSelection
        }
        let selected = available.filter { selection.sourceIDs.contains($0.id) }
        var accumulated = canonicalHTML(target.content)
        var addition = ""
        for block in selected {
            let fragment = canonicalHTML(block.content)
            // Exact rendered fragments retain link destinations, media references, case, and formatting.
            // Avoid text-only matching: two equally captioned images can be different answers.
            guard !accumulated.contains(fragment) else {
                throw CardAnswerAppendError.duplicateContent(block.title)
            }
            let part = "<hr><p>补充答案 · \(Markdown.escape(block.title))</p>" + Markdown.html(block.content)
            addition += part
            accumulated += part
        }
        var result = existing
        let merged = Markdown.html(target.content) + addition
        switch selection.target {
        case .back:
            result.back = merged
        case .field(let index):
            result.fields[index] = merged
            // Field zero is also a search cache, even when this template displays a different question field.
            if index == 0 { result.front = result.fields[0] }
            result.back = result.fields.dropFirst().joined(separator:"<hr>")
        case .section(let id):
            guard let index = result.sections?.firstIndex(where: { $0.id == id }) else {
                throw CardAnswerAppendError.invalidSelection
            }
            result.sections?[index].text = merged
        }
        return .init(incoming:incoming,existing:existing,incomingTemplate:incomingTemplate,
                     existingTemplate:existingTemplate,selection:selection,result:result)
    }

    private static func blocks(for card: Card, template: NoteTemplate?) -> [CardAppendContentBlock] {
        if let type = card.noteType, !card.fields.isEmpty {
            guard let template, template.name == type else { return [] }
            var used = Set<Int>()
            return template.back.compactMap { index in
                guard card.fields.indices.contains(index), !template.front.contains(index), used.insert(index).inserted else { return nil }
                let title = template.fieldNames.indices.contains(index) ? template.fieldNames[index] : "字段\(index + 1)"
                return .init(id:.field(index),title:title,content:card.fields[index])
            }
        }
        return [.init(id:.back,title:"背面答案",content:card.back)] + (card.sections ?? []).map {
            .init(id:.section($0.id),title:$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名栏目" : $0.name,content:$0.text)
        }
    }

    private static func hasContent(_ content: String) -> Bool {
        HTMLSourceCodec.hasContent(content) || content.contains("[sound:")
    }

    private static func canonicalHTML(_ content: String) -> String {
        Markdown.html(content).replacingOccurrences(of:"\r\n",with:"\n")
            .trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
}
