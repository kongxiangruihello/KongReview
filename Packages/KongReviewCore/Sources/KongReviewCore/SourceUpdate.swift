import Foundation

// MARK: - 6.0.2：点一下就更新（仿 KongSeek）
//
// 不再依赖 GitHub Releases：应用在本机的源码文件夹（~/Developer/KongReview）里取 GitHub 上 main 分支的最新代码，
// 先跑测试，再编译、签名、备份学习库与当前版本，最后换上新版并重新打开。这里是其中不碰系统的部分：
// 读编译输出算进度、读 README 里的版本说明、读 project.yml 里的版本号、确定给 git 用的代理。

/// 跟着 Tools/build-app.sh --test 的输出一行行走，算出“测试：已通过 52 / 790 项”这样的说明与总进度。
/// 写法沿用 KongSeek 的 BuildLogProgress；KongReview 先测核心包、再测应用，两段测试的条数累计。
public struct BuildLogProgress: Equatable, Sendable {
    public enum Stage: Int, Comparable, Sendable {
        case starting, buildingTests, runningTests, compiling, packaging, finished
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public private(set) var stage = Stage.starting
    /// 本阶段内的进度，0…1
    public private(set) var fraction: Double = 0
    public private(set) var detail = "准备中…"
    /// 已跑完的测试（两段累计）
    public private(set) var testsRun = 0
    public private(set) var failedTests: [String] = []
    /// “AppUpdater.swift 第 286 行：……”
    public private(set) var compileErrors: [String] = []
    /// “V601SlimTests.swift 第 53 行：XCTAssertEqual failed ……”
    public private(set) var testFailures: [String] = []
    /// 测试进程崩溃（Fatal error、unexpected signal）
    public private(set) var testsCrashed = false
    /// 预计的测试条数（上一次的实数）
    public var expectedTests: Int
    /// 6.3.1：编译新版本预计几秒。编译 KongReview 本身是一整步（整模块优化），约一分钟里几乎没有输出，
    /// 按“[n/m]”算进度会停在一处不动；有了这个数就按已用的时间推进
    public var expectedCompileSeconds: Double?
    /// expectedCompileSeconds 是上一次实测的（否则是估计值，说明里写“一般约”）
    public var compileEstimateIsLast: Bool
    /// 这份源码在本机测过，没有再测（6.3）
    public private(set) var testsSkipped = false
    /// 这份源码在本机编译过，直接用编好的程序（6.3.1）
    public private(set) var compileReused = false
    /// 开始编译新版本的时刻
    public private(set) var compileStarted: Date?
    /// 这次编译新版本用了几秒（编译段结束时记下；用编好的程序时为 nil）
    public private(set) var compileSeconds: Double?
    /// 编译时最近一行“[n/m]”，如“（10 / 40）”
    private var counterText = ""

    public init(expectedTests: Int = 790, expectedCompileSeconds: Double? = nil, compileEstimateIsLast: Bool = true) {
        self.expectedTests = max(1, expectedTests)
        self.expectedCompileSeconds = expectedCompileSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.compileEstimateIsLast = compileEstimateIsLast
    }

    /// 整个构建的进度，0…1（各阶段按大致用时加权）。
    /// 测试照跑时，测试约占四成；测过而跳过时，几乎整段都是编译（6.3.1：原先跳过测试后编译一开始就显示过半，再停在八成上下）
    public var overall: Double {
        let spans: [Stage: (Double, Double)] = testsSkipped ? [
            .starting: (0, 0.02), .buildingTests: (0.02, 0.04), .runningTests: (0.04, 0.06),
            .compiling: (0.06, 0.94), .packaging: (0.94, 1), .finished: (1, 1),
        ] : [
            .starting: (0, 0.02), .buildingTests: (0.02, 0.40), .runningTests: (0.40, 0.55),
            .compiling: (0.55, 0.93), .packaging: (0.93, 1), .finished: (1, 1),
        ]
        let (start, end) = spans[stage]!
        return start + (end - start) * min(1, max(0, fraction))
    }

