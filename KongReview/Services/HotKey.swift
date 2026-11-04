import AppKit
import Carbon.HIToolbox

/// 全局快捷键预设。用 Carbon 的 RegisterEventHotKey，不需要“辅助功能”权限。
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case ctrlOptK, ctrlOptG, ctrlOptSpace, optCmdK, ctrlOptL, ctrlOptJ, optCmdL, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ctrlOptK: return "⌃⌥K"
        case .ctrlOptG: return "⌃⌥G"
        case .ctrlOptSpace: return "⌃⌥空格"
        case .optCmdK: return "⌥⌘K"
        case .ctrlOptL: return "⌃⌥L"
        case .ctrlOptJ: return "⌃⌥J"
        case .optCmdL: return "⌥⌘L"
        case .off: return "不使用"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .ctrlOptK, .optCmdK: return UInt32(kVK_ANSI_K)
        case .ctrlOptG: return UInt32(kVK_ANSI_G)
        case .ctrlOptSpace: return UInt32(kVK_Space)
        case .ctrlOptL, .optCmdL: return UInt32(kVK_ANSI_L)
        case .ctrlOptJ: return UInt32(kVK_ANSI_J)
        case .off: return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .ctrlOptK, .ctrlOptG, .ctrlOptSpace, .ctrlOptL, .ctrlOptJ: return UInt32(controlKey | optionKey)
        case .optCmdK, .optCmdL: return UInt32(optionKey | cmdKey)
        case .off: return 0
        }
    }

    static let defaultsKey = "hotkey.preset"

    static var current: HotKeyPreset {
        get { HotKeyPreset(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ctrlOptK }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 引文速查浮窗的快捷键（默认 ⌃⌥L）
    static let lookupKey = "hotkey.lookup"
    static var lookup: HotKeyPreset {
        get { HotKeyPreset(rawValue: UserDefaults.standard.string(forKey: lookupKey) ?? "") ?? .ctrlOptL }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lookupKey) }
    }

    /// 6.2：随手札记浮窗的快捷键（默认 ⌃⌥J）
    static let noteKey = "hotkey.note"
    static var note: HotKeyPreset {
        get { HotKeyPreset(rawValue: UserDefaults.standard.string(forKey: noteKey) ?? "") ?? .ctrlOptJ }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: noteKey) }
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 快速录入（id 1）
    var action: (() -> Void)?
    /// 引文速查（id 2）
    var lookupAction: (() -> Void)?
    /// 6.2：随手札记（id 3）
    var noteAction: (() -> Void)?
    private(set) var noteRegistrationFailed = false
    /// 最近一次注册是否成功（快捷键被其他应用占用时为 false）
    private(set) var lastRegistrationFailed = false
    private(set) var lookupRegistrationFailed = false

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func apply(_ preset: HotKeyPreset) {
        lastRegistrationFailed = !register(preset, id: 1)
    }

    /// 6.2：随手札记；与快速录入用了同一组键时不注册（算作占用）
    func applyNote(_ preset: HotKeyPreset) {
        if preset != .off, preset == HotKeyPreset.current {
            if let old = refs[3] { UnregisterEventHotKey(old); refs[3] = nil }
            noteRegistrationFailed = true
            return
        }
        noteRegistrationFailed = !register(preset, id: 3)
    }

    func unregister() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
    }

    /// 注册一个快捷键；preset 为“不使用”时只注销。返回是否成功
    private func register(_ preset: HotKeyPreset, id: UInt32) -> Bool {
        if let old = refs[id] { UnregisterEventHotKey(old); refs[id] = nil }
        guard let keyCode = preset.keyCode else { return true }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B47_4C4E), id: id) // "KGLN"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        switch id {
        case 2: lookupAction?()
        case 3: noteAction?()
        default: action?()
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &ref)
        handlerRef = ref
    }
}
