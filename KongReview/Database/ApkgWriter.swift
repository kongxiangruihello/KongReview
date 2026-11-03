import Foundation
import GRDB
import KongReviewCore

/// 把记忆卡导出成 Anki 牌组包（.apkg，旧版 schema 11 格式，Anki 桌面版、AnkiMobile、AnkiDroid 都能导入）。
///
/// 包内结构与 Anki 自己“支持旧版 Anki”导出的一致：collection.anki21（SQLite）+ media（JSON 清单）+ 0、1、2…（媒体文件）。
/// 每张卡导出为一条“KongReview”类型的笔记（字段：正面、背面），内容是卡片当前实际显示的正反面
/// （多字段卡片按模板拼好；Markdown 转成 HTML）。表结构与 JSON 字段参照 Anki 26.09 导出的旧版包。
enum ApkgWriter {
    struct Report: Equatable {
        var cards = 0
        var media = 0
        var revlog = 0
        var decks: [String] = []
    }

    /// 固定的笔记类型 id，重复导出时 Anki 认得是同一个类型
    static let modelID: Int64 = 1_735_000_000_001

    /// 生成包内文件到 folder（之后再打成 zip）
    static func writeFolder(cards: [Card], templates: [String: NoteTemplate], media: (String) -> Data?,
                            history: [Int64: [ReviewEvent]], includeScheduling: Bool,
                            fsrsParameters: [Double]?, desiredRetention: Double,
                            newPerDay: Int, reviewsPerDay: Int,
                            to folder: URL, now: Date = Date()) throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("collection.anki21")
        try? fm.removeItem(at: dbURL)
        let queue = try DatabaseQueue(path: dbURL.path)
        var report = Report()

        let nowSec = Int64(now.timeIntervalSince1970)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // 集合创建时间取今天凌晨 4 点前的那个“天”的开始：复习卡的 due 以它为第 0 天
        let crtDate = Calendar.current.startOfDay(for: now.addingTimeInterval(-4 * 3600)).addingTimeInterval(4 * 3600)
        let crt = Int64(crtDate.timeIntervalSince1970)
        let today = Int((now.timeIntervalSince(crtDate) / 86_400).rounded(.down))

        // 牌组（含上级牌组）→ 稳定的 id
        var deckNames = Set<String>()
        for c in cards {
            let parts = c.deck.components(separatedBy: "::")
            for i in 1...parts.count { deckNames.insert(parts[0..<i].joined(separator: "::")) }
        }
        let deckIDs = Dictionary(uniqueKeysWithValues: deckNames.map { ($0, stableID($0)) })
        report.decks = deckNames.sorted()

