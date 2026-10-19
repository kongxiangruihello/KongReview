import Foundation
import GRDB
import KongReviewCore

/// 仅保留最近一次评分；数据库中的卡片和日志必须仍与评分后相同，才能恢复。
/// 该记录仅存于当前学习会话，不进入通用编辑撤销栈。
struct CardRatingUndoToken: Sendable {
    let before: Card
    let after: Card
    let event: ReviewEvent
}

enum CardRatingUndoError: LocalizedError, Equatable {
    case cardUnavailable
    case cardChanged
    case ratingChanged

    var errorDescription: String? {
        switch self {
        case .cardUnavailable:
            return "这张记忆卡已删除或不存在，请重新进入学习。"
        case .cardChanged:
            return "这张记忆卡已经修改或再次评分，请重新进入学习后操作。"
        case .ratingChanged:
            return "这次评分记录已经改变，无法撤销。"
        }
    }
}

extension AppDatabase {
    /// 原子记录评分前后快照及对应日志。失败时卡片、日志均不改变。
    /// 使用持久化表示比较日期，避免 SQLite 毫秒精度使刚保存的卡片被误判为变更。
    func answerRecordingUndo(_ card: Card, _ answer: CardAnswer,
                             scheduler: any CardScheduling = CardScheduler(), now: Date = Date()) throws -> CardRatingUndoToken {
        try writer.write { db in
            guard let id = card.id, let before = try Card.fetchOne(db, key: id), before.deletedAt == nil else {
                throw CardRatingUndoError.cardUnavailable
            }
            guard before.databaseEquals(card) else { throw CardRatingUndoError.cardChanged }
            var after = scheduler.answer(before, answer, now: now)
            try after.update(db)
            var event = ReviewEvent(kind: .card, cardId: id, answer: answer.rawValue, at: now)
            event.cardState = before.state.rawValue
            try event.insert(db)
            // 重新读取数据库值，撤销比较使用同一精度的快照。
            guard let savedCard = try Card.fetchOne(db, key: id),
                  let savedEvent = try ReviewEvent.fetchOne(db, key: event.id) else {
                throw CardRatingUndoError.ratingChanged
            }
            return CardRatingUndoToken(before: before, after: savedCard, event: savedEvent)
        }
    }

    /// 是否仍可撤销这一次评分（不修改数据库）。
    func canUndoCardRating(_ token: CardRatingUndoToken) throws -> Bool {
        try writer.read { db in try Self.cardRatingUndoFailure(token, in: db) == nil }
    }

    /// 恢复评分前的全部卡片状态，只删除这一次的日志；期间有编辑、删除或再次评分则拒绝。
    @discardableResult
    func undoCardRating(_ token: CardRatingUndoToken) throws -> Card {
        try writer.write { db in
            if let failure = try Self.cardRatingUndoFailure(token, in: db) { throw failure }
            var restored = token.before
            try restored.update(db)
            _ = try ReviewEvent.deleteOne(db, key: token.event.id)
            return restored
        }
    }

    private static func cardRatingUndoFailure(_ token: CardRatingUndoToken, in db: Database) throws -> CardRatingUndoError? {
        guard let id = token.before.id, id == token.after.id,
              let current = try Card.fetchOne(db, key: id), current.deletedAt == nil else {
            return .cardUnavailable
        }
        guard current.databaseEquals(token.after) else { return .cardChanged }
        guard token.event.kind == .card, token.event.cardId == id,
              let answer = token.event.answer, CardAnswer(rawValue: answer) != nil,
              let eventID = token.event.id,
              let currentEvent = try ReviewEvent.fetchOne(db, key: eventID),
              currentEvent.databaseEquals(token.event) else { return .ratingChanged }
        let latestID = try Int64.fetchOne(db,
            sql: "SELECT MAX(id) FROM review_event WHERE kind = 'card' AND cardId = ?", arguments: [id])
        guard latestID == eventID else { return .ratingChanged }
        return nil
    }
}
