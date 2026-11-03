import Foundation
import KongReviewCore

// MARK: - 6.0.3：今日试卷——组卷与作答

/// 卷面上的一道题
enum ExamQuestion: Equatable {
    case card(Card)
    case highlight(Highlight, ExamHighlightMode)
    case note(RevisitNoteItem)
    case block(RevisitBlockItem)
    case question(RevisitQuestionItem)
    /// 6.0.9：解答题（已解决的问题）
    case answer(RevisitAnswerItem)

    var kind: ExamKind {
        switch self {
        case .card: .card
        case .highlight: .highlight
        case .note: .note
        case .block: .block
        case .question, .answer: .question
        }
    }

    /// 换了一道题才重置卷面（展开、我的回答）
    var key: String {
        switch self {
        case .card(let c): "c\(c.id ?? 0)-\(c.reps)-\(c.lapses)-\(c.due.timeIntervalSince1970)"
        case .highlight(let h, _): "h\(h.id ?? 0)"
        case .note(let n): "n\(n.id)"
        case .block(let b): "k\(b.id)"
        case .question(let q): "q\(q.id)"
        case .answer(let a): "a\(a.id)-\(a.reviewCount)"
        }
    }
}

/// 此刻卷子上还没答的题：摘录按今天抽好的顺序，札记、笔记、问题取重温队列，记忆卡取下一张到期卡
struct ExamPaperState: Equatable {
    var highlights: [Highlight] = []
    var revisit = RevisitQueue.empty
    var nextCard: Card?
    /// 6.0.7：设了每天的时长、今天顺延到明天的题数
    var deferred = 0

    var available: Set<ExamKind> {
        var s = Set<ExamKind>()
        if nextCard != nil { s.insert(.card) }
        if !highlights.isEmpty { s.insert(.highlight) }
        if !revisit.notes.isEmpty { s.insert(.note) }
        if !revisit.blocks.isEmpty { s.insert(.block) }
        if !revisit.questions.isEmpty || !revisit.answers.isEmpty { s.insert(.question) }
        return s
    }

    func question(_ kind: ExamKind, day: Date) -> ExamQuestion? {
        switch kind {
        case .card: nextCard.map { .card($0) }
        case .highlight: highlights.first.map { .highlight($0, ExamHighlightMode.pick(for: $0, day: day)) }
        case .note: revisit.notes.first.map { .note($0) }
        case .block: revisit.blocks.first.map { .block($0) }
        // 6.0.9：先出进展题，再出解答题
        case .question: revisit.questions.first.map { .question($0) } ?? revisit.answers.first.map { .answer($0) }
        }
    }
}

extension LibraryStore {
    static let examHandedInKey = "exam.handedIn"

    func openExam() {
        checkDayChange()
        refreshDerived()
        refreshRevisit()
        selection = .dailyCheck
    }

