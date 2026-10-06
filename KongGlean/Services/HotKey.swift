import AppKit
import Carbon.HIToolbox

/// 全局快捷键预设。用 Carbon 的 RegisterEventHotKey，不需要“辅助功能”权限。
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case ctrlOptK, ctrlOptG, ctrlOptSpace, optCmdK, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ctrlOptK: return "⌃⌥K"
        case .ctrlOptG: return "⌃⌥G"
        case .ctrlOptSpace: return "⌃⌥空格"
        case .optCmdK: return "⌥⌘K"
        case .off: return "不使用"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .ctrlOptK, .optCmdK: return UInt32(kVK_ANSI_K)
        case .ctrlOptG: return UInt32(kVK_ANSI_G)
        case .ctrlOptSpace: return UInt32(kVK_Space)
        case .off: return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .ctrlOptK, .ctrlOptG, .ctrlOptSpace: return UInt32(controlKey | optionKey)
        case .optCmdK: return UInt32(optionKey | cmdKey)
        case .off: return 0
        }
    }

    static let defaultsKey = "hotkey.preset"

    static var current: HotKeyPreset {
        get { HotKeyPreset(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ctrlOptK }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    /// 最近一次注册是否成功（快捷键被其他应用占用时为 false）
    private(set) var lastRegistrationFailed = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func apply(_ preset: HotKeyPreset) {
        unregister()
        lastRegistrationFailed = false
        guard let keyCode = preset.keyCode else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B47_4C4E), id: 1) // "KGLN"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            lastRegistrationFailed = true
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, &ref)
        handlerRef = ref
    }
}
