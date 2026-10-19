import Foundation
import KongReviewCore

enum CardBulkEntryFormat: String, CaseIterable, Identifiable, Sendable {
    case tabSeparated, questionAnswer
    var id: String { rawValue }
    var title: String { self == .tabSeparated ? "表格 / Tab 分列" : "问：答：分组" }
}

struct CardBulkEntryParseIssue: Equatable, Identifiable, Sendable {
    var line: Int
    var message: String
    var id: String { "\(line)|\(message)" }
}

struct CardBulkEntrySourceRow: Equatable, Sendable {
    var line: Int
    var values: [String]
}

struct CardBulkEntryParseResult: Equatable, Sendable {
    var rows: [CardBulkEntrySourceRow] = []
    var issues: [CardBulkEntryParseIssue] = []
    var columnCount: Int { rows.map(\.values.count).max() ?? 0 }
}

enum CardBulkEntryParser {
    static let maximumCards = 500
    static let maximumCharacters = 1_000_000

    static func parse(_ source: String, format: CardBulkEntryFormat, firstRowIsHeader: Bool = false) -> CardBulkEntryParseResult {
        guard source.count <= maximumCharacters else {
            return .init(issues:[.init(line:1,message:"一次最多粘贴 100 万个字符，请拆成几批录入。原文仍保留。")])
        }
        let text = source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        var result = format == .tabSeparated ? tabSeparated(text) : questionAnswer(text)
        let maximumRows = maximumCards + (format == .tabSeparated && firstRowIsHeader ? 1 : 0)
        if result.rows.count > maximumRows {
            result.issues.append(.init(line:result.rows[maximumRows].line,message:"一次最多录入 \(maximumCards) 张，请拆成几批。没有截断或保存本批数据。"))
        }
        if result.rows.isEmpty, result.issues.isEmpty {
            result.issues.append(.init(line:1,message:"没有识别到卡片，请粘贴表格，或按“问：…”“答：…”分组。"))
        }
        return result
    }

