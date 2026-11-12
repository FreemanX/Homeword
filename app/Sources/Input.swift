// Keyboard: a session event tap that sees every key press (needs the Accessibility permission), lets the app consume Tab/Esc while
// a suggestion is shown and the proofreading hotkeys, and synthetic typing to insert accepted words. Events we post ourselves carry
// a marker so the tap lets them through untouched.
import AppKit
import Carbon.HIToolbox

struct KeyPress {
    let code: Int64
    let chars: String
    let flags: CGEventFlags
    var command: Bool { flags.contains(.maskCommand) }
    var control: Bool { flags.contains(.maskControl) }
    var option: Bool { flags.contains(.maskAlternate) }
    var shift: Bool { flags.contains(.maskShift) }
    var plain: Bool { !command && !control && !option }
}

enum TapDecision { case pass, consume }

final class KeyTap {
    static let marker: Int64 = 0x1F00_7E57
    /// Called on the main thread for every key press; return .consume to swallow it.
    var onKey: ((KeyPress) -> TapDecision)?
    var onMouseDown: ((CGPoint) -> Void)?           // where, in global coordinates with the origin at the top left (as AX)
    private var tap: CFMachPort?

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyTap.marker { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown || type == .rightMouseDown {
            onMouseDown?(event.location)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        let key = KeyPress(code: event.getIntegerValueField(.keyboardEventKeycode), chars: String(utf16CodeUnits: buf, count: len), flags: event.flags)
        return onKey?(key) == .consume ? nil : Unmanaged.passUnretained(event)
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

enum Keyboard {
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = KeyTap.marker
        return s
    }()

    /// Type text into the focused app, as if typed (works in native, web and Electron text fields).
    static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    static func press(_ key: Int, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
    static func copy() { press(kVK_ANSI_C, flags: .maskCommand) }
    static func paste() { press(kVK_ANSI_V, flags: .maskCommand) }
}

/// Save and restore the general pasteboard around a copy or paste we do on the user's behalf.
enum Clipboard {
    typealias Saved = [[NSPasteboard.PasteboardType: Data]]
    static func save() -> Saved {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }
    static func restore(_ saved: Saved) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(saved.map { d in
            let item = NSPasteboardItem()
            for (t, v) in d { item.setData(v, forType: t) }
            return item
        })
    }
}
