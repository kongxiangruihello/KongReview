import Foundation
import GRDB
import KongReviewCore

// MARK: - 4.2.0：书目状态与读书进度

/// 编辑进度面板（读法、页码、总页数、百分比、已读篇目、计划日期、为什么要读）
struct ReadingEditRequest: Identifiable, Sendable {
    var id = UUID()
    var sourceId: Int64
}

/// 首页“在读”的一本
struct CurrentRead: Identifiable, Sendable {
    var source: Source
    var reading: SourceReading
    var id: Int64 { reading.sourceId }
}

/// 记一笔面板
struct ReadingLogRequest: Identifiable, Sendable {
    var id = UUID()
    var sourceId: Int64?
}

extension LibraryStore {
    /// 书架上的全部状态（出处管理、项目页、书页头、首页都从这里取）
    func refreshReadings() {
        readings = (try? db.readingStatuses()) ?? [:]
        readingRevision += 1
    }

    var readingCount: Int { readings.values.filter { $0.status == .reading }.count }

    private func afterReadingChange() {
        refreshReadings()
        revisionBump()
    }

    func setReadingStatus(_ sourceId: Int64, _ status: SourceReading.Status?) {
        guard !fullBackupBusy else { return }
        do {
            try db.setReadingStatus(sourceId: sourceId, status)
            afterReadingChange()
        } catch { report(error) }
    }

    func addToShelf(_ sourceIds: [Int64], status: SourceReading.Status = .want) {
        guard !fullBackupBusy else { return }
        do {
            for id in sourceIds where readings[id] == nil { try db.setReadingStatus(sourceId: id, status) }
            afterReadingChange()
        } catch { report(error) }
    }

    @discardableResult
    func saveReading(_ r: SourceReading) -> Bool {
        guard !fullBackupBusy else { return false }
        do { try db.saveReading(r); afterReadingChange(); return true } catch { report(error); return false }
    }

    @discardableResult
    func logReading(sourceId: Int64, day: Date, fromPage: Int?, toPage: Int?, minutes: Int?, note: String) -> Bool {
        guard !fullBackupBusy else { return false }
        do {
            try db.logReading(sourceId: sourceId, day: day, fromPage: fromPage, toPage: toPage, minutes: minutes, note: note)
            afterReadingChange()
            return true
        } catch { report(error); return false }
    }

    /// 首页“今天读了”：不填页码，只记下今天读过（读书天数据此统计）
    func markReadToday(_ sourceId: Int64) {
        logReading(sourceId: sourceId, day: Date(), fromPage: nil, toPage: nil, minutes: nil, note: "")
    }

    func deleteReadingLog(_ id: Int64) {
        guard !fullBackupBusy else { return }
        do { try db.deleteReadingLog(id: id); afterReadingChange() } catch { report(error) }
    }

    /// 首页“在读”：最近读过的在前，最多 limit 本
    func currentReads(limit: Int = 3) -> [CurrentRead] {
        _ = readingRevision
        let lastDays = (try? db.writer.read { db in
            try Dictionary(Row.fetchAll(db, sql: "SELECT sourceId, MAX(day) AS d FROM reading_log GROUP BY sourceId")
                .map { ($0["sourceId"] as Int64, $0["d"] as String) }, uniquingKeysWith: { a, _ in a })
        }) ?? [:]
        return readings.values.filter { $0.status == .reading }
            .compactMap { r in sources.first { $0.id == r.sourceId }.map { CurrentRead(source: $0, reading: r) } }
            .sorted { (lastDays[$0.reading.sourceId] ?? "", $0.reading.updatedAt) > (lastDays[$1.reading.sourceId] ?? "", $1.reading.updatedAt) }
            .prefix(limit).map { $0 }
    }
}
