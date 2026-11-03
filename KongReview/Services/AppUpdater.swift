import AppKit
import CFNetwork
import Foundation
import Observation
import Security
import KongReviewCore

// MARK: - 6.0.2：点一下就更新（仿 KongSeek 的更新方式）
//
// 不再等 GitHub Releases 上的安装包：应用在本机的源码文件夹（~/Developer/KongReview，第一次用时自动下载）里
// 取 GitHub 上 main 分支的最新代码，先跑全部测试，再编译、签名；校验新版本后备份学习库，
// 退出，由助手脚本换上新版（当前版本移到“应用备份”留作回退）并重新打开。
// 测试或编译不通过就停下，当前安装的版本不动。启动 30 秒后与每 6 小时自动检查一次（可关）。

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    nonisolated static let repoURL = "https://github.com/kongxiangruihello/KongReview.git"
    nonisolated static let repoPage = URL(string: "https://github.com/kongxiangruihello/KongReview")!
    nonisolated static let bundleID = "com.kongxiangrui.KongReview"

    nonisolated static let autoCheckKey = "update.autoCheck"
    nonisolated static let lastCheckKey = "update.lastCheck"
    nonisolated static let proxyKey = "update.proxy"
    nonisolated static let updatedFromKey = "update.updatedFrom"
    nonisolated static let lastTestCountKey = "update.lastTestCount"
    /// 自动检查的间隔
    nonisolated static let autoInterval: TimeInterval = 6 * 3600

    /// 更新的各步，进度里逐项打勾
    enum Step: Int, CaseIterable, Equatable, Sendable {
        case fetch, test, compile, verify, backup, install

        var title: String {
            switch self {
            case .fetch: "从 GitHub 获取新代码"
            case .test: "编译并运行全部测试"
            case .compile: "编译新版本"
            case .verify: "校验新版本"
            case .backup: "备份学习库"
            case .install: "安装并重新打开"
            }
        }
    }

    struct Progress: Equatable, Sendable {
        var title: String
        var steps: [Step]
        var current: Step
        /// 整个更新，0…1
        var fraction: Double = 0
        var detail = ""
        var started = Date()
        /// 停下的原因；当前安装的版本没有改动
        var failure: String?
        var finished = false
    }

    enum Phase: Equatable {
        case idle
        case checking(String)
        case upToDate
        case available
        case updating
        case failed(String)
    }

    var phase: Phase = .idle
    /// GitHub 上比本机新的版本号
    var remoteVersion: String?
    /// GitHub 上本机没有的提交（只在本机版本记下了提交号时知道）
    var pending: [String] = []
    /// README 里比本机新的各节
    var notes: [ReleaseNotes.Section] = []
    var progress: Progress?
    var showsPanel = false
    /// 刚更新完：从哪个版本来、这之间的改动
    var welcome: (from: String, notes: [ReleaseNotes.Section])?
    var backups: [String] = []
    /// 安装前的准备（备份学习库）；由应用启动时设好
    @ObservationIgnored var beforeInstall: (() throws -> Void)?
    @ObservationIgnored private var timer: Timer?

    var hasUpdate: Bool { remoteVersion != nil || !pending.isEmpty }
    var isBusy: Bool {
        switch phase {
        case .checking, .updating: true
        default: false
        }
    }

    init() {
        backups = Self.listBackups()
    }

    // MARK: 本机这一版

    nonisolated static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    nonisolated static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    /// 构建脚本在源码没有本地改动时记下的提交号
    nonisolated static var installedCommit: String? { Bundle.main.object(forInfoDictionaryKey: "KRSourceCommit") as? String }

    var currentVersionText: String {
        "KongReview \(Self.version)（构建 \(Self.build)" + (Self.installedCommit.map { " · \($0.prefix(7))" } ?? "") + "）"
    }

    /// 只有正式安装的 KongReview.app 才能就地更新（预览版、测试进程不行）
    var canInstall: Bool {
        Bundle.main.bundleIdentifier == Self.bundleID && Bundle.main.bundlePath.hasSuffix(".app") && AppVersion(Self.version) != nil
    }

    /// 源码文件夹
    nonisolated static var sourceRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/KongReview", isDirectory: true)
    }

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("KongReview-updates", isDirectory: true)
    }
    nonisolated static var logURL: URL { supportDirectory.appendingPathComponent("update.log") }
    nonisolated static var buildLogURL: URL { sourceRoot.appendingPathComponent("build/build.log") }
    /// 换下来的旧版本放在这里，可回退
    nonisolated static var backupsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? supportDirectory
        return base.appendingPathComponent("KongReview/应用备份", isDirectory: true)
    }

    var lastChecked: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// 设置里填的代理，否则系统代理；都没有为直连
    nonisolated static var proxy: String? {
        if let typed = ProxySettings.normalized(UserDefaults.standard.string(forKey: proxyKey) ?? "") { return typed }
        return systemProxy
    }

    nonisolated static var systemProxy: String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        return ProxySettings.gitProxy(fromSystem: settings)
    }

    /// 当前应用的签名方式
    nonisolated static func signingDescription(of url: URL = Bundle.main.bundleURL) -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return "无法读取" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return "未签名" }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return "本机签名（ad hoc）" }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let first = certificates.first, let name = SecCertificateCopySubjectSummary(first) as String? {
            return "证书：\(name)"
        }
        return "已签名"
    }

    // MARK: 启动

    /// 启动时：刚更新过就显示改动；之后 30 秒自动检查一次，再每 6 小时一次
    func launched() {
        let defaults = UserDefaults.standard
        if let from = defaults.string(forKey: Self.updatedFromKey) {
            defaults.removeObject(forKey: Self.updatedFromKey)
            if from != Self.version {
                let readme = (try? String(contentsOf: Self.sourceRoot.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
                let current = AppVersion(Self.version)
                welcome = (from, ReleaseNotes.sections(in: readme, newerThan: from).filter { section in
                    guard let v = AppVersion(section.version), let current else { return true }
                    return v <= current
                })
                showsPanel = true
            }
        }
        startAutomaticChecks()
    }

    func startAutomaticChecks() {
        guard canInstall, Self.autoCheckEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    /// 开了自动检查、距上次超过 6 小时才查；有新版只在首页提示，不弹窗
    func checkIfDue(now: Date = Date()) {
        guard Self.autoCheckEnabled, canInstall, !isBusy else { return }
        if let last = lastChecked, now.timeIntervalSince(last) < Self.autoInterval { return }
        check(manual: false)
    }

    // MARK: 检查

    func check(manual: Bool) {
        if manual { showsPanel = true }
        guard !isBusy else { return }
        guard canInstall else {
            if manual { phase = .failed("这是预览版或开发构建，不能就地更新。") }
            return
        }
        welcome = nil
        let root = Self.sourceRoot
        let running = Self.version
        let commit = Self.installedCommit
        phase = .checking(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
                          ? "正在连接 GitHub…" : "第一次使用：正在把源码下载到 ~/Developer/KongReview（只需一次）…")
        Self.queue.async {
            let outcome = Result { () throws -> (String?, [String], [ReleaseNotes.Section]) in
                try Self.ensureSource(root)
                try Self.fetch(root)
                let remote = ReleaseNotes.version(inProjectYML: Self.git(["show", "origin/main:project.yml"], root, logOutput: false).output)
                let readme = Self.git(["show", "origin/main:README.md"], root, logOutput: false).output
                var subjects: [String] = []
                if let commit, Self.git(["cat-file", "-e", commit + "^{commit}"], root).status == 0 {
                    subjects = Self.lines(Self.git(["log", "--no-merges", "--format=%s", "\(commit)..origin/main"], root))
                }
                let newer = remote.flatMap { r in AppVersion(r).flatMap { v in AppVersion(running).map { v > $0 } } == true ? r : nil }
                let notes = ReleaseNotes.sections(in: readme, newerThan: running)
                Self.log("检查：本机 \(running)，GitHub \(remote ?? "?")，新提交 \(subjects.count) 个")
                return (newer, subjects, notes)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                    switch outcome {
                    case .success(let (newer, subjects, notes)):
                        self.remoteVersion = newer
                        self.pending = subjects
                        self.notes = notes
                        self.phase = self.hasUpdate ? .available : .upToDate
                    case .failure(let error):
                        self.phase = .failed(Self.describe(error))
                    }
                }
            }
        }
    }

    // MARK: 更新

    /// 取新代码（fromLocalSource 时不取）→ 测试并编译 → 校验 → 备份学习库 → 安装并重新打开
    func update(fromLocalSource: Bool = false) {
        showsPanel = true
        guard !isBusy else { return }
        guard canInstall else { phase = .failed("这是预览版或开发构建，不能就地更新。"); return }
        let root = Self.sourceRoot
        if fromLocalSource, !FileManager.default.fileExists(atPath: root.appendingPathComponent("Tools/build-app.sh").path) {
            phase = .failed("源码文件夹里还没有代码，请先点“检查更新”。")
            return
        }
        welcome = nil
        let steps: [Step] = fromLocalSource ? [.test, .compile, .verify, .backup, .install] : Step.allCases
        let title = fromLocalSource ? "用本地源码重新构建 KongReview" : "更新 KongReview" + (remoteVersion.map { " 到 \($0)" } ?? "")
        phase = .updating
        progress = Progress(title: title, steps: steps, current: steps[0], detail: fromLocalSource ? "准备中…" : "正在连接 GitHub…")
        let expected = UserDefaults.standard.integer(forKey: Self.lastTestCountKey)
        let report: @Sendable (Step, Double, String) -> Void = { step, fraction, detail in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.advance(step, fraction, detail) } }
        }
        let backupDatabase: @Sendable () throws -> Void = {
            var thrown: Error?
            DispatchQueue.main.sync { MainActor.assumeIsolated { do { try self.beforeInstall?() } catch { thrown = error } } }
            if let thrown { throw thrown }
        }
        Self.queue.async {
            Self.log("==== \(fromLocalSource ? "从本地源码重新构建" : "更新") 开始 \(Date())")
            let buildStart = fromLocalSource ? 0.0 : 0.08
            do {
                if !fromLocalSource {
                    try Self.ensureSource(root)
                    try Self.fetch(root)
                    report(.fetch, 0.05, "正在把源码文件夹换成 GitHub 上的最新代码…")
                    try Self.bringSourceUpToDate(root)
                }
                report(.test, buildStart, "正在编译测试（约几分钟）…")
                var build = BuildLogProgress(expectedTests: expected > 0 ? expected : 790)
                var shown = (detail: "", fraction: -1.0)
                let result = Self.run("/bin/bash", ["Tools/build-app.sh", "--test"], root.path, timeout: 3600) { line in
                    build.consume(line)
                    let fraction = buildStart + (0.9 - buildStart) * build.overall
                    guard build.detail != shown.detail || fraction - shown.fraction >= 0.01 else { return }
                    shown = (build.detail, fraction)
                    report(build.stage >= .compiling ? .compile : .test, fraction, build.detail)
                }
                if build.testsRun > 0, build.failedTests.isEmpty { UserDefaults.standard.set(build.testsRun, forKey: Self.lastTestCountKey) }
                guard result.status == 0 else { throw UpdateError(Self.buildFailure(build)) }

                let built = root.appendingPathComponent("build/KongReview.app")
                report(.verify, 0.92, "核对新版本的标识、版本与签名…")
                try Self.verify(built)

                report(.backup, 0.95, "安装前先备份学习库…")
                try backupDatabase()

                report(.install, 0.98, "正在安装，KongReview 将在几秒内重新打开…")
                try Self.install(built, isRollback: false)
            } catch {
                let message = Self.describe(error)
                Self.log("失败：\(message)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        UserDefaults.standard.removeObject(forKey: Self.updatedFromKey)
                        self.phase = .failed(message)
                        self.progress?.failure = message
                    }
                }
            }
        }
    }

    private func advance(_ step: Step, _ fraction: Double, _ detail: String) {
        guard var p = progress else { return }
        p.current = step
        p.fraction = max(p.fraction, fraction)
        p.detail = detail
        if step == .install { p.finished = true; p.fraction = 1 }
        progress = p
    }

    /// 回退到最近一个备份的版本（只换回应用；学习库保持现在的样子）
    func rollback() {
        guard canInstall, !isBusy, let latest = Self.listBackups().first else { return }
        let source = Self.backupsURL.appendingPathComponent(latest)
        showsPanel = true
        phase = .updating
        progress = Progress(title: "回退到 " + latest.replacingOccurrences(of: ".app", with: ""), steps: [.install], current: .install,
                            fraction: 0.5, detail: "正在换回上一版，KongReview 将重新打开…", finished: true)
        Self.queue.async {
            do {
                // 安装脚本装完会删掉来源，所以先复制一份
                let staged = Self.supportDirectory.appendingPathComponent("回退/KongReview.app")
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.step(Self.run("/usr/bin/ditto", [source.path, staged.path], "/"), "复制备份失败")
                try Self.install(staged, isRollback: true)
            } catch {
                let message = "回退失败：" + Self.describe(error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.phase = .failed(message); self.progress?.failure = message }
                }
            }
        }
    }

    func dismissProgress() {
        guard !isBusy else { return }
        progress = nil
        if case .failed = phase { phase = hasUpdate ? .available : .idle }
    }

    // MARK: 后台各步

    nonisolated static let queue = DispatchQueue(label: "KongReview.updater", qos: .utility)

    /// 源码文件夹不存在就从 GitHub 下载一份
    nonisolated static func ensureSource(_ root: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(".git").path) { return }
        if fm.fileExists(atPath: root.path), let items = try? fm.contentsOfDirectory(atPath: root.path), !items.filter({ $0 != ".DS_Store" }).isEmpty {
            throw UpdateError("“\(root.path)”已有别的文件，不是 KongReview 的源码，没有动它。请把它移走或改名后再试。")
        }
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        log("源码文件夹不存在，下载到 \(root.path)")
        let proxyOptions = proxy.map { ["-c", "http.proxy=\($0)"] } ?? []
        let result = run("/usr/bin/git", ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30"] + proxyOptions
                         + ["clone", "--quiet", "--branch", "main", repoURL, root.path], root.deletingLastPathComponent().path, timeout: 600)
        guard result.status == 0 else {
            try? fm.removeItem(at: root)
            throw UpdateError(fetchFailure(result.output, first: true))
        }
    }

    /// git fetch origin main，有代理就经代理；45 秒没完成就停（连不上 GitHub 时否则要等一分多钟）
    nonisolated static func fetch(_ root: URL) throws {
        log("连接 GitHub：" + (proxy.map { "经代理 \($0)" } ?? "直连"))
        let proxyOptions = proxy.map { ["-c", "http.proxy=\($0)"] } ?? []
        let result = git(proxyOptions + ["fetch", "--quiet", "origin", "main"], root, timeout: 45)
        guard result.status == 0 else { throw UpdateError(fetchFailure(result.output, first: false)) }
    }

    nonisolated static func fetchFailure(_ output: String, first: Bool) -> String {
        let what = first ? "从 GitHub 下载源码失败" : "从 GitHub 获取更新失败"
        guard ProxySettings.isConnectionFailure(output) else { return what + "（详情见更新日志）。" }
        if let proxy { return "通过代理 \(proxy) 仍连不上 GitHub。请确认代理软件正在运行、端口正确。" }
        return "这台 Mac 直连不上 GitHub（中国大陆常见）。如果用代理软件，请打开它的“系统代理”，或在“设置 → 更新”里填写代理地址。"
    }

    /// 把源码文件夹换到 origin/main。本地改过的文件若与某个已发布版本完全相同（从别处复制来的），可以覆盖；
    /// 其余视为自己改过的，停下，免得丢失。仓库从没有过的文件不动。
    nonisolated static func bringSourceUpToDate(_ root: URL) throws {
        if git(["merge-base", "--is-ancestor", "HEAD", "origin/main"], root).status != 0 {
            throw UpdateError("源码文件夹里有 GitHub 上没有的提交，为免丢失，已停止更新。")
        }
        let changed = lines(git(["diff", "--name-only", "HEAD"], root, logOutput: false))
        let untracked = lines(git(["ls-files", "--others", "--exclude-standard"], root, logOutput: false))
        let fm = FileManager.default
        let local = Array(Set(changed + untracked)).sorted().filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        if !local.isEmpty {
            let hashes = lines(git(["hash-object", "--"] + local, root, logOutput: false))
            guard hashes.count == local.count else { throw UpdateError("无法读取源码文件夹中的文件。") }
            var published: [String: Set<String>] = [:]
            for commit in lines(git(["rev-list", "--max-count=200", "origin/main"], root, logOutput: false)) {
                for entry in lines(git(["ls-tree", "-r", commit], root, logOutput: false)) {
                    let parts = entry.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2, let hash = parts[0].split(separator: " ").last else { continue }
                    published[String(parts[1]), default: []].insert(String(hash))
                }
            }
            let conflicts = SourceLocalChanges.conflicts(local: Array(zip(local, hashes)).map { (path: $0.0, hash: $0.1) },
                                                         tracked: Set(changed), published: published)
            guard conflicts.isEmpty else {
                throw UpdateError("源码文件夹里这些文件有本地修改，为免覆盖，已停止更新：" + conflicts.prefix(5).joined(separator: "、"))
            }
            log("本地有 \(local.count) 个文件与已发布版本相同，可以更新。")
        }
        try step(git(["reset", "--hard", "--quiet", "origin/main"], root), "无法更新源码文件夹")
    }

    nonisolated static func buildFailure(_ build: BuildLogProgress) -> String {
        if !build.failedTests.isEmpty || build.testsCrashed {
            var message = build.failedTests.isEmpty ? "测试程序运行中崩溃"
                : "有 \(build.failedTests.count) 项测试未通过（\(build.failedTests.prefix(3).joined(separator: "、"))）"
            message += "，已停止；当前安装的版本没有改动。"
            if let first = build.testFailures.first { message += "\n" + first }
            return message
        }
        if let first = build.compileErrors.first {
            return "编译失败，已停止；当前安装的版本没有改动。\n" + first
                + (build.compileErrors.count > 1 ? "（另有 \(build.compileErrors.count - 1) 处）" : "")
        }
        return "测试或编译失败（详情见构建日志），已停止；当前安装的版本没有改动。"
    }

    /// 新版本必须是 KongReview、版本号可读、签名有效；当前用证书签名时，新版本也要满足同一签名要求
    /// （这样 macOS 仍当作同一个应用，已授予的权限不丢）
    nonisolated static func verify(_ app: URL) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("新版本缺少 Info.plist。")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("新版本的应用标识不对，没有安装。") }
        guard let v = info["CFBundleShortVersionString"] as? String, AppVersion(v) != nil else { throw UpdateError("新版本的版本号读不出，没有安装。") }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("无法读取新版本的签名。")
        }
        guard SecStaticCodeCheckValidity(candidate, [], nil) == errSecSuccess else { throw UpdateError("新版本签名无效，没有安装。") }
        guard !signingDescription().hasPrefix("本机签名") else {
            log("当前版本为本机签名（ad hoc），只核对新版本签名有效。")
            return
        }
        var current: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("无法读取当前版本的签名要求。")
        }
        let status = SecStaticCodeCheckValidity(candidate, [], requirement)
        guard status == errSecSuccess else {
            throw UpdateError("新版本的签名与当前版本不一致（\(status)），为保住已授予的权限，已停止安装。请确认钥匙串里的签名证书还在。")
        }
    }

    /// 写一个助手脚本：等 KongReview 退出，把当前版本移到“应用备份”，换上新版并重新打开（失败则换回）。然后退出。
    nonisolated static func install(_ newApp: URL, isRollback: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        // 只留最近三个旧版本（加上这次换下来的）
        for old in listBackups().dropFirst(2) { try? fm.removeItem(at: backupsURL.appendingPathComponent(old)) }
        let target = Bundle.main.bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else { throw UpdateError("没有权限写入“\(parent)”。") }
        let script = UpdateInstallScript.make(pid: ProcessInfo.processInfo.processIdentifier, source: newApp.path, target: target,
                                              backup: backupsURL.appendingPathComponent(runningBackupName).path,
                                              dmgMount: nil, log: logURL.path)
        let scriptURL = supportDirectory.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        UserDefaults.standard.set(version, forKey: updatedFromKey)
        log(isRollback ? "已启动回退，KongReview 即将退出。" : "已启动安装，KongReview 即将退出。")
        // 让进度窗口显示一下“完成”再退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// 当前版本的备份名，如“KongReview-6.0.2-512.app”
    nonisolated static var runningBackupName: String { "KongReview-\(version)-\(build).app" }

    /// 当前版本以外的备份，构建号新的在前
    nonisolated static func listBackups() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: backupsURL.path))?.filter { $0.hasSuffix(".app") } ?? []
        func buildNumber(_ name: String) -> Int { Int(name.dropLast(4).split(separator: "-").last ?? "") ?? 0 }
        return names.filter { $0 != runningBackupName }.sorted { buildNumber($0) > buildNumber($1) }
    }

    // MARK: 运行命令

    nonisolated static func lines(_ result: (status: Int32, output: String)) -> [String] {
        result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    nonisolated static func step(_ result: (status: Int32, output: String), _ failure: String) throws {
        guard result.status == 0 else {
            let detail = result.output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw UpdateError(failure + (detail.isEmpty ? "" : "：" + detail))
        }
    }

    nonisolated static func git(_ arguments: [String], _ root: URL, timeout: TimeInterval = 120, logOutput: Bool = true) -> (status: Int32, output: String) {
        run("/usr/bin/git", ["-C", root.path, "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=20"] + arguments, root.path,
            timeout: timeout, logOutput: logOutput)
    }

    /// 运行一个命令直到结束，命令与输出记进更新日志；超过 timeout 秒就停。onLine 逐行（按 \n 或 \r 切）收到输出
    nonisolated static func run(_ executable: String, _ arguments: [String], _ directory: String,
                                timeout: TimeInterval = 1200, logOutput: Bool = true,
                                onLine: ((String) -> Void)? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: directory) ? directory : "/")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            log("$ \(executable) \(arguments.joined(separator: " "))\n无法运行：\(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var data = Data()
        var pending = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard let onLine else { continue }
            pending.append(chunk)
            while let cut = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                onLine(String(decoding: pending[pending.startIndex..<cut], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...cut)
            }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        watchdog.cancel()
        var output = String(decoding: data, as: UTF8.self)
        if timedOut.value { output += "\n超过 \(Int(timeout)) 秒未完成，已停止。" }
        let shown = logOutput ? output : "（输出 \(data.count) 字节）\n"
        log("$ \(executable) \(arguments.joined(separator: " "))\n\(shown)(退出码 \(process.terminationStatus))")
        return (timedOut.value ? -2 : process.terminationStatus, output)
    }

    nonisolated static func log(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        return error.localizedDescription
    }
}

/// 看门狗与读输出在不同线程，超时标记加锁
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