    /// 今天的摘录：沿用当天已抽好的一组（今日回顾的同一组与进度）；还没抽就按每天的加权抽样抽一组，
    /// 忘了的摘录（补考）排在最前、占每日条数的名额
    func todayReviewSession(now: Date = Date()) throws -> ReviewSessionRecord {
        let key = ReviewSessionRecord.key(theme: nil)
        let today = ReviewSessionRecord.dayString(now)
        if let saved = ReviewSessionRecord.load(key: key), saved.day == today { return saved }
        let dailyCount = max(0, UserDefaults.standard.object(forKey: SettingsKeys.dailyCount) as? Int ?? 10)
        let scheduler = ReviewScheduler(config: .init(dailyCount: dailyCount, masteryLimit: 0))
        let (highlights, weights) = try db.reviewCandidates(tag: nil)
        let bias = (try? db.reviewBias(focus: learningFocus)) ?? ReviewBias()
        let byID = Dictionary(highlights.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
        let retests = try db.examRetestHighlightIDs(now: now, limit: min(Self.examRetestCap(dailyCount), AppDatabase.examRetestPerDay))
            .filter { byID[$0] != nil }
        // 6.0.8：新录的摘录排在补考之后（录进来的第二天起第 1 次，隔两天第 2 次）
        let freshRoom = min(ExamFresh.perDay(), max(0, dailyCount - retests.count))
        let fresh = ((try? db.examFreshCandidates(now: now, limit: freshRoom + retests.count)) ?? [])
            .filter { byID[$0.id] != nil && !retests.contains($0.id) }.prefix(freshRoom)
        ExamFresh.Session(day: today, rounds: Dictionary(fresh.map { ($0.id, $0.round) }, uniquingKeysWith: { a, _ in a })).save()
        let early = Set(retests + fresh.map(\.id))
        let refresh = bias.refresh.compactMap { byID[$0.id] }.filter { !early.contains($0.id ?? -1) }
        let first = retests + fresh.map(\.id) + refresh.compactMap(\.id)
        let taken = Set(first)
        let pool = highlights.filter { !taken.contains($0.id ?? -1) }
        var rng = SeededGenerator.forDay(now)
        let session = scheduler.makeSession(highlights: pool, sourceWeights: weights, multipliers: bias.multipliers, now: now, using: &rng)
        let regular = session.all.prefix(max(0, dailyCount - first.count)).compactMap(\.id)
        let record = ReviewSessionRecord(day: today, regularIds: Array((first + regular).prefix(max(dailyCount, first.count))), masteryIds: [], position: 0)
        record.save(key: key)
        return record
    }

    /// 6.0.8：这条摘录今天是不是新录的第几次考（不是新录为 nil）
    func examFreshRound(_ id: Int64?, now: Date = Date()) -> Int? {
        guard let id, let s = ExamFresh.Session.load(), s.day == ReviewSessionRecord.dayString(now) else { return nil }
        return s.rounds[id]
    }

    /// 补考至多占每日条数的一半
    nonisolated static func examRetestCap(_ dailyCount: Int) -> Int { max(0, dailyCount / 2) }

    /// 此刻卷子上还没答的题
    func examPaper(now: Date = Date()) -> ExamPaperState {
        var paper = ExamPaperState()
        if let record = try? todayReviewSession(now: now) {
            let ids = record.regularIds + record.masteryIds
            let rest = Array(ids.dropFirst(min(ids.count, max(0, record.position))))
            let found = (try? db.highlights(ids: rest)) ?? []
            let byID = Dictionary(found.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
            paper.highlights = rest.compactMap { byID[$0] }.filter { $0.deletedAt == nil }
        }
        paper.revisit = (try? db.revisitQueue(now: now)) ?? .empty
        paper.nextCard = examNextCard(now: now)
        // 6.0.7：设了每天的时长，各类只出分到的题数，其余顺延到明天
        if let budget = examBudget(now: now) {
            func trim<T>(_ list: [T], _ kind: ExamKind, done: Int) -> [T] {
                let allowed = max(0, (budget.cap(kind) ?? list.count + done) - done)
                paper.deferred += max(0, list.count - allowed)
                return Array(list.prefix(allowed))
            }
            let position = (try? todayReviewSession(now: now))?.position ?? 0
            paper.highlights = trim(paper.highlights, .highlight, done: position)
            paper.revisit.notes = trim(paper.revisit.notes, .note, done: paper.revisit.notesDone)
            paper.revisit.blocks = trim(paper.revisit.blocks, .block, done: paper.revisit.blocksDone)
            let asked = paper.revisit.questionsDone + paper.revisit.answersDone
            paper.revisit.questions = trim(paper.revisit.questions, .question, done: asked)
            paper.revisit.answers = trim(paper.revisit.answers, .question, done: asked + paper.revisit.questions.count)
            if paper.nextCard != nil, let cap = budget.cap(.card), ((try? db.cardsRatedToday(now: now)) ?? 0) >= cap {
                paper.nextCard = nil
                paper.deferred += todayCardPending.total
            }
        }
        return paper
    }

    /// 全部牌组里下一张到期的卡（各牌组与全库的每日上限照旧）
    func examNextCard(now: Date = Date()) -> Card? {
        guard let ledger = try? db.dailyLimitLedger(now: now, limits: CardSettings.limits(now: now)) else { return nil }
        let cards = (try? db.cards()) ?? []
        return StudyQueue.next(from: cards, now: now, left: ledger.left)
    }

    // MARK: 作答

    /// 记忆卡：与牌组学习同一套评分与排程
    func examAnswerCard(_ card: Card, _ answer: CardAnswer) {
        guard !fullBackupBusy else { return }
        checkDayChange()
        do {
            _ = try db.answerRecordingUndo(card, answer, scheduler: scheduler(forDeck: card.deck))
            if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        } catch { report(error); return }
        revisionBump()
        refreshDerived()
    }

    /// 摘录：记下记得 / 大致 / 忘了；记得时可同时收藏或弃置。摘录记为“看过”，今天这一组往后推一条
    func examAnswerHighlight(_ h: Highlight, mode: ExamHighlightMode, result: SelfTestResult,
                             action: ReviewScheduler.Action = .keep, now: Date = Date()) {
        guard !fullBackupBusy, let id = h.id else { return }
        checkDayChange()
        do {
            try db.recordExamResult(kind: mode == .source ? .source : .gist, recordId: id, result: result, now: now)
        } catch { report(error); return }
        // 6.0.7：忘了的，今天卷尾再考
        if result == .forgot, action != .discard { examRelearnAdd(.highlight, id) }
        let kind: ReviewEvent.Kind = action == .favorite ? .favorite : action == .discard ? .discard : .keep
        logReview(kind, highlightId: id)
        let scheduler = ReviewScheduler(config: .init(dailyCount: 10, masteryLimit: 0))
        save(scheduler.apply(action, to: h, now: now))
        advanceTodayReview(past: id, now: now)
    }

    /// 今日这一组的进度推到这一条之后（与今日回顾共用一组、一个进度）
    func advanceTodayReview(past id: Int64, now: Date = Date()) {
        let key = ReviewSessionRecord.key(theme: nil)
        guard var record = ReviewSessionRecord.load(key: key), record.day == ReviewSessionRecord.dayString(now) else { return }
        var ids = record.regularIds
        if let i = ids.firstIndex(of: id) {
            if i >= record.position {
                // 答的若不在当前位置（如作答时顺序变了），挪到已答部分的末尾
                ids.remove(at: i)
                ids.insert(id, at: min(record.position, ids.count))
                record.regularIds = ids
                record.position += 1
            }
        }
        record.save(key: key)
        review.sessionToken += 1
        refreshDerived()
        StatusItemController.shared.updateCounts()
    }

    /// 6.0.9：解答题——记得 / 大致 / 忘了（计入掌握度），忘了的当天卷尾再考
    func examAnswerQuestionAnswer(_ item: RevisitAnswerItem, result: SelfTestResult, now: Date = Date()) {
        guard !fullBackupBusy else { return }
        checkDayChange()
        do {
            try db.recordAnswerReview(questionId: item.id, result: result, now: now)
        } catch { report(error); return }
        if result == .forgot { examRelearnAdd(.answer, item.id) }
        if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        refreshRevisit()
    }

    /// 札记：先记“记得 / 大致 / 忘了”（计入掌握度），再按“还这么看吗”排下次
    func examAnswerNote(_ note: RevisitNoteItem, result: SelfTestResult, outcome: RevisitOutcome, now: Date = Date()) {
        guard !fullBackupBusy else { return }
        do {
            try db.recordExamResult(kind: .argument, recordId: note.id, result: result, now: now)
        } catch { report(error); return }
        if result == .forgot { examRelearnAdd(.note, note.id) }
        if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        revisitNote(note.id, outcome)
    }

    /// 复述题：需重读的，今天卷尾再考
    func examAnswerBlock(_ block: RevisitBlockItem, _ outcome: RevisitOutcome) {
        if outcome == .reread { examRelearnAdd(.block, block.id) }
        revisitBlock(block.id, outcome)
    }

    /// 交卷：今天的成绩单显示在卷面下方（还有没答的题也可以先交；之后仍可接着答）
    var examHandedIn: Bool {
        get { UserDefaults.standard.string(forKey: Self.examHandedInKey) == today }
        set { UserDefaults.standard.set(newValue ? today : "", forKey: Self.examHandedInKey); dailyCheckRevision += 1 }
    }
}
