import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KongReviewCore

// MARK: - 摘录分享图

/// 分享图的选项（不用 @State，见 ViewState.swift 的说明）
@MainActor
@Observable
final class ShareImageOptions {
    static let shared = ShareImageOptions()
    var night = false
    var withTranslation = true
    var withNote = false
}

/// 竖版分享图（4:5，导出 1080×1350 像素）：纸色底、宋体正文、出处与封面
struct ShareCardView: View {
    let highlight: Highlight
    let source: Source?
    var night = false
    var withTranslation = true
    var withNote = false

    private var paper: Color { night ? Color(red: 0.11, green: 0.105, blue: 0.098) : Color(red: 0.965, green: 0.957, blue: 0.937) }
    private var ink: Color { night ? Color(red: 0.93, green: 0.92, blue: 0.90) : Color(red: 0.12, green: 0.118, blue: 0.11) }
    private var sub: Color { night ? Color(red: 0.61, green: 0.59, blue: 0.56) : Color(red: 0.54, green: 0.52, blue: 0.49) }
    private let accent = Color(red: 0.23, green: 0.45, blue: 0.94)

    static func plain(_ s: String) -> String {
        Markdown.plainText(fromHTML: Markdown.richHTML(s))
    }

    private var bodyText: String { Self.plain(highlight.text) }

    private var fontSize: CGFloat {
        switch bodyText.count {
        case ..<50: return 30
        case ..<110: return 25
        case ..<200: return 21
        case ..<320: return 18
        default: return 16
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Rectangle().fill(accent).frame(width: 28, height: 3)
                Spacer()
                Text(highlight.createdAt.formatted(.dateTime.year().month().day()))
                    .font(.system(size: 11)).foregroundStyle(sub)
            }
            Spacer(minLength: 28)
            Text(bodyText)
                .font(.system(size: fontSize, design: .serif))
                .lineSpacing(fontSize * 0.55)
                .foregroundStyle(ink)
                .lineLimit(16)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if withTranslation, let t = highlight.translation, !t.isEmpty {
                Text(Self.plain(t))
                    .font(.system(size: max(13, fontSize * 0.62)))
                    .lineSpacing(5)
                    .foregroundStyle(sub)
                    .lineLimit(6)
                    .padding(.top, 18)
            }
            if withNote, let n = highlight.note, !n.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(accent.opacity(0.6)).frame(width: 2)
                    Text(Self.plain(n)).font(.system(size: 13)).lineSpacing(4).foregroundStyle(sub).lineLimit(5)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            }
            Spacer(minLength: 28)
            HStack(alignment: .center, spacing: 12) {
                SourceThumb(source: source, size: CGSize(width: 34, height: 46))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.map { "《\($0.title)》" } ?? "摘录")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Text([source?.author ?? "", highlight.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(sub).lineLimit(1)
                }
                Spacer()
                Text("KongReview").font(.system(size: 10.5, weight: .medium)).tracking(1).foregroundStyle(sub.opacity(0.8))
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(width: 540, height: 675)
        .background(paper)
        .environment(\.colorScheme, night ? .dark : .light)
    }
}

struct ShareImageView: View {
    @Environment(LibraryStore.self) private var store
    private var options: ShareImageOptions { ShareImageOptions.shared }

    private func card(_ h: Highlight) -> some View {
        ShareCardView(highlight: h, source: store.source(for: h), night: options.night,
                      withTranslation: options.withTranslation, withNote: options.withNote)
            .environment(store)
    }

    /// 以 2 倍分辨率渲染成图片（1080×1350 像素）
    private func render(_ h: Highlight) -> NSImage? {
        let r = ImageRenderer(content: card(h))
        r.scale = 2
        return r.nsImage
    }

    var body: some View {
        let h = store.shareImageHighlight
        return VStack(spacing: 14) {
            Text("生成分享图").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            if let h {
                card(h)
                    .scaleEffect(0.78)
                    .frame(width: 540 * 0.78, height: 675 * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                HStack(spacing: 16) {
                    Toggle("夜色", isOn: Bindable(options).night)
                    Toggle("附译文", isOn: Bindable(options).withTranslation)
                        .disabled(h.translation?.isEmpty ?? true)
                    Toggle("附按语", isOn: Bindable(options).withNote)
                        .disabled(h.note?.isEmpty ?? true)
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("复制图片") {
                        guard let img = render(h) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                        store.shareImageHighlight = nil
                    }
                    Button("存为 PNG…") { savePNG(h) }
                    if let img = render(h) {
                        ShareLink(item: Image(nsImage: img), preview: SharePreview("摘录", image: Image(nsImage: img))) {
                            Label("分享…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Spacer()
                    Button("关闭", role: .cancel) { store.shareImageHighlight = nil }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func savePNG(_ h: Highlight) {
        guard let img = render(h), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let title = store.source(for: h)?.title ?? "摘录"
        panel.nameFieldStringValue = "\(title)-摘录.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            store.shareImageHighlight = nil
        } catch {
            store.report(error)
        }
    }
}