    /// swift build 的“[3/20]”可能用回车分隔；按 \r 或 \n 切开的每一段都当作一行传进来
    public mutating func consume(_ rawLine: String, now: Date = Date()) {
        let line = Self.plain(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if let failure = Self.testFailure(line) {
            if !failedTests.contains(failure.test) { failedTests.append(failure.test) }
            if testFailures.count < 20 { testFailures.append(failure.message) }
            return
        }
        if line.contains("Fatal error:") || line.contains("exited with unexpected signal") {
            if stage >= .buildingTests && stage <= .runningTests { testsCrashed = true }
        }
        if let error = Self.compileError(line) {
            if !compileErrors.contains(error) && compileErrors.count < 20 { compileErrors.append(error) }
            return
        }
        if line.hasPrefix("== tests ==") {
            advance(to: .buildingTests, "正在编译测试…")
        } else if line.contains("已在本机用同一版 Swift 测过") {
            // 6.3：这份源码在本机测过，build-app.sh 不再测
            advance(to: .runningTests, "这份源码已在本机测过、全部通过，不再测一遍")
            testsSkipped = true
            fraction = 1
        } else if line.hasPrefix("Test Suite 'All tests' started") {
            advance(to: .runningTests, "正在运行测试…")
        } else if line.hasPrefix("Test Case '"), line.contains("' passed") || line.contains("' failed") {
            if stage < .runningTests { advance(to: .runningTests, "") }
            testsRun += 1
            if line.contains("' failed"), let name = Self.testName(line), !failedTests.contains(name) { failedTests.append(name) }
            let total = max(expectedTests, testsRun)
            fraction = min(0.99, Double(testsRun) / Double(total))
            detail = "测试：已通过 \(testsRun - failedTests.count) / \(total) 项" + (failedTests.isEmpty ? "" : "，\(failedTests.count) 项未通过")
        } else if line.hasPrefix("== compile ==") {
            advance(to: .compiling, "正在编译新版本…", now: now)
            if compileStarted == nil { compileStarted = now }
            if let expected = expectedCompileSeconds { detail = "正在编译新版本（\(Self.estimate(expected, last: compileEstimateIsLast))）…" }
        } else if line.contains("已在本机编译过") {
            // 6.3.1：同一份源码在本机编译过（多半是合并前在本机测试时编的），build-app.sh 直接用编好的程序
            if stage == .compiling {
                compileReused = true
                fraction = 1
                detail = "这份源码已在本机编译过，直接用编好的程序"
            }
        } else if line.hasPrefix("== icon ==") || line.hasPrefix("== sign ==") {
            advance(to: .packaging, line.hasPrefix("== sign ==") ? "正在签名…" : "正在打包…", now: now)
        } else if line.hasPrefix("Built: ") {
            advance(to: .finished, "编译完成", now: now)
        } else if let counter = Self.stepCounter(line), stage == .buildingTests || stage == .runningTests || stage == .compiling {
            // 核心包测完再编译应用的测试：这时仍在“编译测试”，进度条不后退
            if stage == .runningTests { return }
            if stage == .compiling {
                counterText = "（\(counter.done) / \(counter.total)）"
                // 有预计用时就按时间走（见 tick），“[n/m]”只记下来
                if expectedCompileSeconds != nil { return }
            }
            fraction = max(fraction, Double(counter.done) / Double(max(1, counter.total)))
            detail = (stage == .buildingTests ? "正在编译测试" : "正在编译新版本") + "（\(counter.done) / \(counter.total)）"
        }
    }

    /// 6.3.1：编译新版本时每秒调一次——按已用时间推进进度，说明里写已用几秒
    public mutating func tick(now: Date = Date()) {
        guard stage == .compiling, !compileReused, let start = compileStarted else { return }
        let elapsed = max(0, now.timeIntervalSince(start))
        let seconds = Int(elapsed.rounded())
        if let expected = expectedCompileSeconds {
            // 到预计用时的 97% 为止；超过预计时停在那里，等编译结束
            fraction = max(fraction, min(0.97, elapsed / expected))
            let estimate = Self.estimate(expected, last: compileEstimateIsLast)
            detail = elapsed <= expected
                ? "正在编译新版本：已用 \(seconds) 秒（\(estimate)）"
                : "正在编译新版本：已用 \(seconds) 秒，比\(compileEstimateIsLast ? "上次" : "一般")久一些，请稍候"
        } else {
            detail = "正在编译新版本\(counterText)：已用 \(seconds) 秒"
        }
    }

    /// “上次用了约 68 秒”或“一般约 70 秒”
    static func estimate(_ seconds: Double, last: Bool) -> String {
        (last ? "上次用了约 " : "一般约 ") + "\(Int(seconds.rounded())) 秒"
    }

    private mutating func advance(to next: Stage, _ text: String, now: Date = Date()) {
        guard next >= stage else { return }
        if next > stage {
            if stage == .compiling, !compileReused, let start = compileStarted {
                compileSeconds = max(0, now.timeIntervalSince(start))
            }
            fraction = 0
        }
        stage = next
        if !text.isEmpty { detail = text }
    }

    /// 去掉终端颜色与超链接（ESC [ … m，ESC ] 8 ; ; … ESC \\）
    static func plain(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else { result.unicodeScalars.append(scalar); continue }
            guard let kind = scalars.next() else { break }
            if kind == "[" {
                while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
            } else if kind == "]" {
                while let next = scalars.next() {
                    if next == "\u{07}" { break }
                    if next == "\u{1B}" { _ = scalars.next(); break }
                }
            }
        }
        return result
    }

