import AppKit
import SwiftUI
import KongReviewCore

/// 快速录入浮窗。
/// - 全局快捷键（默认 ⌃⌥K）、菜单栏图标或 kongreview://add、kongreview://quick 链接都会打开它。
/// - 用 AppKit 写成，以“非激活面板”方式出现（类似 Spotlight）：不把主窗口带到前台，
///   保存或取消后焦点自动回到原来的应用。
/// - 剪贴板里有新内容时自动填入正文并全选，直接打字即可替换。
/// - 出处默认沿用上一次，适合连续摘录同一本书。
@MainActor
final class QuickCaptureController: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    static let shared = QuickCaptureController()

    weak var store: LibraryStore?

    private var panel: QuickCapturePanel?
    /// 系统配置好的可滚动文本视图（自动换行、随宽度伸缩）
    /// 正文与按语均使用统一文字／HTML 双模式编辑器。
    private let editorModel = QuickCaptureText()
    private let editorHandle = RichEditorHandle()
    private var editorHost: NSView?
    private let sourceField = NSComboBox()
    private let authorField = NSTextField()
    private let locationField = NSTextField()
    private let tagsField = NSTextField()
    private let noteModel = QuickCaptureText()
    private let noteHandle = RichEditorHandle()
    private let statusLabel = NSTextField(labelWithString: "")

    private var pendingURL: String?
    /// 显示时是否全选正文（剪贴板自动填入时全选，直接打字即替换）
    private var selectAllOnShow = false
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
        // 等新内容送进编辑器（SwiftUI 下一次刷新）后再设焦点、全选
        let selectAll = selectAllOnShow
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.editorHandle.focus(selectAll: selectAll)
        }
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
            editorModel.text = p.text
            sourceField.stringValue = p.title ?? p.url ?? ""
            authorField.stringValue = p.author ?? ""
            locationField.stringValue = p.location ?? ""
            tagsField.stringValue = TagParser.format(p.tags)
            noteModel.text = p.note ?? ""
            pendingURL = p.url
            lastChangeCount = NSPasteboard.general.changeCount
            selectAllOnShow = false
            return
        }

        pendingURL = nil
        sourceField.stringValue = defaults.string(forKey: Self.lastSourceKey) ?? ""
        authorField.stringValue = defaults.string(forKey: Self.lastAuthorKey) ?? ""
        locationField.stringValue = ""
        tagsField.stringValue = ""
        noteModel.text = ""
        editorModel.text = ""
        selectAllOnShow = false

        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount,
           let clip = (pb.string(forType: .string) ?? pb.string(forType: .html))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty, clip.count <= 20_000 {
            editorModel.text = clip
            selectAllOnShow = true
        }
        lastChangeCount = pb.changeCount
    }

    // MARK: 保存

    @objc private func save() {
        // ⌘↩ 可能同时由编辑器和“保存”按钮触发：浮窗已收起就不再保存
        guard panel?.isVisible == true else { return }
        let text = editorModel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HTMLSourceCodec.hasContent(text) else {
            NSSound.beep()
            return
        }
        guard let store else { return }

        let title = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = authorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var draft = HighlightDraft(highlight: Highlight(
            text: text,
            note: noteModel.text.nilIfBlank,
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

    // MARK: Tab 切换栏目：最后一栏（按语）按 Tab 回到正文，第一栏（出处）按 ⇧Tab 回到正文

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertTab(_:)), control === tagsField {
            noteHandle.focus()
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)), control === sourceField {
            editorHandle.focus()
            return true
        }
        return false
    }

    // MARK: 界面

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
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

        // 正文：文字／HTML 双模式编辑器
        let editorView = QuickCaptureEditor(
            model: editorModel, handle: editorHandle,
            onSubmit: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.close() },
            onTab: { [weak self] back in
                guard let self, let panel = self.panel else { return }
                if back { self.noteHandle.focus() } else { panel.makeFirstResponder(self.sourceField) }
            })
        let host: NSView
        if let store {
            let h = NSHostingView(rootView: editorView.environment(store))
            h.sizingOptions = []   // 尺寸由下面的约束决定
            host = h
        } else {
            host = NSView()
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        host.heightAnchor.constraint(equalToConstant: 170).isActive = true
        host.wantsLayer = true
        host.layer?.cornerRadius = 8
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.separatorColor.cgColor
        host.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        editorHost = host

        // 字段
        sourceField.placeholderString = "书名或篇名，可留空（默认沿用上一次）"
        sourceField.completes = true
        sourceField.numberOfVisibleItems = 12
        authorField.placeholderString = "可留空"
        locationField.placeholderString = "页码、卷次、章节"
        tagsField.placeholderString = "用逗号或空格分隔"
        let noteEditor = RichEditor(text: Bindable(noteModel).text,
            placeholder: "个人按语，可留空", minHeight: 75, slot: "quick-note",
            onSubmit: { [weak self] in self?.save() }, onCancel: { [weak self] in self?.close() },
            onTab: { [weak self] back in
                guard let self else { return }
                if back { self.panel?.makeFirstResponder(self.tagsField) } else { self.editorHandle.focus() }
            }, handle: noteHandle)
        let noteView = NSHostingView(rootView: Group {
            if let store { noteEditor.environment(store) } else { noteEditor }
        })
        noteView.sizingOptions = []
        noteView.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let grid = NSGridView(views: [
            [label("出处"), sourceField],
            [label("作者"), authorField],
            [label("位置"), locationField],
            [label("标签"), tagsField],
            [label("按语"), noteView],
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

        let stack = NSStackView(views: [host, grid, buttons])
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
            host.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = content

        // Tab 顺序
        sourceField.delegate = self
        tagsField.delegate = self
        sourceField.nextKeyView = authorField
        authorField.nextKeyView = locationField
        locationField.nextKeyView = tagsField
        tagsField.nextKeyView = noteView
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

// MARK: - 1.2：带格式粘贴

/// 剪贴板 → Markdown：有 HTML（网页、Word、Pages）时保留标题、粗体、斜体、列表、链接等格式；
/// 只有 RTF 时先转成 HTML；都没有就用纯文本。
enum RichClipboard {
    @MainActor
    static func markdown(_ pb: NSPasteboard = .general) -> String? {
        if let html = pb.string(forType: .html), !html.isEmpty {
            let md = Markdown.markdown(fromClipboardHTML: html)
            if !md.isEmpty { return md }
        }
        if pb.string(forType: .string) == nil,
           let rtf = pb.data(forType: .rtf),
           let attr = NSAttributedString(rtf: rtf, documentAttributes: nil),
           let data = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
           let html = String(data: data, encoding: .utf8) {
            let md = Markdown.markdown(fromClipboardHTML: html)
            if !md.isEmpty { return md }
        }
        return pb.string(forType: .string)
    }

    /// 剪贴板里是否有带格式的内容
    @MainActor
    static func hasFormatting(_ pb: NSPasteboard = .general) -> Bool {
        pb.availableType(from: [.html, .rtf]) != nil
    }
}

/// 纯文本框，但粘贴时保留格式（转成 Markdown）；⌥⇧⌘V 仍粘贴纯文本
final class MarkdownPasteTextView: NSTextView {
    override func paste(_ sender: Any?) {
        if RichClipboard.hasFormatting(), let md = RichClipboard.markdown() {
            insertText(md, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }
}

// MARK: - 1.3：快速录入的正文编辑器

@MainActor
@Observable
final class QuickCaptureText {
    var text = ""
}

struct QuickCaptureEditor: View {
    let model: QuickCaptureText
    let handle: RichEditorHandle
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onTab: (Bool) -> Void

    var body: some View {
        RichEditor(text: Bindable(model).text, font: .highlight, placeholder: "摘录原文",
                   toolbar: true, minHeight: 135, slot: "quick-capture",
                   onSubmit: onSubmit, onCancel: onCancel, onTab: onTab, handle: handle)
    }
}
