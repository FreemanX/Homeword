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

    /// A text field, or an editable element with a caret: a settable value and a selection, as a character range or, in WebKit
    /// editors without one (Mail's message body: an editable AXWebArea), as text markers.
    static func isTextInput(_ e: AXUIElement) -> Bool {
        let role = string(e, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            && (attr(e, kAXSelectedTextRangeAttribute) != nil || TextMarkers.selection(e) != nil)
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
    var typed = false           // `before` is what was typed since the last click (the app's text could not be read)
    var earlier = 0             // characters of `before` from earlier blocks (EarlierText)

    static let window = 600
    /// Why a read can fail where the keys typed may stand in for the text: the app draws its text itself.
    static let unreadable: Set<String> = ["no focus", "not a text field", "no caret", "unreadable", "caret out of range"]

    /// nil, with the reason, when there is nothing to predict for.
    static func read() -> (FieldSnapshot?, String) {
        let e = AX.focused()
        let (snap, reason) = read(e)
        FieldDiag.note(e, snap?.bundle, reason, earlier: snap?.earlier ?? 0)
        return (snap, reason)
    }

    private static func read(_ focused: AXUIElement?) -> (FieldSnapshot?, String) {
        guard let e = focused else { return (nil, "no focus") }
        if AX.isSecure(e) { return (nil, "secure field") }
        guard AX.isTextInput(e) else { return (nil, "not a text field") }
        guard let sel = AX.selectedRange(e) else { return readMarkers(e) }
        if sel.length != 0 { return (nil, "selection") }
        if let m = AX.attr(e, "AXTextInputMarkedRange"), CFGetTypeID(m) == AXValueGetTypeID() {   // an input method is composing
            var r = CFRange()
            if AXValueGetValue(m as! AXValue, .cfRange, &r), r.length > 0 { return (nil, "composing") }
        }
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
        guard var b = before else { return (nil, "unreadable") }
        var earlier = ""
        if b.count < window, let (caretMarker, _) = TextMarkers.selection(e) { earlier = EarlierText.prefix(e, caretMarker, b); b = earlier + b }
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
        var snap = FieldSnapshot(element: e, pid: pid, bundle: bundle, before: b, atLineEnd: a.isEmpty || a == "\n" || a == "\r",
                                 caret: caretRect, field: AX.frame(e), host: host)
        snap.earlier = earlier.count
        return (snap, "ok")
    }

    /// The same through WebKit's text markers, for editors without character ranges (Mail's message body).
    private static func readMarkers(_ e: AXUIElement) -> (FieldSnapshot?, String) {
        guard let (start, end) = TextMarkers.selection(e) else { return (nil, "no caret") }
        guard TextMarkers.length(e, start, end) == 0 else { return (nil, "selection") }
        if let v = AX.attr(e, "AXTextInputMarkedTextMarkerRange"), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() {
            let r = v as! AXTextMarkerRange
            if (TextMarkers.length(e, AXTextMarkerRangeCopyStartMarker(r), AXTextMarkerRangeCopyEndMarker(r)) ?? 0) > 0 { return (nil, "composing") }
        }
        let caret = start
        let from = TextMarkers.index(e, caret).flatMap { TextMarkers.marker(e, index: max(0, $0 - window)) }
            ?? TextMarkers.documentStart(e) ?? caret
        guard var b = TextMarkers.string(e, from, caret) else { return (nil, "unreadable") }
        b = String(b.suffix(window)).replacingOccurrences(of: "\u{00A0}", with: " ")   // editors type a trailing space as a no-break space
        var earlier = ""
        if b.count < window { earlier = EarlierText.prefix(e, caret, b); b = earlier + b }
        let next = TextMarkers.next(e, caret)
        let a = next.flatMap { TextMarkers.string(e, caret, $0) } ?? ""
        var caretRect: CGRect? = nil
        if !b.isEmpty, b.last != "\n", let prev = TextMarkers.previous(e, caret), let r = TextMarkers.bounds(e, prev, caret) {
            caretRect = CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        } else if let r = TextMarkers.bounds(e, caret, caret) {
            caretRect = r
        }
        let pid = AX.pid(e)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let host = Style.browsers.contains(bundle) ? AX.pageHost(e) : nil
        var snap = FieldSnapshot(element: e, pid: pid, bundle: bundle, before: b, atLineEnd: a.isEmpty || a == "\n" || a == "\r",
                                 caret: caretRect, field: AX.frame(e), host: host)
        snap.earlier = earlier.count
        return (snap, "ok")
    }
}

extension FieldSnapshot {
    /// Stand-in for an app whose text cannot be read: what was typed since the last click, focus or app change. The caret is
    /// assumed at the last click when it falls inside the field (or window), else the pop-up goes to the field's corner.
    /// Focused elements where typed keys are not text.
    static let notText: Set<String> = ["AXOutline", "AXList", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXButton", "AXPopUpButton",
                                       "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXMenu", "AXMenuBar", "AXMenuItem",
                                       "AXTabGroup", "AXToolbar", "AXImage", "AXLink"]

    static func fromTyped(_ text: String, click: CGPoint?, reason: String) -> FieldSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let e = AX.focused().flatMap { AX.pid($0) == pid ? $0 : nil } ?? appElement
        if notText.contains(AX.string(e, kAXRoleAttribute) ?? "") { return nil }   // keys there select or navigate (Finder's lists)
        let windowFrame = AX.attr(appElement, kAXFocusedWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? AX.frame($0 as! AXUIElement) : nil }
        let field = AX.frame(e).flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil } ?? windowFrame
        var caret: CGRect? = nil
        if let p = click, field?.contains(p) ?? true { caret = CGRect(x: p.x, y: p.y - 9, width: 1, height: 18) }
        let bundle = app.bundleIdentifier ?? ""
        FieldDiag.markTyped(bundle)
        var s = FieldSnapshot(element: e, pid: pid, bundle: bundle, before: String(text.suffix(window)), atLineEnd: true,
                              caret: caret, field: field, host: nil)
        s.typed = true
        return s
    }
}