    /// “/…/AppUpdater.swift:286:24: error: …” → “AppUpdater.swift 第 286 行：…”
    static func compileError(_ line: String) -> String? {
        guard let marker = line.range(of: ": error: "), !line[marker.upperBound...].hasPrefix("-[") else { return nil }
        let location = line[..<marker.lowerBound].split(separator: ":")
        guard location.count >= 2, location[0].hasSuffix(".swift"), let lineNumber = Int(location[1]) else { return nil }
        let file = (String(location[0]) as NSString).lastPathComponent
        var message = String(line[marker.upperBound...])
        if let link = message.range(of: " [#") { message = String(message[..<link.lowerBound]) }
        return "\(file) 第 \(lineNumber) 行：\(message)"
    }

    /// “/…/V601SlimTests.swift:53: error: -[KongReviewTests.V601SlimTests testX] : XCTAssertEqual failed: …”
    /// → （“V601SlimTests testX”，“V601SlimTests.swift 第 53 行：XCTAssertEqual failed: …”）
    static func testFailure(_ line: String) -> (test: String, message: String)? {
        guard let marker = line.range(of: ": error: -["), let close = line.range(of: "] : ", range: marker.upperBound..<line.endIndex) else { return nil }
        let location = line[..<marker.lowerBound].split(separator: ":")
        guard location.count >= 2, let number = Int(location[1]) else { return nil }
        let full = line[marker.upperBound..<close.lowerBound]
        let test = String(full.split(separator: ".").last ?? full)
        let file = (String(location[0]) as NSString).lastPathComponent
        return (test, "\(file) 第 \(number) 行：" + String(line[close.upperBound...]))
    }

    /// “[12 / 40] Compiling …”或“[12/40] …”
    static func stepCounter(_ line: String) -> (done: Int, total: Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0, done <= total else { return nil }
        return (done, total)
    }

    /// “Test Case '-[Module.SuiteTests testName]' failed (…)” → “SuiteTests testName”
    static func testName(_ line: String) -> String? {
        guard let open = line.range(of: "-["), let close = line.range(of: "]'", range: open.upperBound..<line.endIndex) else { return nil }
        let full = line[open.upperBound..<close.lowerBound]
        return String(full.split(separator: ".").last ?? full)
    }
}

/// 更新说明：GitHub 上的版本号与 README 里比本机新的各节
public enum ReleaseNotes {
    public struct Section: Equatable, Sendable {
        public var version: String
        public var title: String
        public var body: String
    }

