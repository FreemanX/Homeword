// Shortcuts for proofreading and rewriting: a key code plus modifiers, matched exactly by the key tap, recorded in Settings.
import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Hotkey: Equatable {
    var code: Int          // virtual key code; -1 = no shortcut
    var mods: UInt64       // CGEventFlags bits of ⌘ ⌃ ⌥ ⇧

    static let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    static let defaultProofread = Hotkey(code: kVK_ANSI_P, mods: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
    static let defaultRewrite = Hotkey(code: kVK_ANSI_R, mods: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
    static let none = Hotkey(code: -1, mods: 0)

    var dict: [String: Any] { ["code": code, "mods": mods] }
    init(code: Int, mods: UInt64) { self.code = code; self.mods = mods }
    init(_ d: Any?) {
        let d = d as? [String: Any] ?? [:]
        code = d["code"] as? Int ?? -1
        mods = (d["mods"] as? NSNumber)?.uint64Value ?? 0
    }
    static func load(_ key: String) -> Hotkey { Hotkey(Pref.d.dictionary(forKey: key)) }
    func save(_ key: String) { Pref.d.set(dict, forKey: key) }

    var isSet: Bool { code >= 0 }
    var flags: CGEventFlags { CGEventFlags(rawValue: mods) }

    func matches(_ k: KeyPress) -> Bool {
        isSet && Int(k.code) == code && k.flags.intersection(Hotkey.relevant) == flags.intersection(Hotkey.relevant)
    }

    /// "⌃⌥P"
    var display: String {
        guard isSet else { return "None" }
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + Hotkey.keyName(code)
    }

    /// For a menu item: the key as a character and the modifier mask (empty when the key has no character).
    var menuEquivalent: (String, NSEvent.ModifierFlags) {
        guard isSet else { return ("", []) }
        let name = Hotkey.keyName(code).lowercased()
        var m: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return name.count == 1 ? (name, m) : ("", [])
    }

    /// Why this combination is a poor choice, if it is.
    func warning(other: Hotkey) -> String? {
        guard isSet else { return nil }
        if self == other { return "Same as the other shortcut." }
        let m = flags.intersection(Hotkey.relevant)
        if m == .maskCommand || m == [.maskCommand, .maskShift] { return "Apps use ⌘ shortcuts like this one; it may clash." }
        return nil
    }

    static let special: [Int: String] = [kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖",
        kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]

    /// The key's label on the current keyboard layout.
    static func keyName(_ code: Int) -> String {
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }

    /// While a recorder listens, the key tap lets every key through (and the hotkeys do nothing).
    static var recording = false
}

/// A button that shows a shortcut; click it and press the new combination. Esc cancels, Delete clears.
final class HotkeyRecorderModel: ObservableObject {
    @Published var hotkey: Hotkey
    @Published var listening = false
    let key: String
    private var monitor: Any?

    init(key: String) { self.key = key; hotkey = Hotkey.load(key) }

    func toggle() { listening ? stop() : start() }

    private func start() {
        listening = true
        Hotkey.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let code = Int(e.keyCode)
            let m = e.modifierFlags.intersection([.command, .control, .option, .shift])
            if code == kVK_Escape && m.isEmpty { self.stop(); return nil }
            if (code == kVK_Delete || code == kVK_ForwardDelete) && m.isEmpty { self.set(.none); return nil }
            guard !m.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return nil }   // needs ⌘, ⌃ or ⌥
            var f: CGEventFlags = []
            if m.contains(.command) { f.insert(.maskCommand) }
            if m.contains(.control) { f.insert(.maskControl) }
            if m.contains(.option) { f.insert(.maskAlternate) }
            if m.contains(.shift) { f.insert(.maskShift) }
            self.set(Hotkey(code: code, mods: f.rawValue))
            return nil
        }
    }

    private func set(_ h: Hotkey) {
        hotkey = h
        h.save(key)
        stop()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        Hotkey.recording = false
    }

    func reset(to h: Hotkey) { hotkey = h; h.save(key) }
}

struct HotkeyRecorder: View {
    @ObservedObject var model: HotkeyRecorderModel

    var body: some View {
        Button(action: model.toggle) {
            Text(model.listening ? "Type a shortcut…" : model.hotkey.display)
                .frame(minWidth: 120)
                .foregroundStyle(model.listening ? Color.accentColor : (model.hotkey.isSet ? Color.primary : Color.secondary))
        }
        .help("Click, then press a key combination with ⌘, ⌃ or ⌥. Esc cancels, Delete removes the shortcut.")
        .onDisappear { model.stop() }
    }
}
