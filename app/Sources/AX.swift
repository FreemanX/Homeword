// Accessibility helpers: the focused text field, the text before the caret, where the caret is on screen, the selection.
// Every call has a short messaging timeout, so a hung app cannot stall us. Call them off the main thread (see Predictor).
import AppKit
import ApplicationServices

enum AX {
    static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.25)
        return s
    }()

    static func trusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

    static func focused() -> AXUIElement? {
        guard let v = attr(system, kAXFocusedUIElementAttribute) else { return nil }
        let e = v as! AXUIElement
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(e, &p)
        return p
    }

    /// Password fields are never read.
    static func isSecure(_ e: AXUIElement) -> Bool {
        string(e, kAXRoleAttribute) == "AXSecureTextField" || string(e, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    static func isTextInput(_ e: AXUIElement) -> Bool {
        let role = string(e, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            && attr(e, kAXSelectedTextRangeAttribute) != nil
    }

    static func selectedRange(_ e: AXUIElement) -> CFRange? {
        guard let v = attr(e, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    static func string(_ e: AXUIElement, range: CFRange) -> String? {
        var r = range
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, arg, &v) == .success else { return nil }
        return v as? String
    }

    /// Screen rectangle of a text range, in global coordinates with the origin at the top left of the main screen (AX convention).
    static func bounds(_ e: AXUIElement, range: CFRange) -> CGRect? {
        var r = range
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let val = v else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(val as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero else { return nil }
        return rect
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// Ask Chromium and Electron apps to build their accessibility tree (they only do it for assistive apps).
    static func enableAccessibility(pid: pid_t, chromium: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromium { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// The host name of the web page a field is in (browsers): the URL of the enclosing web area. Only the host is kept, in
    /// memory, to pick a writing style. Cached for the last focused element (walking up the tree costs a few ms in Chrome).
    private static var hostCache: (AXUIElement, String?)?
    static func pageHost(_ e: AXUIElement) -> String? {
        if let (el, host) = hostCache, CFEqual(el, e) { return host }
        var cur: AXUIElement? = e, host: String? = nil
        for _ in 0..<60 {
            guard let c = cur else { break }
            if string(c, kAXRoleAttribute) == "AXWebArea" {
                if let u = attr(c, "AXURL"), CFGetTypeID(u) == CFURLGetTypeID() { host = (u as! CFURL as URL).host }
                break
            }
            cur = attr(c, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        hostCache = (e, host)
        return host
    }

    /// AX coordinates (top-left origin) to AppKit screen coordinates (bottom-left origin).
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

/// What the focused text field looks like right now.
struct FieldSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let bundle: String
    let before: String          // up to 600 characters before the caret
    let atLineEnd: Bool         // nothing after the caret on its line
    let caret: CGRect?          // AX coordinates
    let field: CGRect?
    let host: String?           // the web page's host, in browsers

    static let window = 600

    /// nil, with the reason, when there is nothing to predict for.
    static func read() -> (FieldSnapshot?, String) {
        guard let e = AX.focused() else { return (nil, "no focus") }
        if AX.isSecure(e) { return (nil, "secure field") }
        guard AX.isTextInput(e) else { return (nil, "not a text field") }
        guard let sel = AX.selectedRange(e) else { return (nil, "no caret") }
        if sel.length != 0 { return (nil, "selection") }
        let caret = sel.location
        let start = max(0, caret - window)
        var before = AX.string(e, range: CFRange(location: start, length: caret - start))
        var after = AX.string(e, range: CFRange(location: caret, length: 1))
        if before == nil, let v = AX.string(e, kAXValueAttribute) {   // no ranged access: slice the whole value
            let ns = v as NSString
            guard caret <= ns.length else { return (nil, "caret out of range") }
            before = ns.substring(with: NSRange(location: start, length: caret - start))
            after = caret < ns.length ? ns.substring(with: NSRange(location: caret, length: 1)) : ""
        }
        guard let b = before else { return (nil, "unreadable") }
        let a = after ?? ""
        var caretRect: CGRect? = nil
        if caret > 0, b.last != "\n", let r = AX.bounds(e, range: CFRange(location: caret - 1, length: 1)) {
            caretRect = CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        } else if let r = AX.bounds(e, range: CFRange(location: caret, length: 0)) {
            caretRect = r
        }
        let pid = AX.pid(e)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let host = Style.browsers.contains(bundle) ? AX.pageHost(e) : nil
        return (FieldSnapshot(element: e, pid: pid, bundle: bundle, before: b, atLineEnd: a.isEmpty || a == "\n" || a == "\r",
                              caret: caretRect, field: AX.frame(e), host: host), "ok")
    }
}

/// The selected text of the focused element, and where it is on screen.
struct SelectionSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let bundle: String
    let text: String
    let rect: CGRect?           // AX coordinates

    static func read() -> SelectionSnapshot? {
        guard let e = AX.focused(), !AX.isSecure(e) else { return nil }
        let pid = AX.pid(e)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard let text = AX.string(e, kAXSelectedTextAttribute), !text.isEmpty else { return nil }
        var rect: CGRect? = nil
        if let r = AX.selectedRange(e) { rect = AX.bounds(e, range: r) }
        return SelectionSnapshot(element: e, pid: pid, bundle: bundle, text: text, rect: rect ?? AX.frame(e))
    }
}
