import Foundation
import KongReviewCore

/// A disposable answer scratchpad. This is deliberately not Codable or persisted:
/// self-assessment must never become a scheduler answer or a learning event.
struct CardSelfAnswerDraft: Equatable, Sendable {
    var text = ""
    var assessment: CardSelfAssessment?
}

enum CardSelfAssessment: String, CaseIterable, Identifiable, Sendable {
    case needsWork, partlyRemembered, remembered
    var id: String { rawValue }
    var title: String {
        switch self {
        case .needsWork: return "还需巩固"
        case .partlyRemembered: return "部分掌握"
        case .remembered: return "已掌握"
        }
    }
}

enum CardEntryLearningStatus: String, CaseIterable, Sendable {
    case suspended = "暂停", unseen = "未学", learning = "学习中", reviewed = "已复习"
    init(card: Card) {
        if card.isSuspended { self = .suspended }
        else {
            switch card.state {
            case .new: self = .unseen
            case .learning, .relearning: self = .learning
            case .review: self = .reviewed
            }
        }
    }
    /// New and suspended cards have no actionable next review time.
    func nextDue(for card: Card) -> Date? {
        self == .learning || self == .reviewed ? card.due : nil
    }
}