    /// project.yml 里的 MARKETING_VERSION: "6.0.2"
    public static func version(inProjectYML text: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.contains("MARKETING_VERSION") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if AppVersion(value) != nil { return value }
        }
        return nil
    }

    /// README 里“## 6.0.2 标题”这样的各节，版本比 installed 新的，新的在前；最多 limit 节
    public static func sections(in readme: String, newerThan installed: String, limit: Int = 8) -> [Section] {
        let base = AppVersion(installed)
        var result: [Section] = []
        var current: (version: String, title: String, lines: [String])?
        func finish() {
            guard let c = current, let v = AppVersion(c.version) else { return }
            if base.map({ v > $0 }) ?? true {
                result.append(Section(version: c.version, title: c.title,
                                      body: c.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in readme.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                finish()
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let version = String(heading.prefix { $0.isNumber || $0 == "." })
                if version.contains("."), AppVersion(version) != nil {
                    current = (version, heading.dropFirst(version.count).trimmingCharacters(in: .whitespaces), [])
                } else {
                    current = nil
                }
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        finish()
        return Array(result.prefix(limit))
    }
}

/// 给 git 用的代理：设置里填的，否则用系统网络设置里的 HTTPS / HTTP / SOCKS 代理（Clash 等的“系统代理”）。
/// git 自己不读 macOS 的代理设置。写法沿用 KongSeek。
public enum ProxySettings {
    /// 由 CFNetworkCopySystemProxySettings 的字典得出 git 的 http.proxy
    public static func gitProxy(fromSystem settings: [String: Any]) -> String? {
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.intValue == 1 }
        func address(_ hostKey: String, _ portKey: String) -> String? {
            guard let host = settings[hostKey] as? String, !host.isEmpty else { return nil }
            let port = (settings[portKey] as? NSNumber)?.intValue
            return port.map { "\(host):\($0)" } ?? host
        }
        if enabled("HTTPSEnable"), let value = address("HTTPSProxy", "HTTPSPort") { return "http://" + value }
        if enabled("HTTPEnable"), let value = address("HTTPProxy", "HTTPPort") { return "http://" + value }
        if enabled("SOCKSEnable"), let value = address("SOCKSProxy", "SOCKSPort") { return "socks5h://" + value }
        return nil
    }

    /// 手填的代理：“127.0.0.1:7890”补成“http://127.0.0.1:7890”；保留 http、https、socks5、socks5h、socks4。空或不能用返回 nil
    public static func normalized(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h", "socks4"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return withScheme
    }

    /// git 的输出说明根本连不上服务器
    public static func isConnectionFailure(_ output: String) -> Bool {
        let markers = ["Failed to connect", "Couldn't connect", "Could not resolve host", "Connection timed out",
                       "Operation timed out", "Connection refused", "Proxy CONNECT aborted", "SSL_ERROR_SYSCALL",
                       "LibreSSL SSL_connect", "Network is unreachable", "超过"]
        return markers.contains { output.contains($0) }
    }
}

/// 更新时源码文件夹里的本地改动：与 GitHub 上某个已发布版本完全相同的文件（从别处复制来的）可以放心覆盖，
/// 其余视为自己改过的，为免丢失要停下。只做判断，不碰文件。
public enum SourceLocalChanges {
    /// - Parameters:
    ///   - local: 有改动或未被跟踪的文件（相对路径）及其 git 哈希
    ///   - tracked: 其中被 git 跟踪的（有改动的）
    ///   - published: 近期已发布各版本里，每个路径出现过的全部哈希
    /// - Returns: 不能覆盖的文件
    public static func conflicts(local: [(path: String, hash: String)], tracked: Set<String>, published: [String: Set<String>]) -> [String] {
        var out: [String] = []
        for (path, hash) in local {
            if let versions = published[path] {
                if !versions.contains(hash) { out.append(path) }
            } else if tracked.contains(path) {
                out.append(path)
            }
        }
        return out
    }
}
