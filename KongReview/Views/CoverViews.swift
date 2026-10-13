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

/// 出处编辑面板里的封面区：显示、拖入图片、选择文件、按 ISBN 获取、移除
struct CoverEditorSection: View {
    @Environment(LibraryStore.self) private var store
    let source: Source
    let isbn: Binding<String>

    var body: some View {
        let _ = store.coverRevision
        let img = source.id.flatMap { CoverCache.shared.image(for: $0, store: store) }
        Section("封面") {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    if let img {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        SourceThumb(source: source, size: CGSize(width: 72, height: 98))
                    }
                }
                .frame(width: 72, height: 98)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(ReviewPalette.hair))
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ISBN（10 或 13 位）", text: isbn)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    HStack {
                        Button("按 ISBN 获取") { fetch() }
                            .disabled(source.id == nil || isbn.wrappedValue.filter(\.isNumber).count < 9 || store.maintenanceProgress != nil)
                        Button("选择图片…") { choose() }
                            .disabled(source.id == nil)
                        if img != nil {
                            Button("移除", role: .destructive) { if let id = source.id { store.setCover(nil, for: id) } }
                        }
                    }
                    Text(source.id == nil ? "先保存出处，再添加封面。"
                         : "可把封面图片直接拖到左边。按 ISBN 获取用的是 Open Library，中文书收录较少，取不到时请拖入图片。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setCover(_ data: Data) {
        guard let id = source.id, let jpeg = CoverCache.normalized(data) else {
            store.errorMessage = "无法读取这张图片。"
            return
        }
        store.setCover(jpeg, for: id)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard source.id != nil, let p = providers.first else { return false }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage, let tiff = img.tiffRepresentation else { return }
                Task { @MainActor in setCover(tiff) }
            }
            return true
        }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in setCover(data) }
        }
        return true
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "设为封面"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        setCover(data)
    }

    private func fetch() {
        guard let id = source.id else { return }
        let isbn = isbn.wrappedValue
        store.maintenanceProgress = "正在从 Open Library 获取封面…"
        Task {
            let data = await CoverCache.fetchOpenLibrary(isbn: isbn)
            store.maintenanceProgress = nil
            if let data {
                store.setCover(data, for: id)
            } else {
                store.infoMessage = "Open Library 没有这个 ISBN 的封面（中文书常见）。可以把封面图片拖到出处编辑面板左边的封面框里。"
            }
        }
    }
}
