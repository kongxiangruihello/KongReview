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
        // 6.3.4：补考、新录、卡片屡错的摘录三类排在最前的，合计至多占每日条数的一半，其余留给平常的加权抽样
        let priorityRoom = Self.examPriorityCap(dailyCount)
        // 多取几条再筛：排在前面的若不在今天的候选里（如出处的回顾权重为 0），不让它白占名额
        let retests = try Array(db.examRetestHighlightIDs(now: now, limit: min(priorityRoom, AppDatabase.examRetestPerDay) + 20)
            .filter { byID[$0] != nil }.prefix(min(priorityRoom, AppDatabase.examRetestPerDay)))
        // 6.0.8：新录的摘录排在补考之后（录进来的第二天起第 1 次，隔两天第 2 次）
        let freshRoom = min(ExamFresh.perDay(), max(0, priorityRoom - retests.count))
        let fresh = ((try? db.examFreshCandidates(now: now, limit: freshRoom + retests.count + 20)) ?? [])
            .filter { byID[$0.id] != nil && !retests.contains($0.id) }.prefix(freshRoom)
        let early = Set(retests + fresh.map(\.id))
        let refresh = bias.refresh.compactMap { byID[$0.id] }.filter { !early.contains($0.id ?? -1) }
            .prefix(max(0, priorityRoom - early.count))
        let first = retests + fresh.map(\.id) + refresh.compactMap(\.id)
        ExamFresh.Session(day: today, rounds: Dictionary(fresh.map { ($0.id, $0.round) }, uniquingKeysWith: { a, _ in a }),
                          priority: first.count).save()
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

    /// 6.3.4：排在最前的三类（补考、新录、卡片屡错的摘录）合计至多占每日条数的一半
    nonisolated static func examPriorityCap(_ dailyCount: Int) -> Int { max(0, dailyCount / 2) }

    /// 6.3.4：还在等的补考与新录（含今天日课上还没答的），显示在日课页头
    func examBacklog(now: Date = Date()) -> (retests: Int, fresh: Int) {
        ((try? db.examRetestBacklog(now: now)) ?? 0, ExamFresh.perDay() > 0 ? ((try? db.examFreshBacklog(now: now)) ?? 0) : 0)
    }

    /// 此刻卷子上还没答的题
    func examPaper(now: Date = Date()) -> ExamPaperState {
        var paper = ExamPaperState()
        if let record = try? todayReviewSession(now: now) {
            let ids = record.regularIds + record.masteryIds
            let rest = Array(ids.dropFirst(min(ids.count, max(0, record.position))))
            let found = (try? db.highlights(ids: rest)) ?? []
            let byID = Dictionary(found.compactMap { h in h.id.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
            // 6.3.4：今天在别处弃置了的不再出题（与课末再练一致）
            paper.highlights = rest.compactMap { byID[$0] }.filter { $0.deletedAt == nil && !$0.isDiscarded }
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
            if let card = paper.nextCard, let cap = budget.cap(.card), ((try? db.cardsRatedToday(now: now)) ?? 0) >= cap {
                // 6.3.4：题数满了不再出新的卡；答了“重来”、还在学习中的卡照旧回来，不留到明天
                let pending = todayCardPending
                paper.nextCard = Self.isLearning(card) ? card : examNextCard(now: now, learningOnly: true)
                paper.deferred += max(0, pending.total - pending.learning)
            }
        }
        return paper
    }

    /// 全部牌组里下一张到期的卡（各牌组与全库的每日上限照旧）
    func examNextCard(now: Date = Date(), learningOnly: Bool = false) -> Card? {
        guard let ledger = try? db.dailyLimitLedger(now: now, limits: CardSettings.limits(now: now)) else { return nil }
        let cards = (try? db.cards()) ?? []
        return StudyQueue.next(from: learningOnly ? cards.filter(Self.isLearning) : cards, now: now, left: ledger.left)
    }

    /// 学习中（答过、还没毕业）的卡
    nonisolated static func isLearning(_ card: Card) -> Bool { card.state == .learning || card.state == .relearning }

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
    /// 6.2：记下这道题写出了几处要点与自己判的分（只作统计）
    func examRecordCalibration(_ kind: CalibrationKind, recordId: Int64, match: IdeaUnitMatch, result: SelfTestResult, now: Date = Date()) {
        guard !fullBackupBusy else { return }
        do { try db.recordCalibration(kind: kind, recordId: recordId, match: match, result: result, now: now) }
        catch { report(error) }
    }

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
        checkDayChange()   // 6.3.4：过了零点接着答，先换到新的一天（与记忆卡、摘录、解答题一致）
        do {
            try db.recordExamResult(kind: .argument, recordId: note.id, result: result, now: now)
        } catch { report(error); return }
        if result == .forgot { examRelearnAdd(.note, note.id) }
        if !reviewedToday { reviewedToday = true; onReviewedToday?() }
        revisitNote(note.id, outcome)
    }

    /// 复述题：需重读的，今天卷尾再考
    func examAnswerBlock(_ block: RevisitBlockItem, _ outcome: RevisitOutcome) {
        guard !fullBackupBusy else { return }
        checkDayChange()
        if outcome == .reread { examRelearnAdd(.block, block.id) }
        revisitBlock(block.id, outcome)
    }

    /// 交卷：今天的成绩单显示在卷面下方（还有没答的题也可以先交；之后仍可接着答）
    var examHandedIn: Bool {
        get { UserDefaults.standard.string(forKey: Self.examHandedInKey) == today }
        set {
            UserDefaults.standard.set(newValue ? today : "", forKey: Self.examHandedInKey)
            // 6.3.4：收工算不算打卡的条件，要重算今天的检查
            refreshDailyCheck()
        }
    }
}

