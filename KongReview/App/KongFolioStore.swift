import Foundation
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 6.0.6：导入 KongFolio 的阅读材料

extension LibraryStore {
    /// 自动导入：KongFolio 的 catalog.json 改过才读（后台读文件，导入在主线程一次写完）
    /// force：不管改没改、开没开都导入一次（菜单与设置里的“立即导入”）
    func checkKongFolio(quiet: Bool = true, force: Bool = false) {
        guard !fullBackupBusy, !kongFolioChecking else { return }
        guard KongFolioSettings.isEnabled || force else { return }
        let url = KongFolioSettings.catalog
        let signature = KongFolioSettings.signature(url)
        if !force {
            guard let signature, signature != UserDefaults.standard.string(forKey: KongFolioSettings.lastSeenKey) else { return }
        }
        kongFolioChecking = true
        Task.detached(priority: .utility) {
            let read = Result { try KongFolioConverter.read(url) }
            await MainActor.run {
                self.kongFolioChecking = false
                switch read {
                case .success(let result):
                    self.importKongFolio(result, quiet: quiet)
                    if let signature { UserDefaults.standard.set(signature, forKey: KongFolioSettings.lastSeenKey) }
                case .failure(let error):
                    if !quiet { self.report(error) }
                }
            }
        }
    }

    /// 选一个文件导入：catalog.json、阅读记录备份（JSON）或导出的 Markdown
    func chooseKongFolioFile() {
        let panel = NSOpenPanel()
        panel.message = "选择 KongFolio 的阅读记录（catalog.json）或导出的 Markdown"
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.directoryURL = KongFolioSettings.catalog.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { importKongFolio(try KongFolioConverter.read(url), quiet: false) } catch { report(error) }
        }
    }

    /// 写入学习库并提示
    @discardableResult
    func importKongFolio(_ result: KongFolioConverter.Result, quiet: Bool) -> KongFolioReport? {
        guard !fullBackupBusy else { return nil }
        do {
            let r = try db.importKongFolio(result)
            if r.added > 0 || r.updated > 0 {
                reload()
                refreshRevisit()
                refreshDailyCheck()
            }
            kongFolioLast = Self.kongFolioStamp() + "：" + r.summary.replacingOccurrences(of: "\n", with: " ")
            UserDefaults.standard.set(kongFolioLast, forKey: KongFolioSettings.lastReportKey)
            if !quiet || r.added > 0 || r.updated > 0 { infoMessage = r.summary }
            return r
        } catch {
            report(error)
            return nil
        }
    }

    static func kongFolioStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}
