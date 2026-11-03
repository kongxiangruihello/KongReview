import Foundation

// MARK: - 5.2.1：在线更新——版本比较与发布信息解析
//
// 新版发布在 GitHub Releases（kongxiangruihello/KongReview）：标签为“v5.2.1”，附件为“KongReview-5.2.1.dmg”，
// 说明为本版改动。应用读取 /releases/latest，比较版本号，有新版就下载 DMG。

/// 形如“5.2.1”的版本号；按数字逐段比较，“5.10” > “5.9”，缺的段按 0 计（“5.2” == “5.2.0”）
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// 接受“5.2.1”“v5.2.1”“KongReview 5.2.1”；不是版本号（如“预览”）返回 nil
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) { s = String(s[r]) } else { return nil }
        let ps = s.split(separator: ".").compactMap { Int($0) }
        guard !ps.isEmpty else { return nil }
        parts = ps
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private func padded(_ n: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, n - parts.count)) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n).lexicographicallyPrecedes(b.padded(n))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n) == b.padded(n)
    }
}

/// 一次发布：版本、说明、DMG 下载地址与大小、可选的 SHA-256
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    public var tag: String
    public var notes: String
    public var publishedAt: Date?
    public var pageURL: URL?
    public var dmgName: String
    public var dmgURL: URL
    public var dmgSize: Int64
    /// GitHub 为附件给出的“sha256:…”摘要（较新的发布才有）
    public var sha256: String?

    public init(version: AppVersion, tag: String, notes: String, publishedAt: Date?, pageURL: URL?,
                dmgName: String, dmgURL: URL, dmgSize: Int64, sha256: String?) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.dmgName = dmgName
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.sha256 = sha256
    }

    public static func == (a: UpdateRelease, b: UpdateRelease) -> Bool {
        a.tag == b.tag && a.dmgURL == b.dmgURL && a.dmgSize == b.dmgSize
    }

    public enum ParseError: LocalizedError, Equatable {
        case notJSON
        case notVersion(String)
        case noDMG(String)
        case draft
        public var errorDescription: String? {
            switch self {
            case .notJSON: "发布信息无法读取。"
            case .notVersion(let tag): "发布标签“\(tag)”不是版本号。"
            case .noDMG(let tag): "\(tag) 没有附带安装包（.dmg）。"
            case .draft: "最新发布是草稿或预发布，不更新。"
            }
        }
    }

    /// 解析 GitHub REST API“/releases/latest”的回应。附件取名字以 appName 开头、以 .dmg 结尾的第一个。
    public static func parse(_ data: Data, appName: String = "KongReview") throws -> UpdateRelease {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        let tag = obj["tag_name"] as? String ?? ""
        guard let version = AppVersion(tag) else { throw ParseError.notVersion(tag) }
        if (obj["draft"] as? Bool) == true || (obj["prerelease"] as? Bool) == true { throw ParseError.draft }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: {
                  let n = ($0["name"] as? String ?? "").lowercased()
                  return n.hasPrefix(appName.lowercased()) && n.hasSuffix(".dmg")
              }),
              let urlText = dmg["browser_download_url"] as? String, let url = URL(string: urlText)
        else { throw ParseError.noDMG(tag) }
        let digest = (dmg["digest"] as? String).flatMap { d -> String? in
            d.lowercased().hasPrefix("sha256:") ? String(d.dropFirst(7)).lowercased() : nil
        }
        let iso = ISO8601DateFormatter()
        return UpdateRelease(version: version, tag: tag,
                             notes: (obj["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             publishedAt: (obj["published_at"] as? String).flatMap { iso.date(from: $0) },
                             pageURL: (obj["html_url"] as? String).flatMap(URL.init(string:)),
                             dmgName: dmg["name"] as? String ?? url.lastPathComponent,
                             dmgURL: url,
                             dmgSize: (dmg["size"] as? NSNumber)?.int64Value ?? 0,
                             sha256: digest)
    }
}

/// 下载进度的文字：“3.2 / 12.6 MB · 1.1 MB/s · 约 9 秒”
public enum UpdateProgressText {
    public static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    public static func line(received: Int64, total: Int64, bytesPerSecond: Double?) -> String {
        var parts = [total > 0 ? "\(megabytes(received)) / \(megabytes(total)) MB" : "\(megabytes(received)) MB"]
        if let r = bytesPerSecond, r > 1 {
            parts.append(String(format: "%.1f MB/s", r / 1_048_576))
            if total > received {
                let left = Int((Double(total - received) / r).rounded(.up))
                parts.append(left >= 60 ? "约 \(left / 60) 分 \(left % 60) 秒" : "约 \(left) 秒")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// 安装助手脚本：等应用退出，把旧版移到备份处，换上新版，去掉隔离属性，重新打开。
public enum UpdateInstallScript {
    /// - Parameters:
    ///   - pid: 正在运行的应用进程号
    ///   - source: 从 DMG 复制出来的新版 .app
    ///   - target: 现有应用的位置（如 /Applications/KongReview.app）
    ///   - backup: 旧版移到哪里（同名已存在先删）
    ///   - dmgMount: 用完要卸下的挂载点（可无）
    ///   - log: 记录写到哪里
    public static func make(pid: Int32, source: String, target: String, backup: String, dmgMount: String?, log: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = [
            "#!/bin/bash",
            "# KongReview 在线更新：等应用退出后替换并重新打开（由应用生成）",
            "exec >>\(q(log)) 2>&1",
            "echo \"== $(date) 开始安装\"",
            "for i in $(seq 1 300); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done",
            "if kill -0 \(pid) 2>/dev/null; then echo '应用没有退出，放弃安装'; exit 1; fi",
            "rm -rf \(q(backup))",
            "mkdir -p \"$(dirname \(q(backup)))\"",
            "if [ -d \(q(target)) ]; then mv \(q(target)) \(q(backup)) || { echo '移走旧版失败'; exit 1; }; fi",
            "if ! ditto \(q(source)) \(q(target)); then",
            "  echo '复制新版失败，恢复旧版'; rm -rf \(q(target)); mv \(q(backup)) \(q(target)); open \(q(target)); exit 1",
            "fi",
            "xattr -cr \(q(target)) 2>/dev/null",
        ]
        if let m = dmgMount { lines.append("hdiutil detach \(q(m)) -quiet 2>/dev/null || hdiutil detach \(q(m)) -force -quiet 2>/dev/null") }
        lines += [
            "rm -rf \(q(source))",
            "echo '安装完成，重新打开'",
            "open \(q(target))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
