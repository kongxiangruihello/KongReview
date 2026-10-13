import AppKit
import SwiftUI
import ApplicationServices
import KongReviewCore

/// 引文速查浮窗：在任何应用里按快捷键（默认 ⌃⌥L）弹出，输入关键词找摘录，回车把“原文 + 出处”粘到原来的应用里。
///
/// - 浮窗与快速录入一样是“非激活面板”：不把 KongReview 带到前台，原来的应用仍是当前应用，关掉浮窗后焦点自动回去。
/// - 自动粘贴需要“辅助功能”权限（用来模拟按 ⌘V）；没有权限时只复制到剪贴板，提示按 ⌘V。
/// - ↑↓ 选择，↩ 按当前格式粘贴，⌥↩ 只粘贴出处，⇧↩ 只粘贴原文，⌘↩ 只复制不粘贴，Esc 关闭。
/// - 1.2：Tab 把当前条加入 / 移出“已选”，可换关键词继续挑，↩ 一次粘贴全部已选；
///   “原文 + 脚注”格式把出处做成 Word / Pages 的真脚注（剪贴板里放 RTF，另附纯文本备用）。
@MainActor
final class CitationLookupController: NSObject, NSSearchFieldDelegate {
    static let shared = CitationLookupController()

    private var panel: QuickCapturePanel?
    private let field = NSSearchField()
    let model = LookupModel()

    enum Format: String, CaseIterable, Identifiable {
        case quoteThenCitation, quoteWithDash, footnote, textOnly, citationOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quoteThenCitation: return "“原文”（出处）"
            case .quoteWithDash: return "原文 + 换行——出处"
            case .footnote: return "“原文” + 脚注（Word、Pages）"
            case .textOnly: return "只要原文"
            case .citationOnly: return "只要出处"
            }
        }
        static let key = "lookup.format"
        static var current: Format {
            get { Format(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .quoteThenCitation }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    // MARK: 显示 / 关闭

    func show() {
        let p = panel ?? makePanel()
        panel = p
        model.message = nil
        model.picked = []
        field.stringValue = ""
        search("")
        if !p.isVisible { p.center() }
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(field)
    }

    func close() { panel?.orderOut(nil) }

    // MARK: 搜索

    func search(_ q: String) {
        guard let store = QuickCaptureController.shared.store else { return }
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = HighlightQuery(text: text)
        let hs = (try? store.db.highlights(query, limit: 40)) ?? []
        model.results = hs
        model.terms = SearchTerms.terms(text)
        model.selected = hs.isEmpty ? nil : 0
    }

    /// 1.1：输入时防抖 150 毫秒再查库，打字快时不卡
    private var pendingSearch: Task<Void, Never>?

    /// 输入后 150 毫秒内就按了 ↩ 或 Tab：立刻按当前文字搜索，免得用到上一次的结果
    private func flushPendingSearch() {
        guard let p = pendingSearch else { return }
        p.cancel()
        pendingSearch = nil
        search(field.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        pendingSearch?.cancel()
        let q = field.stringValue
        pendingSearch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingSearch = nil
            self?.search(q)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            model.move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            model.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            var format = Format.current
            if flags.contains(.option) { format = .citationOnly }
            if flags.contains(.shift) { format = .textOnly }
            choose(format: format, paste: !flags.contains(.command))
            return true
        case #selector(NSResponder.insertTab(_:)):
            flushPendingSearch()
            model.togglePick(); return true
        case #selector(NSResponder.insertBacktab(_:)):
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }

    // MARK: 选定

    func choose(index: Int? = nil, format: Format = Format.current, paste: Bool = true) {
        guard let store = QuickCaptureController.shared.store else { return }
        flushPendingSearch()
        // 有“已选”时粘贴全部已选（按挑选顺序）；否则粘贴当前这一条
        let items: [Highlight]
        if !model.picked.isEmpty, index == nil {
            items = model.picked
        } else {
            let i = index ?? model.selected ?? 0
            guard model.results.indices.contains(i) else { NSSound.beep(); return }
            items = [model.results[i]]
        }
        let pairs = items.map { ($0, store.source(for: $0)) }
        Self.write(pairs, format: format, to: .general)
        AppLog.write("引文速查：复制了 \(items.count) 条摘录（\(format.rawValue)）")

        if paste && AXIsProcessTrusted() {
            close()
            // 等浮窗收起、焦点回到原应用后再模拟 ⌘V
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                Self.postCommandV()
            }
        } else {
            let n = items.count > 1 ? "\(items.count) 条" : ""
            model.message = paste ? "已复制\(n)。按 ⌘V 粘贴（在“设置 → 快速录入”开启辅助功能权限后可自动粘贴）。" : "已复制\(n)到剪贴板。"
            let delay: UInt64 = paste ? 1_600_000_000 : 800_000_000
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.close()
            }
        }
    }

    /// 写进剪贴板：纯文本一律有；脚注格式另放 RTF（真脚注），其余格式另放 RTF 以便 Word 用正文字体
    static func write(_ items: [(Highlight, Source?)], format: Format, to pb: NSPasteboard) {
        let plain = items.map { compose($0.0, source: $0.1, format: format) }
            .joined(separator: format == .citationOnly ? "\n" : "\n\n")
        pb.clearContents()
        if format == .footnote {
            let paragraphs: [[RTFWriter.Run]] = items.map { h, s in
                let text = Markdown.plainText(fromHTML: Markdown.richHTML(h.text))
                let cite = CitationFormatter.citation(for: h, source: s, style: CitationSettings.style)
                return cite.isEmpty ? [.text("“\(text)”")] : [.text("“\(text)”"), .footnote(cite)]
            }
            if let data = RTFWriter.document(paragraphs).data(using: .ascii) {
                pb.setData(data, forType: .rtf)
            }
        }
        pb.setString(plain, forType: .string)
    }

    static func compose(_ h: Highlight, source: Source?, format: Format) -> String {
        let plain = Markdown.plainText(fromHTML: Markdown.richHTML(h.text))
        let cite = CitationFormatter.citation(for: h, source: source, style: CitationSettings.style)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．. "))
        switch format {
        case .quoteThenCitation: return cite.isEmpty ? "“\(plain)”" : "“\(plain)”（\(cite)）"
        case .quoteWithDash: return cite.isEmpty ? plain : plain + "\n——" + cite
        case .footnote: return cite.isEmpty ? "“\(plain)”" : "“\(plain)”［\(cite)］"
        case .textOnly: return plain
        case .citationOnly: return cite.isEmpty ? (source?.title ?? "") : cite + "。"
        }
    }

    /// 模拟按下 ⌘V（需要辅助功能权限）
    nonisolated static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 请求辅助功能权限（系统会弹出设置提示）
    static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt 的值就是这个字符串
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: 界面

    private func makePanel() -> QuickCapturePanel {
        let p = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                  styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.title = "引文速查"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.close() }

        field.placeholderString = "搜索摘录：原文、译文、按语（两字以内为模糊匹配）"
        field.font = .systemFont(ofSize: 16)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(rootView: LookupResultsView(model: model, onChoose: { [weak self] i in
            self?.choose(index: i)
        }))
        host.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        content.addSubview(host)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 30),
            host.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        p.contentView = content
        p.initialFirstResponder = field
        return p
    }
}