    /// Spreadsheet-style TSV, including quoted tabs/newlines and doubled quotes.
    private static func tabSeparated(_ source: String) -> CardBulkEntryParseResult {
        var result = CardBulkEntryParseResult()
        let characters = Array(source)
        var index = 0, line = 1, rowStart = 1
        var fields: [String] = [], field = ""
        var quoted = false, afterQuote = false, fieldStarted = false, rowTouched = false
        func finishField() { fields.append(field);field = "";fieldStarted = false;afterQuote = false }
        func finishRow() {
            finishField()
            // Empty physical separator lines carry no card data. An explicit quoted empty
            // cell or tabbed row is retained and will receive the ordinary front validation.
            if rowTouched || fields.count > 1 || fields.contains(where:{ !$0.isEmpty }) {
                result.rows.append(.init(line:rowStart,values:fields))
            }
            fields = [];rowTouched = false
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"");index += 1
                    } else { quoted = false;afterQuote = true }
                } else { field.append(character);if character == "\n" { line += 1 } }
            } else if character == "\t" {
                finishField();rowTouched = true
            } else if character == "\n" {
                finishRow();line += 1;rowStart = line
            } else if character == "\"", !fieldStarted, !afterQuote {
                quoted = true;fieldStarted = true;rowTouched = true
            } else if afterQuote {
                if character != " " {
                    result.issues.append(.init(line:line,message:"带引号的单元格结束后还有文字，请用 Tab 分列，或把引号写成双引号转义。"))
                    field.append(character);afterQuote = false
                }
            } else {
                field.append(character);fieldStarted = true;rowTouched = true
            }
            index += 1
        }
        if quoted { result.issues.append(.init(line:rowStart,message:"这个单元格的引号没有闭合；多行单元格请用一对英文双引号包住。")) }
        if rowTouched || !field.isEmpty || !fields.isEmpty { finishRow() }
        return result
    }

    /// Only an explicit question prefix starts the next card; answer continuation lines
    /// and blank paragraphs remain in the same answer.
    private static func questionAnswer(_ source: String) -> CardBulkEntryParseResult {
        var result = CardBulkEntryParseResult()
        var question: [String] = [], answer: [String] = [], start: Int?, hasAnswer = false
        func finish() {
            guard let start else { return }
            if !hasAnswer { result.issues.append(.init(line:start,message:"这组问题没有“答：”，请补上答案标记。")) }
            result.rows.append(.init(line:start,values:[question.joined(separator:"\n"),answer.joined(separator:"\n")]))
        }
        for (offset,line) in source.components(separatedBy:"\n").enumerated() {
            let number = offset + 1
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            if let value = prefixedValue(trimmed,prefix:"问") {
                finish();start = number;question = [value];answer = [];hasAnswer = false
            } else if let value = prefixedValue(trimmed,prefix:"答") {
                guard start != nil else { result.issues.append(.init(line:number,message:"答案前没有“问：”，请先写问题。"));continue }
                if hasAnswer {
                    result.issues.append(.init(line:number,message:"同一组出现第二个“答：”；新卡请先写“问：”，答案续行无需重复标记。"))
                    answer.append(line)
                } else { hasAnswer = true;answer = [value] }
            } else if start != nil {
                if hasAnswer { answer.append(line) } else { question.append(line) }
            } else if !trimmed.isEmpty {
                result.issues.append(.init(line:number,message:"这行没有所属问题，请加上“问：”，或移入相应答案。"))
            }
        }
        finish()
        return result
    }

    private static func prefixedValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix + "：") || line.hasPrefix(prefix + ":") else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in:.whitespaces)
    }

    /// Preserve deliberate HTML, while plain pasted text cannot become markup accidentally.
    static func html(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        if source.range(of:#"(?is)</?[a-z][a-z0-9:-]*(?:\s[^>]*|\s*/?)>"#,options:.regularExpression) != nil {
            return source
        }
        return "<p>" + Markdown.escape(source).replacingOccurrences(of:"\n",with:"<br>\n") + "</p>"
    }

    static func candidates(_ parsed: CardBulkEntryParseResult) throws -> [CardBulkEntryCandidate] {
        guard parsed.issues.isEmpty else { throw CardBulkEntryError.parseIssues }
        return parsed.rows.map { .init(line:$0.line,values:$0.values.map(html)) }
    }
}

enum CardBulkEntryDestination: Hashable, Identifiable, Sendable {
    case unassigned, front, back, field(Int), section(Int)
    var id: String {
        switch self {
        case .unassigned: return "unassigned"
        case .front: return "front"
        case .back: return "back"
        case .field(let index): return "field:\(index)"
        case .section(let index): return "section:\(index)"
        }
    }
}

struct CardBulkEntryConfiguration: Equatable, Sendable {
    var deck = "默认"
    var tags: [String] = []
    var preset: CardEntryPreset?
    var mapping: [CardBulkEntryDestination] = []

    func destinations() -> [(destination: CardBulkEntryDestination, title: String)] {
        if let preset, preset.noteType != nil {
            return preset.fieldNames.enumerated().map { (.field($0.offset),$0.element) }
        }
        return [(.front,"正面"),(.back,"背面")] + (preset?.sections ?? []).enumerated().map { (.section($0.offset),$0.element.name) }
    }

    func defaultMapping(columnCount: Int) -> [CardBulkEntryDestination] {
        let targets = destinations().map(\.destination)
        return (0..<columnCount).map { targets.indices.contains($0) ? targets[$0] : .unassigned }
    }

