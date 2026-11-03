import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 出处封面

/// 封面图片的内存缓存（数据库里存的是压缩后的 JPEG）
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private var images: [Int64: NSImage] = [:]
    private var revision = -1

    func image(for sourceId: Int64, store: LibraryStore) -> NSImage? {
        if revision != store.coverRevision {
            images.removeAll()
            revision = store.coverRevision
        }
        if let img = images[sourceId] { return img }
        guard store.coverIDs.contains(sourceId), let data = try? store.db.cover(sourceId: sourceId),
              let img = NSImage(data: data) else { return nil }
        images[sourceId] = img
        return img
    }

    /// 缩到长边不超过 600 像素、转成 JPEG（封面只做显示用，没必要存原图）
    nonisolated static func normalized(_ data: Data) -> Data? {
        guard let src = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: src.size)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, 600 / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// 按 ISBN 从 Open Library 取封面（https://openlibrary.org/dev/docs/api/covers）；没有时返回 nil
    nonisolated static func fetchOpenLibrary(isbn raw: String) async -> Data? {
        let isbn = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        guard isbn.count == 10 || isbn.count == 13,
              let url = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("KongReview (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 1000 else { return nil }
        return normalized(data)
    }
}
