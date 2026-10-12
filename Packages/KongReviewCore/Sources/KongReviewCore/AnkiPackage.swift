import Foundation

/// Anki 牌组包（.apkg / .colpkg）里与格式有关的小工具。
///
/// 新格式（Anki 2.1.50 起默认）：
/// - collection.anki21b：zstd 压缩的 SQLite 集合（schema 18：笔记类型、牌组改为独立的表）
/// - media：zstd 压缩的 protobuf 清单 MediaEntries { repeated MediaEntry entries = 1; }，
///   MediaEntry { string name = 1; uint32 size = 2; bytes sha1 = 3; optional uint32 legacy_zip_filename = 255; }
/// - 0、1、2…：各媒体文件，按清单顺序编号，也是 zstd 压缩
/// 旧格式：collection.anki2 / collection.anki21 为普通 SQLite，media 为 JSON {"0": "a.jpg"}，媒体文件不压缩。
public enum AnkiPackage {

    /// 解析媒体清单，返回 [包内文件名: 原始文件名]
    public static func mediaMap(_ data: Data) -> [String: String] {
        let raw = Zstd.isZstd(data) ? ((try? Zstd.decompress(data)) ?? Data()) : data
        if let first = raw.first, first == UInt8(ascii: "{"),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: String] {
            return obj
        }
        var map: [String: String] = [:]
        let bytes = [UInt8](raw)
        var p = 0
        var index = 0
        while p < bytes.count {
            guard let (field, wire) = readTag(bytes, &p) else { break }
            if field == 1 && wire == 2, let len = readVarint(bytes, &p), p + Int(len) <= bytes.count {
                let entry = Array(bytes[p..<p + Int(len)])
                p += Int(len)
                var name: String?
                var zipName: Int?
                var q = 0
                while q < entry.count {
                    guard let (f, w) = readTag(entry, &q) else { break }
                    if w == 2, let l = readVarint(entry, &q), q + Int(l) <= entry.count {
                        if f == 1 { name = String(decoding: entry[q..<q + Int(l)], as: UTF8.self) }
                        q += Int(l)
                    } else if w == 0, let v = readVarint(entry, &q) {
                        if f == 255 { zipName = Int(v) }
                    } else if !skip(entry, &q, wire: w) {
                        break
                    }
                }
                if let name { map[String(zipName ?? index)] = name }
                index += 1
            } else if !skip(bytes, &p, wire: wire) {
                break
            }
        }
        return map
    }

    /// 笔记内容里引用到的媒体文件名（<img src>、[sound:]）
    public static func mediaReferences(in html: String) -> Set<String> {
        var out = Set<String>()
        let patterns = [#"(?i)\bsrc\s*=\s*"([^"]+)""#, #"(?i)\bsrc\s*=\s*'([^']+)'"#, #"\[sound:([^\]]+)\]"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                out.insert(name)
                if let decoded = name.removingPercentEncoding { out.insert(decoded) }
            }
        }
        return out
    }

    /// 新格式 decks.kind（protobuf）：Normal 牌组 { config_id = 1 } 在字段 1 里
    public static func deckConfigID(fromKind data: Data) -> Int64? {
        let b = [UInt8](data)
        var p = 0
        while p < b.count {
            guard let (f, w) = readTag(b, &p) else { return nil }
            if f == 1 && w == 2, let len = readVarint(b, &p), p + Int(len) <= b.count {
                let inner = Array(b[p..<p + Int(len)])
                var q = 0
                while q < inner.count {
                    guard let (f2, w2) = readTag(inner, &q) else { return nil }
                    if f2 == 1 && w2 == 0 { return readVarint(inner, &q).map { Int64($0) } }
                    if !skip(inner, &q, wire: w2) { return nil }
                }
                return nil
            }
            if !skip(b, &p, wire: w) { return nil }
        }
        return nil
    }

    /// 新格式 deck_config.config（protobuf DeckConfig.Config）：
    /// 字段 9 每日新卡、10 每日复习上限（varint），37 期望保留率（float）
    public static func deckConfig(fromProto data: Data) -> (newPerDay: Int?, reviewsPerDay: Int?, desiredRetention: Double?) {
        let b = [UInt8](data)
        var p = 0
        var new: Int?, rev: Int?, ret: Double?
        while p < b.count {
            guard let (f, w) = readTag(b, &p) else { break }
            if w == 0, let v = readVarint(b, &p) {
                if f == 9 { new = Int(v) } else if f == 10 { rev = Int(v) }
            } else if w == 5 {
                guard p + 4 <= b.count else { break }
                let bits = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
                if f == 37 { ret = (Double(Float(bitPattern: bits)) * 1000).rounded() / 1000 }
                p += 4
            } else if !skip(b, &p, wire: w) {
                break
            }
        }
        return (new, rev, ret)
    }

    // MARK: protobuf 线格式

    static func readVarint(_ b: [UInt8], _ p: inout Int) -> UInt64? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while p < b.count && shift < 64 {
            let byte = b[p]; p += 1
            v |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return v }
            shift += 7
        }
        return nil
    }

    static func readTag(_ b: [UInt8], _ p: inout Int) -> (Int, Int)? {
        guard let t = readVarint(b, &p) else { return nil }
        return (Int(t >> 3), Int(t & 7))
    }

    static func skip(_ b: [UInt8], _ p: inout Int, wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint(b, &p) != nil
        case 1: p += 8; return p <= b.count
        case 2:
            guard let l = readVarint(b, &p) else { return false }
            p += Int(l); return p <= b.count
        case 5: p += 4; return p <= b.count
        default: return false
        }
    }
}