/// 浮窗里的搜索结果与选中项
@MainActor
@Observable
final class LookupModel {
    var results: [Highlight] = []
    var selected: Int?
    var terms: [String] = []
    var message: String?
    /// 1.2：Tab 挑选的多条（按挑选顺序），换关键词后仍保留
    var picked: [Highlight] = []
    var format: CitationLookupController.Format = .current {
        didSet { CitationLookupController.Format.current = format }
    }

    func isPicked(_ h: Highlight) -> Bool { picked.contains { $0.id == h.id } }

    /// Tab：当前条加入或移出“已选”，然后移到下一条
    func togglePick() {
        guard let i = selected, results.indices.contains(i) else { return }
        let h = results[i]
        if let k = picked.firstIndex(where: { $0.id == h.id }) { picked.remove(at: k) } else { picked.append(h) }
        if i + 1 < results.count { selected = i + 1 }
    }

    func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let cur = selected ?? -1
        selected = max(0, min(results.count - 1, cur + d))
    }
}

struct LookupResultsView: View {
    @Bindable var model: LookupModel
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { i, h in
                            row(h, selected: model.selected == i)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selected = i
                                    // ⌘ 点按：加入 / 移出已选；普通点按：粘贴这一条
                                    if NSEvent.modifierFlags.contains(.command) { model.selected = i; model.togglePick(); model.selected = i }
                                    else { onChoose(i) }
                                }
                        }
                        if model.results.isEmpty {
                            Text("没有找到。换个关键词试试。")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: model.selected) {
                    if let s = model.selected { proxy.scrollTo(s) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                if let m = model.message {
                    Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                } else {
                    Picker("格式", selection: $model.format) {
                        ForEach(CitationLookupController.Format.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.picked.isEmpty {
                        Text("↩ 粘贴　Tab 多选　⌥↩ 只要出处　⇧↩ 只要原文　⌘↩ 只复制")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("已选 \(model.picked.count) 条，↩ 一起粘贴")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(ReviewPalette.accent)
                        Button("清空") { model.picked = [] }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func row(_ h: Highlight, selected: Bool) -> some View {
        let source = QuickCaptureController.shared.store?.source(for: h)
        return HStack(alignment: .top, spacing: 8) {
          if let k = model.picked.firstIndex(where: { $0.id == h.id }) {
              Text("\(k + 1)")
                  .font(.system(size: 11, weight: .bold).monospacedDigit())
                  .foregroundStyle(selected ? ReviewPalette.accent : Color.white)
                  .frame(width: 18, height: 18)
                  .background(selected ? Color.white : ReviewPalette.accent, in: Circle())
                  .padding(.top, 2)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(RichText.marked(h.text, terms: model.terms))
                .font(.system(size: 14, design: .serif))
                .lineLimit(3)
                .foregroundStyle(selected ? Color.white : Color.primary)
            Text([source.map { "《\($0.title)》" } ?? "未归类", source?.author ?? "", h.location ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(ReviewPalette.accent) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