    func makeCard(_ candidate: CardBulkEntryCandidate, templates: [String:NoteTemplate]) throws -> Card {
        let destinations = Set(destinations().map(\.destination))
        guard mapping.count >= candidate.values.count else { throw CardBulkEntryError.mapping("有尚未分配的列，请逐列指定字段。") }
        let assigned = mapping.filter { $0 != .unassigned }
        guard Set(assigned).count == assigned.count else { throw CardBulkEntryError.mapping("同一字段不能对应多个列，请调整字段对应。") }
        guard assigned.allSatisfy({ destinations.contains($0) }) else { throw CardBulkEntryError.mapping("字段对应已失效，请重新指定。") }
        var card = try preset?.blankCard(templates:templates,deckOverride:deck) ?? Card(deck:deck,front:"")
        let guidance = preset?.guidance(for:card)
        card.deck = deck.trimmingCharacters(in:.whitespacesAndNewlines).nilIfBlank ?? "默认"
        card.tags = TagParser.parse(TagParser.format((preset?.tags ?? []) + tags))
        for (index,value) in candidate.values.enumerated() {
            switch mapping[index] {
            case .unassigned:
                guard value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                    throw CardBulkEntryError.mapping("第 \(index + 1) 列有内容但尚未分配字段；请指定对应栏目，避免遗漏文字。")
                }
            case .front: card.front = value
            case .back: card.back = value
            case .field(let field):
                guard card.fields.indices.contains(field) else { throw CardBulkEntryError.changedTemplate }
                card.fields[field] = value
            case .section(let section):
                guard card.sections?.indices.contains(section) == true else { throw CardBulkEntryError.changedTemplate }
                card.sections?[section].text = value
            }
        }
        if card.noteType != nil, !card.fields.isEmpty {
            card.front = card.fields[0]
            card.back = card.fields.dropFirst().filter { !$0.isEmpty }.joined(separator:"<hr>")
        }
        let template = card.noteType.flatMap { templates[$0] }
        guard CardContinuousEntry.hasFrontContent(card,template:template) else { throw CardBulkEntryError.emptyFront }
        if let issue = guidance?.validationIssues(card:card,templates:templates).first {
            throw CardBulkEntryError.required(issue.title + "：" + issue.message)
        }
        return card
    }
}

struct CardBulkEntryCandidate: Equatable, Identifiable, Sendable {
    var id = UUID()
    var line: Int
    /// HTML values, one per source column. Editing never mutates the pasted source.
    var values: [String]
}

struct CardBulkEntryPreviewItem: Identifiable, Sendable {
    var candidate: CardBulkEntryCandidate
    var card: Card?
    var issues: [String] = []
    var id: UUID { candidate.id }
}

struct CardBulkEntryPreview: Sendable {
    var configuration: CardBulkEntryConfiguration
    var candidates: [CardBulkEntryCandidate]
    var selectedIDs: Set<UUID>
    var items: [CardBulkEntryPreviewItem]
    var template: NoteTemplate?
    var canSave: Bool {
        !selectedIDs.isEmpty && items.filter { selectedIDs.contains($0.id) }.allSatisfy { $0.card != nil && $0.issues.isEmpty }
    }
}

enum CardBulkEntryError: LocalizedError {
    case parseIssues, emptyFront, changedTemplate, changedPreset, emptySelection, changedSelection, tooMany, invalidCandidate(Int,String)
    case mapping(String), required(String)
    var errorDescription: String? {
        switch self {
        case .parseIssues: return "粘贴内容还有格式问题，请按行号修正后重新拆分。原文仍保留。"
        case .emptyFront: return "请填写正面内容。"
        case .changedTemplate: return "笔记类型或字段对应已变化，请重新选择预设并检查。输入仍保留。"
        case .changedPreset: return "录入预设刚被修改或删除，请重新选择预设并检查。输入仍保留。"
        case .emptySelection: return "请至少勾选一张要保存的卡片。"
        case .changedSelection: return "候选清单已变化，请重新检查后保存。"
        case .tooMany: return "一次最多录入 \(CardBulkEntryParser.maximumCards) 张，请拆成几批。"
        case .invalidCandidate(let line,let detail): return "第 \(line) 行：\(detail) 本批尚未保存，输入仍保留。"
        case .mapping(let message), .required(let message): return message
        }
    }
}