/// Editors that make every paragraph its own field (Notion and other block editors) show only the current block's text: add the
/// paragraphs before it, through text markers, as long as they are editable too (the page around the editor is left out). Read
/// once per focused element: earlier blocks do not change while one is typed in.
enum EarlierText {
    private static let lock = NSLock()
    private static var cache: (AXUIElement, String)?

    static func prefix(_ e: AXUIElement, _ caret: AXTextMarker, _ own: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let (el, text) = cache, CFEqual(el, e) { return text }
        let text = compute(e, caret, own)
        cache = (e, text)
        return text
    }

    private static func compute(_ e: AXUIElement, _ caret: AXTextMarker, _ own: String) -> String {
        var from = caret
        var found: String? = nil
        for _ in 0..<12 {
            guard let p = TextMarkers.previousParagraphStart(e, from), !CFEqual(p, from),
                  let el = TextMarkers.element(e, p), editable(el) else { break }
            from = p
            guard let t = TextMarkers.string(e, from, caret) else { break }
            found = t
            if t.count >= FieldSnapshot.window { break }
        }
        guard let t = found?.replacingOccurrences(of: "\u{00A0}", with: " "), t.count > own.count, t.hasSuffix(own) else { return "" }
        return String(t.dropLast(own.count).suffix(FieldSnapshot.window - own.count))
    }

    private static func editable(_ el: AXUIElement) -> Bool {
        AX.attr(el, "AXEditableAncestor") != nil || AX.isTextInput(el)
    }
}

/// WebKit's text markers: opaque positions in a web area's text (AXTextMarker), used where an editor exposes no character ranges.
enum TextMarkers {
    private static func param(_ e: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(e, name as CFString, arg, &v) == .success ? v : nil
    }
    private static func asMarker(_ v: CFTypeRef?) -> AXTextMarker? {
        guard let v, CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return (v as! AXTextMarker)
    }
    private static func range(_ a: AXTextMarker, _ b: AXTextMarker) -> AXTextMarkerRange { AXTextMarkerRangeCreate(nil, a, b) }