        try queue.write { db in
            try db.execute(sql: schema)
            try db.execute(sql: """
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')
                """, arguments: [crt, nowMs, nowMs,
                                 json(conf(fsrs: fsrsParameters != nil)),
                                 json([String(modelID): model(now: nowSec)]),
                                 json(decks(deckIDs, now: nowSec)),
                                 json(["1": dconf(newPerDay: newPerDay, reviewsPerDay: reviewsPerDay,
                                                  fsrs: fsrsParameters, retention: desiredRetention)])])

            var usedIDs = Set<Int64>()
            func uniqueID(_ base: Int64) -> Int64 {
                var id = base
                while usedIDs.contains(id) { id += 1 }
                usedIDs.insert(id)
                return id
            }

            for (i, c) in cards.enumerated() {
                let template = c.noteType.flatMap { templates[$0] }
                let faces = c.faces(using: template)
                // 6.0.0：HTML 模板的样式随正面一起带到 Anki
                let css = template?.css.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let front = (css.isEmpty ? "" : "<style>\(css)</style>") + Markdown.html(faces.front)
                let back = Markdown.html(faces.back)
                let nid = uniqueID(nowMs + Int64(i))
                let guid = c.ankiGuid ?? "kr\(c.id ?? Int64(i))"
                let sortText = Markdown.plainText(fromHTML: front)
                let csum = Int64(SHA1.hex(Data(sortText.utf8)).prefix(8), radix: 16) ?? 0
                let tags = c.tags.isEmpty ? "" : " " + c.tags.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: " ") + " "
                try db.execute(sql: """
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')
                    """, arguments: [nid, guid, modelID, nowSec, tags, front + "\u{1f}" + back, sortText, csum])

                // 调度
                var type = 0, queueValue = 0, due = i + 1, ivl = 0, factor = 0, reps = 0, lapses = 0
                var data = "{}"
                if includeScheduling && c.state != .new {
                    type = 2; queueValue = 2
                    ivl = max(1, Int(c.interval.rounded()))
                    let dueDay = Int((c.due.timeIntervalSince(crtDate) / 86_400).rounded(.down))
                    due = c.state == .review ? dueDay : min(dueDay, today)
                    factor = Int((c.ease * 1000).rounded())
                    reps = c.reps; lapses = c.lapses
                    if let s = c.stability, let d = c.difficulty {
                        data = String(format: #"{"s":%.4f,"d":%.4f,"dr":%.2f}"#, s, d, desiredRetention)
                    }
                }
                if c.isSuspended { queueValue = -1 }
                let cid = nid
                try db.execute(sql: """
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses,
                                       left, odue, odid, flags, data)
                    VALUES (?, ?, ?, 0, ?, -1, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?)
                    """, arguments: [cid, nid, deckIDs[c.deck] ?? 1, nowSec, type, queueValue, due, ivl, factor,
                                     reps, lapses, data])
                report.cards += 1

                if includeScheduling, let id = c.id {
                    for e in history[id] ?? [] where (1...4).contains(e.answer ?? 0) {
                        let rid = uniqueID(Int64(e.at.timeIntervalSince1970 * 1000))
                        try db.execute(sql: """
                            INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
                            VALUES (?, ?, -1, ?, 0, 0, 0, 0, 1)
                            """, arguments: [rid, cid, e.answer ?? 3])
                        report.revlog += 1
                    }
                }
            }
        }

