import Foundation
import KongReviewCore

/// A standalone, data-only format. It intentionally contains no cards, learning state,
/// executable template markup, note-type definitions or deck-to-preset bindings.
enum CardEntryPresetTransfer {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumPresetCount = 100
    private struct Document: Codable {
        var format = "KongReview.entry-presets"
        var version = 1
        var presets: [CardEntryPreset]
    }

    static func encode(_ presets: [CardEntryPreset]) throws -> Data {
        guard !presets.isEmpty, presets.count <= maximumPresetCount else { throw CardEntryPresetTransferError.invalidCount }
        for preset in presets { try checkLimits(preset) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(presets: presets.map(\.cleaned)))
        guard data.count <= maximumBytes else { throw CardEntryPresetTransferError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> [CardEntryPreset] {
        guard data.count <= maximumBytes else { throw CardEntryPresetTransferError.tooLarge }
        do {
            // Reject unrelated backup/card files instead of silently ignoring their content.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["format", "version", "presets"]),
                  let rows = object["presets"] as? [[String: Any]] else { throw CardEntryPresetTransferError.invalidFile }
            let presetKeys: Set<String> = ["id", "name", "deck", "tags", "sections", "noteType", "fieldNames", "frontRule", "backRule", "fieldRules"]
            for row in rows {
                guard Set(row.keys).isSubset(of: presetKeys) else { throw CardEntryPresetTransferError.invalidFile }
                if let sections = row["sections"] as? [[String: Any]] {
                    for section in sections {
                        guard Set(section.keys).isSubset(of: ["id", "name", "folded", "rule"]) else { throw CardEntryPresetTransferError.invalidFile }
                        try checkRuleKeys(section["rule"])
                    }
                }
                try checkRuleKeys(row["frontRule"])
                try checkRuleKeys(row["backRule"])
                if let rules = row["fieldRules"] as? [Any] { for rule in rules { try checkRuleKeys(rule) } }
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.format == "KongReview.entry-presets", document.version == 1 else { throw CardEntryPresetTransferError.unsupportedVersion }
            guard !document.presets.isEmpty, document.presets.count <= maximumPresetCount else { throw CardEntryPresetTransferError.invalidCount }
            for preset in document.presets { try checkLimits(preset) }
            return document.presets.map(\.cleaned)
        } catch let error as CardEntryPresetTransferError { throw error }
        catch { throw CardEntryPresetTransferError.invalidFile }
    }

    static func read(from url: URL) throws -> [CardEntryPreset] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CardEntryPresetTransferError.invalidFile }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw CardEntryPresetTransferError.tooLarge }
        return try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func suggestedCopyName(_ name: String, existingNames: [String]) -> String {
        let stem = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "录入预设"
        func occupied(_ value: String) -> Bool { existingNames.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
        let first = stem + " 副本"
        if !occupied(first) { return first }
        var index = 2
        while occupied("\(first) \(index)") { index += 1 }
        return "\(first) \(index)"
    }

    static func checkLimits(_ preset: CardEntryPreset) throws {
        let strings = [preset.name, preset.deck, preset.noteType ?? ""] + preset.tags + preset.fieldNames + preset.sections.map(\.name)
        let rules = [preset.frontRule, preset.backRule].compactMap { $0 } + (preset.fieldRules ?? []) + preset.sections.compactMap(\.rule)
        guard preset.sections.count <= 100, preset.fieldNames.count <= 100, preset.tags.count <= 100,
              strings.allSatisfy({ $0.utf8.count <= 4_096 }), rules.count <= 202,
              rules.allSatisfy({ $0.hint.utf8.count <= 16_384 && ($0.html ?? "").utf8.count <= 65_536 }) else { throw CardEntryPresetTransferError.tooComplex }
    }

    private static func checkRuleKeys(_ object: Any?) throws {
        guard let object, !(object is NSNull) else { return }
        guard let rule = object as? [String: Any], Set(rule.keys).isSubset(of: ["hint", "required", "html"]) else {
            throw CardEntryPresetTransferError.invalidFile
        }
    }
}

enum CardEntryPresetTransferError: LocalizedError, Equatable {
    case invalidFile, unsupportedVersion, invalidCount, tooLarge, tooComplex
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "这不是有效的 KongReview 录入模板 JSON 文件；卡片、备份和其他内容不能作为模板导入。"
        case .unsupportedVersion: return "此文件的模板格式或版本不受支持，请使用兼容版本导出。"
        case .invalidCount: return "每次请选择 1 至 100 个录入模板。"
        case .tooLarge: return "模板文件超过 2 MB，请分批导出后再导入。"
        case .tooComplex: return "模板的栏目、字段、标签或说明过多，请简化后再导入。"
        }
    }
}