// MARK: - 6.2：做题时随手记

/// 今日试卷上当前这道题：随手记摘录时沿用的出处、记札记时挂上的摘录
struct ExamCaptureContext: Equatable {
    /// 面板上显示“记于 ……”
    var label = ""
    var highlight: Highlight?
    var source: Source?
}

extension LibraryStore {
    func examCaptureContext(_ q: ExamQuestion?) -> ExamCaptureContext {
        guard let q else { return ExamCaptureContext(label: "今日日课") }
        func short(_ s: String) -> String {
            let t = Markdown.plainText(fromHTML: Markdown.richHTML(s)).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 24 ? String(t.prefix(24)) + "…" : t
        }
        switch q {
        case .highlight(let h, _):
            return ExamCaptureContext(label: "今日日课 · 摘录“\(short(h.text))”", highlight: h, source: source(for: h))
        case .card(let c):
            let h = c.highlightId.flatMap { id in (try? db.highlights(ids: [id]))?.first { $0.deletedAt == nil } }
            return ExamCaptureContext(label: "今日日课 · 记忆卡“\(short(c.front))”", highlight: h, source: h.flatMap { source(for: $0) })
        case .note(let n):
            return ExamCaptureContext(label: "今日日课 · 札记《\(n.title)》")
        case .block(let b):
            return ExamCaptureContext(label: "今日日课 · 笔记《\(b.notebookTitle)》")
        case .question(let item):
            return ExamCaptureContext(label: "今日日课 · 问题“\(short(item.title))”")
        case .answer(let a):
            return ExamCaptureContext(label: "今日日课 · 问题“\(short(a.title))”")
        }
    }

    /// 随手记一条摘录：快速录入浮窗，出处沿用这道题的（可改），正文取剪贴板里新复制的
    func examCaptureHighlight(_ ctx: ExamCaptureContext) {
        guard !fullBackupBusy else { return }
        if let s = ctx.source {
            QuickCaptureController.shared.show(prefill: CaptureRequest(text: "", title: s.title, author: s.author), useClipboard: true)
        } else {
            QuickCaptureController.shared.show()
        }
    }

    /// 随手写一条札记：随手札记浮窗，挂上这道题的摘录（可改为加入已有札记）
    static func examNoteComposer(_ ctx: ExamCaptureContext) -> IdeaNoteComposer {
        var c = ideaNoteComposer(highlight: ctx.highlight)
        c.context = ctx.label
        return c
    }
}