    /// The selection's start and end (equal: a caret).
    static func selection(_ e: AXUIElement) -> (AXTextMarker, AXTextMarker)? {
        guard let v = AX.attr(e, "AXSelectedTextMarkerRange"), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        let r = v as! AXTextMarkerRange
        return (AXTextMarkerRangeCopyStartMarker(r), AXTextMarkerRangeCopyEndMarker(r))
    }
    static func documentStart(_ e: AXUIElement) -> AXTextMarker? { asMarker(AX.attr(e, "AXStartTextMarker")) }
    static func index(_ e: AXUIElement, _ m: AXTextMarker) -> Int? { param(e, "AXIndexForTextMarker", m) as? Int }
    static func marker(_ e: AXUIElement, index: Int) -> AXTextMarker? { asMarker(param(e, "AXTextMarkerForIndex", index as CFNumber)) }
    static func next(_ e: AXUIElement, _ m: AXTextMarker) -> AXTextMarker? { asMarker(param(e, "AXNextTextMarkerForTextMarker", m)) }
    static func previous(_ e: AXUIElement, _ m: AXTextMarker) -> AXTextMarker? { asMarker(param(e, "AXPreviousTextMarkerForTextMarker", m)) }
    static func previousParagraphStart(_ e: AXUIElement, _ m: AXTextMarker) -> AXTextMarker? {
        asMarker(param(e, "AXPreviousParagraphStartTextMarkerForTextMarker", m))
    }
    /// The element holding the text at a marker.
    static func element(_ e: AXUIElement, _ m: AXTextMarker) -> AXUIElement? {
        guard let v = param(e, "AXUIElementForTextMarker", m), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func length(_ e: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> Int? { param(e, "AXLengthForTextMarkerRange", range(a, b)) as? Int }
    static func string(_ e: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> String? {
        param(e, "AXStringForTextMarkerRange", range(a, b)) as? String
    }
    /// Screen rectangle of the text between two markers (AX coordinates), nil when the editor gives none.
    static func bounds(_ e: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> CGRect? {
        guard let v = param(e, "AXBoundsForTextMarkerRange", range(a, b)), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero else { return nil }
        return rect
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
        var rect: CGRect? = nil
        var text = AX.string(e, kAXSelectedTextAttribute)
        if text == nil, let (a, b) = TextMarkers.selection(e) {           // WebKit editors without AXSelectedText (Mail)
            text = TextMarkers.string(e, a, b)?.replacingOccurrences(of: "\u{00A0}", with: " ")
            rect = TextMarkers.bounds(e, a, b)
        }
        guard let text, !text.isEmpty else { return nil }
        if rect == nil, let r = AX.selectedRange(e) { rect = AX.bounds(e, range: r) }
        return SelectionSnapshot(element: e, pid: pid, bundle: bundle, text: text, rect: rect ?? AX.frame(e))
    }
}

/// Troubleshooting "no suggestions in this app": per app, the outcome of the last field read and the shape of the focused element
/// (role, subrole, attribute names, whether its value is settable). Names only, never text or values. Written to fields.json next
/// to the metrics whenever an app's outcome changes.
enum FieldDiag {
    private static let lock = NSLock()
    private static var entries: [String: [String: Any]] = [:]       // bundle -> entry
    private static var lastKey: [String: String] = [:]              // bundle -> role + outcome, to write only on a change

    static func note(_ e: AXUIElement?, _ bundle: String?, _ outcome: String, earlier: Int = 0) {
        let pid = e.map(AX.pid) ?? 0
        let app = bundle ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        let role = e.flatMap { AX.string($0, kAXRoleAttribute) } ?? ""
        lock.lock(); defer { lock.unlock() }
        let key = role + "|" + outcome + (earlier > 0 ? "|earlier" : "")
        guard lastKey[app] != key else { return }
        lastKey[app] = key
        var entry: [String: Any] = ["outcome": outcome, "role": role, "t": ISO8601DateFormatter().string(from: Date())]
        if earlier > 0 { entry["earlierBlocksChars"] = earlier }        // a count, not the text
        if let e {
            entry["subrole"] = AX.string(e, kAXSubroleAttribute) ?? ""
            var names: CFArray?
            if AXUIElementCopyAttributeNames(e, &names) == .success { entry["attributes"] = (names as? [String] ?? []).sorted() }
            if AXUIElementCopyParameterizedAttributeNames(e, &names) == .success { entry["parameterized"] = (names as? [String] ?? []).sorted() }
            var settable: DarwinBoolean = false
            entry["valueSettable"] = AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            if let parent = AX.attr(e, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                entry["parentRole"] = AX.string(parent as! AXUIElement, kAXRoleAttribute) ?? ""
            }
        }
        entries[app] = entry
        save()
    }

    /// The app's text could not be read and the keys typed stood in for it.
    static func markTyped(_ app: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries[app] != nil, entries[app]?["fallback"] == nil else { return }
        entries[app]?["fallback"] = "typed keys"
        save()
    }

    private static func save() {
        let url = Metrics.shared.url.deletingLastPathComponent().appendingPathComponent("fields.json")
        try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
