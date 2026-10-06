import AppKit
import KongGleanCore

/// 快速录入浮窗。
/// - 全局快捷键（默认 ⌃⌥K）、菜单栏图标或 kongglean://add、kongglean://quick 链接都会打开它。
/// - 用 AppKit 写成，以“非激活面板”方式出现（类似 Spotlight）：不把主窗口带到前台，
///   保存或取消后焦点自动回到原来的应用。
/// - 剪贴板里有新内容时自动填入正文并全选，直接打字即可替换。
/// - 出处默认沿用上一次，适合连续摘录同一本书。
@MainActor
final class QuickCaptureController: NSObject, NSTextViewDelegate {
    static let shared = QuickCaptureController()

    weak var store: LibraryStore?

    private var panel: QuickCapturePanel?
    /// 系统配置好的可滚动文本视图（自动换行、随宽度伸缩）
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let sourceField = NSComboBox()
    private let authorField = NSTextField()
    private let locationField = NSTextField()
    private let tagsField = NSTextField()
    private let noteField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    private var pendingURL: String?
    /// 上次打开时的剪贴板计数；-1 表示首次打开也使用剪贴板内容
    private var lastChangeCount = -1

    private static let lastSourceKey = "quick.lastSource"
    private static let lastAuthorKey = "quick.lastAuthor"

    // MARK: 显示 / 关闭

    func show(prefill: CaptureRequest? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reset(prefill: prefill)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func reset(prefill: CaptureRequest?) {
        let defaults = UserDefaults.standard
        statusLabel.stringValue = "⌘↩ 保存　Esc 取消　Tab 切换栏目"
        statusLabel.textColor = .secondaryLabelColor

        sourceField.removeAllItems()
        let titles = (store?.sources.map(\.title) ?? []).reduce(into: [String]()) { acc, t in
            if !acc.contains(t) { acc.append(t) }
        }
        sourceField.addItems(withObjectValues: titles)

        if let p = prefill {
            textView.string = p.text
            sourceField.stringValue = p.title ?? p.url ?? ""
            authorField.stringValue = p.author ?? ""
            locationField.stringValue = p.location ?? ""
            tagsField.stringValue = TagParser.format(p.tags)
            noteField.stringValue = p.note ?? ""
            pendingURL = p.url
            lastChangeCount = NSPasteboard.general.changeCount
            textView.setSelectedRange(NSRange(location: (p.text as NSString).length, length: 0))
            return
        }

        pendingURL = nil
        sourceField.stringValue = defaults.string(forKey: Self.lastSourceKey) ?? ""
        authorField.stringValue = defaults.string(forKey: Self.lastAuthorKey) ?? ""
        locationField.stringValue = ""
        tagsField.stringValue = ""
        noteField.stringValue = ""
        textView.string = ""

        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount,
           let clip = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty, clip.count <= 20_000 {
            textView.string = clip
            textView.selectAll(nil)
        }
        lastChangeCount = pb.changeCount
    }

    // MARK: 保存

    @objc private func save() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        guard let store else { return }

        let title = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = authorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var draft = HighlightDraft(highlight: Highlight(
            text: text,
            note: noteField.stringValue.nilIfBlank,
            location: locationField.stringValue.nilIfBlank
        ))
        draft.tagsText = tagsField.stringValue
        draft.newSourceTitle = title
        draft.newSourceAuthor = author
        draft.newSourceURL = pendingURL ?? ""
        draft.newSourceKind = pendingURL == nil ? .book : .web

        guard store.save(draft: draft) else {
            statusLabel.stringValue = "保存失败：\(store.errorMessage ?? "未知错误")"
            statusLabel.textColor = .systemRed
            store.errorMessage = nil
            return
        }

        // 网页来源不作为“上次出处”记忆，免得下一条书摘误归到网页
        if pendingURL == nil {
            UserDefaults.standard.set(title, forKey: Self.lastSourceKey)
            UserDefaults.standard.set(author, forKey: Self.lastAuthorKey)
        }
        close()
    }

    @objc private func cancel() {
        close()
    }

    // MARK: NSTextViewDelegate：Tab 切换栏目，Esc 关闭

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            close()
            return true
        default:
            return false
        }
    }

    // MARK: 界面

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "快速录入"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }

        // 正文
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont(name: "Songti SC", size: 16) ?? .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        // 字段
        sourceField.placeholderString = "书名或篇名，可留空（默认沿用上一次）"
        sourceField.completes = true
        sourceField.numberOfVisibleItems = 12
        authorField.placeholderString = "可留空"
        locationField.placeholderString = "页码、卷次、章节"
        tagsField.placeholderString = "用逗号或空格分隔"
        noteField.placeholderString = "个人按语，可留空"

        let grid = NSGridView(views: [
            [label("出处"), sourceField],
            [label("作者"), authorField],
            [label("位置"), locationField],
            [label("标签"), tagsField],
            [label("按语"), noteField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        // 按钮
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelColor = .controlAccentColor
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        let buttons = NSStackView(views: [statusLabel, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = content

        // Tab 顺序
        textView.nextKeyView = sourceField
        sourceField.nextKeyView = authorField
        authorField.nextKeyView = locationField
        locationField.nextKeyView = tagsField
        tagsField.nextKeyView = noteField
        noteField.nextKeyView = textView
        panel.initialFirstResponder = textView
        return panel
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }
}

/// 可以成为键盘焦点、但不激活整个应用的浮动面板
final class QuickCapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
