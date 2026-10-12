import Foundation

/// 纯 Swift 的 Zstandard 解压器（只解压，不压缩；不支持字典）。
///
/// 为什么要自己写：Anki 2.1.50 起导出的 .apkg / .colpkg 默认采用新格式，
/// 集合数据库 collection.anki21b、媒体清单与每个媒体文件都用 zstd 压缩；
/// 而 macOS 自带的 Compression 框架与 libarchive 都不支持 zstd。
/// 按 RFC 8878（Zstandard Compression and the application/zstd Media Type）实现。
public enum Zstd {

    public enum DecodeError: Error, LocalizedError, Equatable {
        case notZstd
        case corrupted(String)
        case dictionaryUnsupported
        public var errorDescription: String? {
            switch self {
            case .notZstd: return "不是 zstd 压缩数据。"
            case .corrupted(let s): return "zstd 数据损坏：\(s)"
            case .dictionaryUnsupported: return "不支持带字典的 zstd 数据。"
            }
        }
    }

    static let magic: UInt32 = 0xFD2F_B528

    /// 数据是否以 zstd 帧头开始
    public static func isZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 == magic
    }

    public static func decompress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 4)
        var pos = 0
        var sawFrame = false
        while pos + 4 <= input.count {
            let m = UInt32(input[pos]) | UInt32(input[pos + 1]) << 8 | UInt32(input[pos + 2]) << 16 | UInt32(input[pos + 3]) << 24
            if m == magic {
                sawFrame = true
                pos = try decodeFrame(input, at: pos + 4, into: &out)
            } else if m & 0xFFFF_FFF0 == 0x184D_2A50 {
                // 可跳过帧
                guard pos + 8 <= input.count else { throw DecodeError.corrupted("可跳过帧不完整") }
                let size = Int(UInt32(input[pos + 4]) | UInt32(input[pos + 5]) << 8 | UInt32(input[pos + 6]) << 16 | UInt32(input[pos + 7]) << 24)
                pos += 8 + size
            } else {
                if !sawFrame { throw DecodeError.notZstd }
                break
            }
        }
        if !sawFrame { throw DecodeError.notZstd }
        return Data(out)
    }

    // MARK: - 帧

    /// 帧内跨块共享的状态
    private struct FrameState {
        var huffman: HuffmanTable?
        var llTable: FSETable?
        var ofTable: FSETable?
        var mlTable: FSETable?
        var reps: (Int, Int, Int) = (1, 4, 8)
        var frameStart = 0
    }

    private static func decodeFrame(_ src: [UInt8], at start: Int, into out: inout [UInt8]) throws -> Int {
        var p = start
        guard p < src.count else { throw DecodeError.corrupted("帧头不完整") }
        let fhd = src[p]; p += 1
        let fcsFlag = Int(fhd >> 6)
        let singleSegment = (fhd >> 5) & 1 == 1
        let hasChecksum = (fhd >> 2) & 1 == 1
        let dictFlag = Int(fhd & 3)
        if !singleSegment { p += 1 }                      // 窗口描述符
        let dictSize = [0, 1, 2, 4][dictFlag]
        if dictSize > 0 {
            var id = 0
            for i in 0..<dictSize where p + i < src.count { id |= Int(src[p + i]) << (8 * i) }
            if id != 0 { throw DecodeError.dictionaryUnsupported }
            p += dictSize
        }
        let fcsSize = fcsFlag == 0 ? (singleSegment ? 1 : 0) : [0, 2, 4, 8][fcsFlag]
        if fcsSize > 0 {
            guard p + fcsSize <= src.count else { throw DecodeError.corrupted("帧头不完整") }
            var v = 0
            for i in 0..<fcsSize { v |= Int(src[p + i]) << (8 * i) }
            if fcsSize == 2 { v += 256 }
            if v > 0 && v < 1 << 31 { out.reserveCapacity(out.count + v) }
            p += fcsSize
        }

        var state = FrameState()
        state.frameStart = out.count
        while true {
            guard p + 3 <= src.count else { throw DecodeError.corrupted("块头不完整") }
            let h = Int(src[p]) | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16
            p += 3
            let last = h & 1 == 1
            let type = (h >> 1) & 3
            let size = h >> 3
            switch type {
            case 0:     // Raw
                guard p + size <= src.count else { throw DecodeError.corrupted("原始块越界") }
                out.append(contentsOf: src[p..<p + size])
                p += size
            case 1:     // RLE
                guard p < src.count else { throw DecodeError.corrupted("RLE 块越界") }
                out.append(contentsOf: repeatElement(src[p], count: size))
                p += 1
            case 2:     // Compressed
                guard p + size <= src.count else { throw DecodeError.corrupted("压缩块越界") }
                try decodeCompressedBlock(src, p, p + size, &state, &out)
                p += size
            default:
                throw DecodeError.corrupted("保留的块类型")
            }
            if last { break }
        }
        if hasChecksum { p += 4 }
        return p
    }

    // MARK: - 压缩块

    private static func decodeCompressedBlock(_ src: [UInt8], _ start: Int, _ end: Int,
                                              _ st: inout FrameState, _ out: inout [UInt8]) throws {
        var p = start
        // 1. 字面量
        let literals = try decodeLiterals(src, &p, end, &st)

        // 2. 序列数
        guard p < end else { throw DecodeError.corrupted("缺少序列段") }
        let b0 = Int(src[p])
        var nbSeq = 0
        if b0 == 0 {
            p += 1
        } else if b0 < 128 {
            nbSeq = b0; p += 1
        } else if b0 < 255 {
            guard p + 1 < end else { throw DecodeError.corrupted("序列数不完整") }
            nbSeq = ((b0 - 128) << 8) + Int(src[p + 1]); p += 2
        } else {
            guard p + 2 < end else { throw DecodeError.corrupted("序列数不完整") }
            nbSeq = Int(src[p + 1]) + (Int(src[p + 2]) << 8) + 0x7F00; p += 3
        }
        if nbSeq == 0 {
            out.append(contentsOf: literals)
            return
        }

        // 3. 三张 FSE 表
        guard p < end else { throw DecodeError.corrupted("缺少压缩模式") }
        let modes = src[p]; p += 1
        st.llTable = try readTable(mode: Int(modes >> 6), src, &p, end, previous: st.llTable,
                                   predefined: Tables.llDefault, maxLog: 9, maxSymbol: 35)
        st.ofTable = try readTable(mode: Int((modes >> 4) & 3), src, &p, end, previous: st.ofTable,
                                   predefined: Tables.ofDefault, maxLog: 8, maxSymbol: 31)
        st.mlTable = try readTable(mode: Int((modes >> 2) & 3), src, &p, end, previous: st.mlTable,
                                   predefined: Tables.mlDefault, maxLog: 9, maxSymbol: 52)
        guard let ll = st.llTable, let of = st.ofTable, let ml = st.mlTable else {
            throw DecodeError.corrupted("缺少 FSE 表")
        }

        // 4. 逆向比特流解序列并执行
        var br = try BackwardBits(src, p, end)
        var llState = br.read(ll.log)
        var ofState = br.read(of.log)
        var mlState = br.read(ml.log)
        var litPos = 0
        var reps = st.reps

        for i in 0..<nbSeq {
            let ofCode = Int(of.symbol[ofState])
            let llCode = Int(ll.symbol[llState])
            let mlCode = Int(ml.symbol[mlState])
            guard llCode < Tables.llBase.count, mlCode < Tables.mlBase.count, ofCode <= 31 else {
                throw DecodeError.corrupted("序列代码越界")
            }
            let offsetValue = (1 << ofCode) + br.read(ofCode)
            let matchLength = Tables.mlBase[mlCode] + br.read(Tables.mlBits[mlCode])
            let litLength = Tables.llBase[llCode] + br.read(Tables.llBits[llCode])

            // 重复偏移（RFC 8878 §3.1.1.5）
            var offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                reps = (offset, reps.0, reps.1)
            } else {
                let idx = offsetValue - 1 + (litLength == 0 ? 1 : 0)
                switch idx {
                case 0: offset = reps.0
                case 1: offset = reps.1; reps = (reps.1, reps.0, reps.2)
                case 2: offset = reps.2; reps = (reps.2, reps.0, reps.1)
                default: offset = reps.0 - 1; reps = (offset, reps.0, reps.1)
                }
            }

            guard litPos + litLength <= literals.count else { throw DecodeError.corrupted("字面量不足") }
            out.append(contentsOf: literals[litPos..<litPos + litLength])
            litPos += litLength

            guard offset > 0, offset <= out.count - st.frameStart else { throw DecodeError.corrupted("匹配偏移越界") }
            // 逐字节复制（不能用 out[from..<…] 切片追加：切片持有缓冲区，会触发整块复制）
            let from = out.count - offset
            for k in 0..<matchLength { out.append(out[from + k]) }

            if i < nbSeq - 1 {
                llState = Int(ll.baseline[llState]) + br.read(Int(ll.nbBits[llState]))
                mlState = Int(ml.baseline[mlState]) + br.read(Int(ml.nbBits[mlState]))
                ofState = Int(of.baseline[ofState]) + br.read(Int(of.nbBits[ofState]))
            }
        }
        st.reps = reps
        if litPos < literals.count { out.append(contentsOf: literals[litPos...]) }
    }

    private static func readTable(mode: Int, _ src: [UInt8], _ p: inout Int, _ end: Int,
                                  previous: FSETable?, predefined: [Int], maxLog: Int, maxSymbol: Int) throws -> FSETable {
        switch mode {
        case 0:
            switch maxSymbol {
            case 35: return Tables.llTable
            case 31: return Tables.ofTable
            default: return Tables.mlTable
            }
        case 1:
            guard p < end else { throw DecodeError.corrupted("RLE 符号缺失") }
            let s = src[p]; p += 1
            return FSETable(rle: s)
        case 2:
            let (probs, log, used) = try readProbabilities(src, p, end, maxSymbol: maxSymbol, maxLog: maxLog)
            p += used
            return FSETable(probabilities: probs, log: log)
        default:
            guard let previous else { throw DecodeError.corrupted("重复模式但没有上一张表") }
            return previous
        }
    }

    // MARK: - 字面量段

    private static func decodeLiterals(_ src: [UInt8], _ p: inout Int, _ end: Int, _ st: inout FrameState) throws -> [UInt8] {
        guard p < end else { throw DecodeError.corrupted("缺少字面量段") }
        let b0 = Int(src[p])
        let type = b0 & 3
        let sizeFormat = (b0 >> 2) & 3
        func byte(_ i: Int) throws -> Int {
            guard p + i < end else { throw DecodeError.corrupted("字面量头不完整") }
            return Int(src[p + i])
        }

        if type == 0 || type == 1 {
            var regen: Int
            switch sizeFormat {
            case 0, 2: regen = b0 >> 3; p += 1
            case 1: regen = (b0 >> 4) + (try byte(1) << 4); p += 2
            default: regen = (b0 >> 4) + (try byte(1) << 4) + (try byte(2) << 12); p += 3
            }
            if type == 0 {
                guard p + regen <= end else { throw DecodeError.corrupted("原始字面量越界") }
                let lit = Array(src[p..<p + regen])
                p += regen
                return lit
            } else {
                guard p < end else { throw DecodeError.corrupted("RLE 字面量缺失") }
                let b = src[p]; p += 1
                return [UInt8](repeating: b, count: regen)
            }
        }

        // 压缩 / 复用表
        let streams: Int
        let headerSize: Int
        let bits: Int
        switch sizeFormat {
        case 0: streams = 1; headerSize = 3; bits = 10
        case 1: streams = 4; headerSize = 3; bits = 10
        case 2: streams = 4; headerSize = 4; bits = 14
        default: streams = 4; headerSize = 5; bits = 18
        }
        var hv = 0
        for i in 0..<headerSize { hv |= try byte(i) << (8 * i) }
        let mask = (1 << bits) - 1
        let regen = (hv >> 4) & mask
        let compSize = (hv >> (4 + bits)) & mask
        p += headerSize
        guard p + compSize <= end else { throw DecodeError.corrupted("压缩字面量越界") }
        var q = p
        let blockEnd = p + compSize
        p = blockEnd

        if type == 2 {
            st.huffman = try readHuffmanTable(src, &q, blockEnd)
        }
        guard let table = st.huffman else { throw DecodeError.corrupted("复用的霍夫曼表不存在") }

        var out = [UInt8]()
        out.reserveCapacity(regen)
        if streams == 1 {
            try decodeHuffmanStream(table, src, q, blockEnd, count: regen, into: &out)
        } else {
            guard q + 6 <= blockEnd else { throw DecodeError.corrupted("跳转表不完整") }
            let s1 = Int(src[q]) | Int(src[q + 1]) << 8
            let s2 = Int(src[q + 2]) | Int(src[q + 3]) << 8
            let s3 = Int(src[q + 4]) | Int(src[q + 5]) << 8
            q += 6
            let seg = (regen + 3) / 4
            let starts = [q, q + s1, q + s1 + s2, q + s1 + s2 + s3, blockEnd]
            guard starts[3] <= blockEnd else { throw DecodeError.corrupted("跳转表越界") }
            for k in 0..<4 {
                let n = k < 3 ? seg : regen - 3 * seg
                guard n >= 0 else { throw DecodeError.corrupted("字面量长度不对") }
                try decodeHuffmanStream(table, src, starts[k], starts[k + 1], count: n, into: &out)
            }
        }
        guard out.count == regen else { throw DecodeError.corrupted("字面量长度不符") }
        return out
    }

    // MARK: - 霍夫曼

    struct HuffmanTable {
        var maxBits: Int
        var symbol: [UInt8]
        var nbBits: [UInt8]
    }

    private static func readHuffmanTable(_ src: [UInt8], _ p: inout Int, _ end: Int) throws -> HuffmanTable {
        guard p < end else { throw DecodeError.corrupted("霍夫曼表头缺失") }
        let header = Int(src[p]); p += 1
        var weights: [Int] = []
        if header >= 128 {
            let n = header - 127
            let bytes = (n + 1) / 2
            guard p + bytes <= end else { throw DecodeError.corrupted("霍夫曼权重越界") }
            for i in 0..<n {
                let b = Int(src[p + i / 2])
                weights.append(i % 2 == 0 ? b >> 4 : b & 15)
            }
            p += bytes
        } else {
            let compEnd = p + header
            guard compEnd <= end else { throw DecodeError.corrupted("霍夫曼权重越界") }
            let (probs, log, used) = try readProbabilities(src, p, compEnd, maxSymbol: 255, maxLog: 6)
            let table = FSETable(probabilities: probs, log: log)
            var br = try BackwardBits(src, p + used, compEnd)
            var s1 = br.read(log)
            var s2 = br.read(log)
            while weights.count < 255 {
                weights.append(Int(table.symbol[s1]))
                s1 = Int(table.baseline[s1]) + br.read(Int(table.nbBits[s1]))
                if br.overflowed { weights.append(Int(table.symbol[s2])); break }
                weights.append(Int(table.symbol[s2]))
                s2 = Int(table.baseline[s2]) + br.read(Int(table.nbBits[s2]))
                if br.overflowed { weights.append(Int(table.symbol[s1])); break }
            }
            p = compEnd
        }

        // 补出最后一个符号的权重
        var total = 0
        for w in weights where w > 0 { total += 1 << (w - 1) }
        guard total > 0 else { throw DecodeError.corrupted("霍夫曼权重全为 0") }
        let maxBits = highBit(total) + 1
        let rest = (1 << maxBits) - total
        guard rest > 0, rest & (rest - 1) == 0 else { throw DecodeError.corrupted("霍夫曼权重不成立") }
        weights.append(highBit(rest) + 1)
        guard maxBits <= 11 else { throw DecodeError.corrupted("霍夫曼码过长") }

        let size = 1 << maxBits
        var symbol = [UInt8](repeating: 0, count: size)
        var nb = [UInt8](repeating: 0, count: size)
        var pos = 0
        for w in 1...maxBits {
            for (s, sw) in weights.enumerated() where sw == w {
                let span = 1 << (w - 1)
                let bitsLen = UInt8(maxBits + 1 - w)
                guard pos + span <= size else { throw DecodeError.corrupted("霍夫曼表溢出") }
                for k in pos..<pos + span { symbol[k] = UInt8(s); nb[k] = bitsLen }
                pos += span
            }
        }
        return HuffmanTable(maxBits: maxBits, symbol: symbol, nbBits: nb)
    }

    private static func decodeHuffmanStream(_ t: HuffmanTable, _ src: [UInt8], _ start: Int, _ end: Int,
                                            count: Int, into out: inout [UInt8]) throws {
        if count == 0 { return }
        var br = try BackwardBits(src, start, end)
        for _ in 0..<count {
            let v = br.peek(t.maxBits)
            out.append(t.symbol[v])
            br.skip(Int(t.nbBits[v]))
        }
        if br.position < 0 { throw DecodeError.corrupted("霍夫曼流读过头") }
    }

    // MARK: - FSE

    struct FSETable {
        var log: Int
        var symbol: [UInt8]
        var nbBits: [UInt8]
        var baseline: [UInt16]

        init(rle s: UInt8) {
            log = 0; symbol = [s]; nbBits = [0]; baseline = [0]
        }

        init(probabilities: [Int], log: Int) {
            self.log = log
            let size = 1 << log
            var sym = [UInt8](repeating: 0, count: size)
            var high = size - 1
            var next = [Int](repeating: 0, count: probabilities.count)
            for (s, pr) in probabilities.enumerated() {
                if pr == -1 {
                    sym[high] = UInt8(s); high -= 1; next[s] = 1
                } else {
                    next[s] = pr
                }
            }
            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var position = 0
            for (s, pr) in probabilities.enumerated() where pr > 0 {
                for _ in 0..<pr {
                    sym[position] = UInt8(s)
                    repeat { position = (position + step) & mask } while position > high
                }
            }
            var nb = [UInt8](repeating: 0, count: size)
            var base = [UInt16](repeating: 0, count: size)
            for u in 0..<size {
                let s = Int(sym[u])
                let n = next[s]
                next[s] += 1
                let bits = log - highBit(n)
                nb[u] = UInt8(bits)
                base[u] = UInt16((n << bits) - size)
            }
            symbol = sym; nbBits = nb; baseline = base
        }
    }

    /// 读 FSE 表描述（正向、低位在前）。返回概率、精度与用掉的字节数。
    private static func readProbabilities(_ src: [UInt8], _ start: Int, _ end: Int,
                                          maxSymbol: Int, maxLog: Int) throws -> ([Int], Int, Int) {
        var bitPos = 0
        func peek(_ n: Int) -> Int {
            var v = 0
            for i in 0..<n {
                let b = bitPos + i
                let idx = start + b >> 3
                if idx < end, (src[idx] >> UInt8(b & 7)) & 1 == 1 { v |= 1 << i }
            }
            return v
        }
        let log = peek(4) + 5
        bitPos += 4
        guard log <= maxLog else { throw DecodeError.corrupted("FSE 精度过高") }
        var remaining = (1 << log) + 1
        var threshold = 1 << log
        var nbBits = log + 1
        var probs: [Int] = []
        while remaining > 1 && probs.count <= maxSymbol {
            let maxV = (2 * threshold - 1) - remaining
            var count: Int
            let low = peek(nbBits - 1)
            if low < maxV {
                count = low
                bitPos += nbBits - 1
            } else {
                count = peek(nbBits)
                if count >= threshold { count -= maxV }
                bitPos += nbBits
            }
            count -= 1
            remaining -= count < 0 ? -count : count
            probs.append(count)
            if count == 0 {
                while true {
                    let r = peek(2)
                    bitPos += 2
                    for _ in 0..<r { probs.append(0) }
                    if r != 3 { break }
                }
            }
            while remaining < threshold { nbBits -= 1; threshold >>= 1 }
            guard start + (bitPos >> 3) <= end else { throw DecodeError.corrupted("FSE 表描述越界") }
        }
        guard remaining == 1, probs.count <= maxSymbol + 1 else { throw DecodeError.corrupted("FSE 概率之和不对") }
        return (probs, log, (bitPos + 7) >> 3)
    }

    // MARK: - 逆向比特流

    struct BackwardBits {
        let src: [UInt8]
        let start: Int
        let end: Int
        /// 剩余比特数；读过头后为负（按 0 补位）
        var position: Int

        init(_ src: [UInt8], _ start: Int, _ end: Int) throws {
            guard end > start, src[end - 1] != 0 else { throw DecodeError.corrupted("比特流缺少结束标记") }
            self.src = src
            self.start = start
            self.end = end
            position = (end - start - 1) * 8 + highBit(Int(src[end - 1]))
        }

        var overflowed: Bool { position < 0 }

        /// 取 [from, from+n) 这些比特（from ≥ 0）
        private func bits(from: Int, count n: Int) -> Int {
            if n == 0 { return 0 }
            var v: UInt64 = 0
            let first = from >> 3
            let last = (from + n - 1) >> 3
            var shift: UInt64 = 0
            for i in first...last {
                let idx = start + i
                if idx < end { v |= UInt64(src[idx]) << shift }
                shift += 8
            }
            v >>= UInt64(from & 7)
            return Int(v & ((1 << UInt64(n)) - 1))
        }

        func peek(_ n: Int) -> Int {
            if n == 0 { return 0 }
            let from = position - n
            if from >= 0 { return bits(from: from, count: n) }
            let avail = max(0, position)
            return bits(from: 0, count: avail) << (n - avail)
        }

        mutating func skip(_ n: Int) { position -= n }

        mutating func read(_ n: Int) -> Int {
            let v = peek(n)
            position -= n
            return v
        }
    }

    static func highBit(_ v: Int) -> Int {
        v <= 0 ? -1 : (Int.bitWidth - 1 - v.leadingZeroBitCount)
    }

    // MARK: - 预定义表（RFC 8878 §3.1.1.3.2.2）

    enum Tables {
        static let llDefault = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
                                2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
        static let mlDefault = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
                                -1, -1, -1, -1, -1]
        static let ofDefault = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                -1, -1, -1, -1, -1]

        static let llTable = FSETable(probabilities: llDefault, log: 6)
        static let mlTable = FSETable(probabilities: mlDefault, log: 6)
        static let ofTable = FSETable(probabilities: ofDefault, log: 5)

        static let llBase: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512,
                                                    1024, 2048, 4096, 8192, 16384, 32768, 65536]
        static let llBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9,
                                                                     10, 11, 12, 13, 14, 15, 16]
        static let mlBase: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515,
                                                    1027, 2051, 4099, 8195, 16387, 32771, 65539]
        static let mlBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9,
                                                                     10, 11, 12, 13, 14, 15, 16]
    }
}
