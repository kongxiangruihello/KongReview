import Foundation
import GRDB

/// 3.4 的专题问题（存于 app_progress）。4.1.1 起迁入问题簿，只在迁移时读取。
struct TopicQuestion: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var notebookID: Int64
    var question = ""
    var answer = ""
    var evidence: PlanEvidence?
    var createdAt = Date()
    var updatedAt = Date()
    var solvedAt: Date?
    var key: String { "topic-question.\(id.uuidString)" }
}
/// 3.4 的专题问题草稿，4.1.1 迁移时转为 QuestionDraft
struct TopicQuestionDraft: Codable, Equatable, Identifiable, Sendable {
    var value: TopicQuestion
    var original: TopicQuestion?
    var id: UUID { value.id }
    var key: String { "question-draft.\(id.uuidString)" }
}