        // 媒体：只带卡片里用到的
        var used = Set<String>()
        for c in cards {
            let faces = c.faces(using: c.noteType.flatMap { templates[$0] })
            used.formUnion(AnkiPackage.mediaReferences(in: faces.front))
            used.formUnion(AnkiPackage.mediaReferences(in: faces.back))
        }
        var index: [String: String] = [:]
        for (n, name) in used.sorted().enumerated() {
            guard let d = media(name) else { continue }
            try d.write(to: folder.appendingPathComponent(String(n)))
            index[String(n)] = name
        }
        report.media = index.count
        try Data(json(index).utf8).write(to: folder.appendingPathComponent("media"))
        return report
    }

    /// 把 folder 里的文件打成 zip（.apkg）
    static func zip(folder: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = folder
        p.arguments = ["-q", "-X", output.path] + names
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "KongReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "打包 .apkg 失败（zip 退出码 \(p.terminationStatus)）。"])
        }
    }

    // MARK: - 结构

    static let schema = """
        CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL,
          ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL,
          models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL);
        CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL,
          usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL,
          flags integer NOT NULL, data text NOT NULL);
        CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL,
          mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL,
          ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL,
          odue integer NOT NULL, odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
        CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL,
          ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL);
        CREATE TABLE graves (usn integer NOT NULL, oid integer NOT NULL, type integer NOT NULL);
        CREATE INDEX ix_notes_usn ON notes (usn);
        CREATE INDEX ix_cards_usn ON cards (usn);
        CREATE INDEX ix_revlog_usn ON revlog (usn);
        CREATE INDEX ix_cards_nid ON cards (nid);
        CREATE INDEX ix_cards_sched ON cards (did, queue, due);
        CREATE INDEX ix_revlog_cid ON revlog (cid);
        CREATE INDEX ix_notes_csum ON notes (csum);
        """

    static func stableID(_ name: String) -> Int64 {
        // FNV-1a，落在 1.6e12–1.7e12 之间（看起来像毫秒时间戳，Anki 不在乎具体值）
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return 1_600_000_000_000 + Int64(h % 100_000_000_000)
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func conf(fsrs: Bool) -> [String: Any] {
        ["activeDecks": [1], "curDeck": 1, "newSpread": 0, "collapseTime": 1200, "timeLim": 0, "estTimes": true,
         "dueCounts": true, "curModel": modelID, "nextPos": 1, "sortType": "noteFld", "sortBackwards": false,
         "addToCur": true, "dayLearnFirst": false, "schedVer": 2, "sched2021": true, "fsrs": fsrs]
    }

    static func model(now: Int64) -> [String: Any] {
        func field(_ name: String, _ ord: Int) -> [String: Any] {
            ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": [] as [Any],
             "description": "", "plainText": false, "collapsed": false, "excludeFromSearch": false]
        }
        return [
            "id": modelID, "name": "KongReview", "type": 0, "mod": now, "usn": -1, "sortf": 0, "did": NSNull(),
            "tmpls": [["name": "卡片 1", "ord": 0, "qfmt": "{{正面}}",
                       "afmt": "{{FrontSide}}\n\n<hr id=answer>\n\n{{背面}}",
                       "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0] as [String: Any]],
            "flds": [field("正面", 0), field("背面", 1)],
            "css": """
                .card { font-family: -apple-system, "PingFang SC", "Songti SC", serif; font-size: 20px; line-height: 1.7;
                        text-align: left; color: black; background-color: white; }
                .card.nightMode { color: #eee; background-color: #2c2c2c; }
                .kr-label { font-size: 13px; color: #888; margin-top: 12px; }
                details.kr-field { margin-top: 12px; } details.kr-field summary { color: #888; font-size: 14px; cursor: pointer; }
                #answer ~ .kr-field + .kr-field { margin-top: 16px; padding-top: 12px; border-top: 1px dashed rgba(128,128,128,.4); }
                .cloze { font-weight: bold; color: #2f6fe4; }
                img { max-width: 100%; }
                """,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}", "latexsvg": false,
            "req": [[0, "any", [0]] as [Any]], "tags": [] as [Any], "vers": [] as [Any],
        ]
    }

    static func decks(_ ids: [String: Int64], now: Int64) -> [String: Any] {
        func deck(_ id: Int64, _ name: String) -> [String: Any] {
            ["id": id, "mod": now, "name": name, "usn": -1, "lrnToday": [0, 0], "revToday": [0, 0], "newToday": [0, 0],
             "timeToday": [0, 0], "collapsed": false, "browserCollapsed": false, "desc": "", "dyn": 0, "conf": 1,
             "extendNew": 0, "extendRev": 0]
        }
        var out: [String: Any] = ["1": deck(1, "Default")]
        for (name, id) in ids { out[String(id)] = deck(id, name) }
        return out
    }

    static func dconf(newPerDay: Int, reviewsPerDay: Int, fsrs: [Double]?, retention: Double) -> [String: Any] {
        [
            "id": 1, "mod": 0, "name": "Default", "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true,
            "new": ["bury": false, "delays": [1.0, 10.0], "initialFactor": 2500, "ints": [1, 4, 0], "order": 1, "perDay": newPerDay] as [String: Any],
            "rev": ["bury": false, "ease4": 1.3, "ivlFct": 1.0, "maxIvl": 36500, "perDay": reviewsPerDay, "hardFactor": 1.2] as [String: Any],
            "lapse": ["delays": [10.0], "leechAction": 1, "leechFails": 8, "minInt": 1, "mult": 0.0] as [String: Any],
            "dyn": false, "newMix": 0, "newPerDayMinimum": 0, "interdayLearningMix": 0, "reviewOrder": 0,
            "newSortOrder": 0, "newGatherPriority": 0, "buryInterdayLearning": false,
            "fsrsWeights": [] as [Double], "fsrsParams5": [] as [Double], "fsrsParams6": fsrs ?? [],
            "desiredRetention": retention, "sm2Retention": 0.9,
        ]
    }
}
