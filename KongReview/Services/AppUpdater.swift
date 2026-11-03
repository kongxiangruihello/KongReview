import AppKit
import CryptoKit
import Foundation
import Observation
import KongReviewCore

// MARK: - 5.2.1：在线更新
//
// 读 GitHub Releases 的最新发布（kongxiangruihello/KongReview），比当前版本新就提示：
// 下载 DMG（显示进度、速度、剩余时间）→ 校验大小与 SHA-256 → 挂载、核对应用标识与版本、校验签名，
// 复制到缓存目录 → 先备份学习库 → 退出，由助手脚本换上新版（旧版移到缓存目录留作后备）并重新打开。
// 下载用 URLSession，不带“隔离”属性，所以本机签名的新版能直接打开。
// 启动时每天至多自动检查一次（设置可关），菜单“KongReview → 检查更新…”随时手动检查。

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    static let owner = "kongxiangruihello"
    static let repo = "KongReview"
    static let latestURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repo)/releases")!

    static let autoCheckKey = "update.autoCheck"
    static let lastCheckKey = "update.lastCheck"
    static let skippedKey = "update.skippedVersion"
    /// 自动检查的间隔
    static let autoInterval: TimeInterval = 20 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        /// 已是最新（附上最新发布的版本）
        case upToDate(String)
        case available
        case downloading
        case verifying
        /// 下载好、校验过，等用户点“安装并重新打开”
        case ready
        case installing(String)
        case failed(String)
    }

    var phase: Phase = .idle
    var release: UpdateRelease?
    var received: Int64 = 0
    var expected: Int64 = 0
    var bytesPerSecond: Double?
    var showsPanel = false
    /// 安装前的准备（备份学习库）；由应用启动时设好
    @ObservationIgnored var beforeInstall: (() throws -> Void)?

    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var downloadedFile: URL?
    @ObservationIgnored private var rateSamples: [(Date, Int64)] = []

    /// 当前版本；预览版、开发构建（版本不是数字）为 nil
    let currentVersion: AppVersion? = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    var currentVersionText: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// 只有正式安装的 KongReview.app 才能就地替换（预览版、命令行编译的不行）
    var canInstall: Bool {
        Bundle.main.bundleIdentifier == "com.kongxiangrui.KongReview" && Bundle.main.bundlePath.hasSuffix(".app") && currentVersion != nil
    }

    var isNewer: Bool {
        guard let r = release else { return false }
        guard let cur = currentVersion else { return true }
        return r.version > cur
    }

    var progress: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var progressLine: String { UpdateProgressText.line(received: received, total: expected, bytesPerSecond: bytesPerSecond) }

    var lastChecked: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("KongReview-updates", isDirectory: true)
    }

    // MARK: 检查

    /// 启动时：开了自动检查、距上次超过 20 小时才查；有新版且没被跳过就弹出面板
    func checkIfDue(now: Date = Date()) {
        guard Self.autoCheckEnabled, canInstall else { return }
        if let last = lastChecked, now.timeIntervalSince(last) < Self.autoInterval { return }
        check(manual: false)
    }

    /// 手动检查总是弹出面板；自动检查只在有新版（且没跳过）时弹出，出错不打扰
    func check(manual: Bool) {
        switch phase {
        case .downloading, .verifying, .installing: showsPanel = true; return
        default: break
        }
        phase = .checking
        if manual { showsPanel = true }
        var req = URLRequest(url: Self.latestURL, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KongReview/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw UpdateError(status == 404 ? "还没有找到发布的版本（仓库未公开或尚无发布）。"
                                      : status == 403 ? "GitHub 暂时限制了查询次数，请过一会儿再试。"
                                      : "查询失败（HTTP \(status)）。")
                }
                let r = try UpdateRelease.parse(data)
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                self.release = r
                if self.isNewer {
                    self.phase = .available
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                    if manual || skipped != r.version.description { self.showsPanel = true }
                } else {
                    self.phase = .upToDate(r.version.description)
                }
            } catch {
                self.phase = .failed(Self.describe(error))
                if !manual { self.showsPanel = false }
            }
        }
    }

    func skipThisVersion() {
        if let r = release { UserDefaults.standard.set(r.version.description, forKey: Self.skippedKey) }
        showsPanel = false
    }

    // MARK: 下载

    func download() {
        guard let r = release else { return }
        cancelDownload(resetPhase: false)
        phase = .downloading
        received = 0
        expected = r.dmgSize
        bytesPerSecond = nil
        rateSamples = [(Date(), 0)]
        let dir = Self.cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(r.dmgName)
        let delegate = UpdateDownloadDelegate(destination: dest,
            progress: { [weak self] got, total in
                Task { @MainActor in self?.progressed(got, total) }
            },
            finished: { [weak self] result in
                Task { @MainActor in self?.finished(result) }
            })
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var req = URLRequest(url: r.dmgURL)
        req.setValue("KongReview/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
        let task = s.downloadTask(with: req)
        session = s
        downloadTask = task
        task.resume()
    }

    func cancelDownload(resetPhase: Bool = true) {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        if resetPhase { phase = release != nil && isNewer ? .available : .idle }
    }

    private func progressed(_ got: Int64, _ total: Int64) {
        guard phase == .downloading else { return }
        received = got
        if total > 0 { expected = total }
        let now = Date()
        rateSamples.append((now, got))
        rateSamples.removeAll { now.timeIntervalSince($0.0) > 4 }
        if let first = rateSamples.first, now.timeIntervalSince(first.0) > 0.5 {
            bytesPerSecond = Double(got - first.1) / now.timeIntervalSince(first.0)
        }
    }

    private func finished(_ result: Result<URL, Error>) {
        session?.finishTasksAndInvalidate()
        session = nil
        downloadTask = nil
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            phase = .failed("下载没有完成：" + Self.describe(error))
        case .success(let file):
            downloadedFile = file
            phase = .verifying
            let r = release
            Task.detached(priority: .userInitiated) {
                let check = Result { try Self.verifyDownload(file, release: r) }
                await MainActor.run {
                    switch check {
                    case .success: self.phase = .ready
                    case .failure(let e): self.phase = .failed(Self.describe(e))
                    }
                }
            }
        }
    }

    /// 大小与 SHA-256（发布给了摘要时）都要对得上
    nonisolated static func verifyDownload(_ file: URL, release: UpdateRelease?) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let r = release, r.dmgSize > 0, size != r.dmgSize {
            throw UpdateError("下载的文件大小不对（\(size) 字节，应为 \(r.dmgSize) 字节），请重试。")
        }
        if let want = release?.sha256 {
            let got = try sha256(of: file)
            if got != want { throw UpdateError("下载的文件校验不符，可能已损坏，请重试。") }
        }
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 安装

    func installAndRelaunch() {
        guard let file = downloadedFile, let r = release else { return }
        guard canInstall else {
            phase = .failed("这是预览版或开发构建，不能就地更新。可打开下载好的安装包手动安装。")
            return
        }
        let target = Bundle.main.bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            phase = .failed("没有权限写入“\(parent)”，请打开下载好的安装包手动安装。")
            return
        }
        phase = .installing("正在备份学习库…")
        do { try beforeInstall?() } catch {
            phase = .failed("安装前备份学习库失败，没有安装：" + Self.describe(error))
            return
        }
        phase = .installing("正在检查安装包…")
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .userInitiated) {
            do {
                let staged = try Self.stage(dmg: file, bundleID: bundleID, version: r.version)
                let dir = Self.cacheDirectory
                let script = UpdateInstallScript.make(pid: pid, source: staged.path, target: target,
                                                      backup: dir.appendingPathComponent("上一版/KongReview.app").path,
                                                      dmgMount: nil, log: dir.appendingPathComponent("安装记录.log").path)
                let scriptURL = dir.appendingPathComponent("install.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [scriptURL.path]
                try p.run()
                await MainActor.run {
                    self.phase = .installing("正在重新打开…")
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run { self.phase = .failed(Self.describe(error)) }
            }
        }
    }

    /// 挂载 DMG，找到 KongReview.app，核对标识、版本与签名，复制到缓存目录，卸下 DMG
    nonisolated static func stage(dmg: URL, bundleID: String, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let mount = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KongReview-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }
        let apps = (try fm.contentsOfDirectory(atPath: mount.path)).filter { $0.hasSuffix(".app") }
        guard let name = apps.first(where: { $0 == "KongReview.app" }) ?? apps.first else {
            throw UpdateError("安装包里没有找到 KongReview.app。")
        }
        let app = mount.appendingPathComponent(name)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("安装包里的应用缺少 Info.plist。")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("安装包里的应用标识不对，没有安装。") }
        guard let v = AppVersion(info["CFBundleShortVersionString"] as? String ?? ""), v == version else {
            throw UpdateError("安装包里的版本与发布说明不符，没有安装。")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        let staged = cacheDirectory.appendingPathComponent("新版/KongReview.app")
        try? fm.removeItem(at: staged)
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [app.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-cr", staged.path])
        return staged
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) 出错：" + text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    /// 打开下载好的安装包（手动安装）
    func revealDownloadedDMG() {
        if let f = downloadedFile { NSWorkspace.shared.open(f) } else { NSWorkspace.shared.open(Self.releasesPage) }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "没有联网。"
            case .timedOut: return "连接超时，请检查网络或代理后重试。"
            case .cannotFindHost, .cannotConnectToHost: return "连不上 GitHub，请检查网络或代理后重试。"
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// URLSession 的下载回调：进度、完成时把临时文件立刻移到目标位置（回调返回后系统会删掉临时文件）
final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    let finished: @Sendable (Result<URL, Error>) -> Void
    private var reported = false

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void, finished: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.finished = finished
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            report(.failure(UpdateError("下载失败（HTTP \(status)）。")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            report(.success(destination))
        } catch {
            report(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { report(.failure(error)) }
    }

    private func report(_ r: Result<URL, Error>) {
        guard !reported else { return }
        reported = true
        finished(r)
    }
}
