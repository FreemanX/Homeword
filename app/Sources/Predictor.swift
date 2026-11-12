// Input prediction: on every key press, read the focused field (text before the caret, caret position), ask the typing policy for
// a continuation and show it next to the caret. Same interaction as `pred try` and the agent integrations: Tab inserts the next
// word, typing the suggestion's next character keeps the rest, anything else asks again, Esc dismisses.
// Where an app's text cannot be read (it draws it itself), the keys typed since the last click stand in for it (Pref.typedFallback).
import AppKit
import Carbon.HIToolbox

final class Predictor {
    let panel = SuggestionPanel()
    private let axQueue = DispatchQueue(label: "ax", qos: .userInteractive)
    private var ghost = ""                  // the suggestion still to come
    private var ghostFor = ""               // the text before the caret it continues
    private var snap: FieldSnapshot?        // where it is shown
    private var record: SuggestionRecord?
    private var seq = 0                     // bumped on every key press: answers to older requests are dropped
    private var readSeq = 0
    private var lastKeyAt = CACurrentMediaTime()
    private var pendingKeys = 0             // key presses since the last field read, credited to that field's app
    private var warmed = ""                 // the style the engine was last asked to warm
    private var typed = ""                  // keys typed since the last click, focus or app change (memory only)
    private var typedValid = false          // something was typed since that reset
    private var lastClick: CGPoint?         // the caret is usually where the user last clicked (AX coordinates)
    /// No requests while a prompt benchmark runs (the model has one cache) or after the user stopped the engine.
    static var paused = false
    private var task: URLSessionDataTask?

    var enabled: Bool { Pref.d.bool(forKey: Pref.predictions) && !Predictor.paused && !Services.shared.stoppedByUser }

    // MARK: events (main thread)

    func key(_ k: KeyPress) -> TapDecision {
        if panel.visible && !ghost.isEmpty {
            if k.code == Int64(kVK_Tab) && k.plain && !k.shift { accept(); return .consume }
            if k.code == Int64(kVK_Escape) && k.plain { dismiss("dismissed"); return .consume }
        }
        track(k)
        guard enabled else { return .pass }
        lastKeyAt = CACurrentMediaTime()
        seq += 1
        let printable = k.plain && k.chars.count == 1 && (k.chars.unicodeScalars.first?.value ?? 0) >= 0x20 && k.code != Int64(kVK_Delete)
        if panel.visible, printable, let first = ghost.first, String(first) == k.chars {
            ghost.removeFirst()                                     // typed the suggestion's next character: keep the rest
            ghostFor += k.chars
            record?.typedAlong += 1
            if ghost.trimmingCharacters(in: .whitespaces).isEmpty { dismiss("used") } else { redraw() }
        } else if panel.visible {
            dismiss("ignored")
        }
        if printable || k.code == Int64(kVK_Delete) { pendingKeys += 1 }
        scheduleRead(after: 0.02)
        return .pass
    }

    func mouseDown(at p: CGPoint) {
        resetTyped()
        lastClick = p
        if panel.visible { dismiss("dismissed") }
    }

    func appChanged(pid: pid_t, bundle: String) {
        resetTyped()
        lastClick = nil
        if panel.visible { dismiss("dismissed") }
        let chromium = chromiumApps.contains(bundle) && Pref.d.bool(forKey: Pref.chromium)
        axQueue.async { AX.enableAccessibility(pid: pid, chromium: chromium) }
        warm(Style.resolve(bundle: bundle, host: nil))          // browsers: refined at the first field read
    }

    /// Have the engine get this style's prompt ready, so the first keystroke does not wait for it.
    private func warm(_ style: String) {
        guard enabled, style != "off", style != warmed else { return }
        warmed = style
        Services.shared.post("/warm", ["context": style], timeout: 5) { _, _ in }
    }

    // MARK: the keys typed (the stand-in for apps whose text cannot be read)

    /// Follow the text typed since the last reset. Anything that may move the caret or change text we cannot see (arrows, Return,
    /// Tab, clicks, shortcuts such as paste and undo) starts over.
    private func track(_ k: KeyPress) {
        let code = Int(k.code)
        if k.command || k.control { resetTyped(); return }
        switch code {
        case kVK_Delete:
            if k.option {                                               // a word back
                while typed.last?.isWhitespace == true { typed.removeLast() }
                while let c = typed.last, !c.isWhitespace { typed.removeLast() }
            } else if !typed.isEmpty {
                typed.removeLast()
            } else {
                typedValid = false                                      // deleting text we never saw
            }
        case kVK_ForwardDelete:
            break                                                       // after the caret: the text before it is unchanged
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
             kVK_PageUp, kVK_PageDown:
            resetTyped()
        default:
            guard let v = k.chars.unicodeScalars.first?.value, v >= 0x20, v != 0x7F, !(0xF700...0xF8FF).contains(v) else { return }
            typed += k.chars
            typedValid = true
            if typed.count > FieldSnapshot.window * 2 { typed = String(typed.suffix(FieldSnapshot.window)) }
        }
    }

    private func resetTyped() {
        typed = ""
        typedValid = false
    }

    /// A keyboard layout is active, not an input method: with an input method the keys are not the text (composition).
    private func layoutInput() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let t = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return true }
        return (Unmanaged<CFString>.fromOpaque(t).takeUnretainedValue() as String) == (kTISTypeKeyboardLayout as String)
    }

    // MARK: reading the field

    /// The focused field, or (Pref.typedFallback) the keys typed when the app's text cannot be read. `done` runs on the main thread.
    private func readField(after delay: Double = 0, _ done: @escaping (FieldSnapshot?) -> Void) {
        let fallback = typedValid && Pref.d.bool(forKey: Pref.typedFallback) && layoutInput() ? typed : nil
        let click = lastClick
        axQueue.asyncAfter(deadline: .now() + delay) {
            var (s, reason) = FieldSnapshot.read()
            if s == nil, let t = fallback, FieldSnapshot.unreadable.contains(reason) {
                s = FieldSnapshot.fromTyped(t, click: click, reason: reason)
            }
            DispatchQueue.main.async { done(s) }
        }
    }

    private func scheduleRead(after delay: Double, retries: Int = 0) {
        readSeq += 1
        let my = readSeq
        readField(after: delay) { s in
            guard my == self.readSeq else { return }                   // a newer read is coming
            self.handle(s, retries: retries)
        }
    }

    private func handle(_ s: FieldSnapshot?, retries: Int) {
        let keys = pendingKeys
        pendingKeys = 0
        let style = s.map { Style.resolve(bundle: $0.bundle, host: $0.host) } ?? "off"
        guard enabled, let s, style != "off", s.pid != getpid() else {
            if panel.visible { dismiss("dismissed") }
            return
        }
        warm(style)
        if keys > 0 { Metrics.shared.keystrokes(keys, app: s.bundle) }
        if panel.visible {
            if s.before == ghostFor { snap = s; redraw(); return }     // still following: move to the new caret
            if ghostFor.hasPrefix(s.before) && retries < 3 {           // the app has not processed the key yet
                scheduleRead(after: 0.04, retries: retries + 1)
                return
            }
            dismiss("ignored")
        }
        guard s.atLineEnd, s.before.trimmingCharacters(in: .whitespacesAndNewlines).count >= max(1, Pref.d.integer(forKey: Pref.minChars)) else { return }
        // from typed keys only after a finished word: single letters are shortcuts in apps that draw their own text (Figma, games)
        if s.typed && !s.before.contains(where: \.isWhitespace) { return }
        request(s, style: style)
    }

    // MARK: asking the policy

    private func request(_ s: FieldSnapshot, style: String, depth: Int = 0) {
        task?.cancel()
        let my = seq, t0 = lastKeyAt
        let body: [String: Any] = ["app": "notes", "context": style, "text": String(s.before.suffix(2000)), "stream": "macapp"]
        task = Services.shared.post("/predict", body, timeout: 5) { r, err in
            guard my == self.seq else { return }                        // typed on meanwhile
            let latency = (CACurrentMediaTime() - t0) * 1000
            guard let r, r["ok"] as? Bool == true else {
                let e = (r?["error"] as? String) ?? err ?? "error"
                if e != "cancelled" { Metrics.shared.log("request", ["app": s.bundle, "style": style, "outcome": "error: " + e, "latency_ms": Int(latency)]) }
                return
            }
            let sug = r["suggestion"] as? String ?? ""
            let model = (r["timing"] as? [String: Any])?["model_ms"] as? Double ?? 0
            if sug.trimmingCharacters(in: .whitespaces).isEmpty {
                let why = (r["suppressed"] as? String).map { "suppressed: " + $0 } ?? "empty"
                Metrics.shared.log("request", ["app": s.bundle, "style": style, "outcome": why, "latency_ms": Int(latency)])
                return
            }
            self.readField { now in                                     // is the field still showing this text?
                guard my == self.seq, let now, now.atLineEnd else { return }
                if now.before == s.before {
                    self.show(sug, now, style: style, latency: (CACurrentMediaTime() - t0) * 1000, model: model)
                } else if depth < 2 {
                    self.request(now, style: style, depth: depth + 1)       // the read raced the key: ask for the real text
                }
            }
        }
    }

    private func show(_ suggestion: String, _ s: FieldSnapshot, style: String, latency: Double, model: Double) {
        record?.finish("replaced")
        ghost = suggestion
        ghostFor = s.before
        snap = s
        record = SuggestionRecord(app: s.bundle, style: style, latency: latency, model: model, suggestion: suggestion,
                                  source: s.typed ? "typed" : "field")
        redraw()
    }

    private func redraw() {
        guard let s = snap else { return }
        // the next word as it reads after Tab: an unfinished word is shown completed
        let partial = ghost.first.map { !$0.isWhitespace } == true ? trailingWord(ghostFor) : ""
        let trimmed = ghost.drop(while: \.isWhitespace)
        let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        panel.show(word: partial + trimmed[..<end], rest: trimmed[end...].trimmingCharacters(in: .whitespaces),
                   caret: s.caret, field: s.field, beside: Pref.d.string(forKey: Pref.position) == "beside")
    }

    // MARK: accepting

    private func accept() {
        let piece = firstWord(ghost)                                    // " the", or "ing" of an unfinished word
        guard !piece.isEmpty else { return }
        seq += 1
        lastKeyAt = CACurrentMediaTime()
        // and a space to type on, unless the suggestion goes on with something else (", then": the comma comes next)
        let rest = ghost.dropFirst(piece.count)
        let insert = Pref.d.bool(forKey: Pref.spaceAfterWord) && (rest.isEmpty || rest.first == " ") ? piece + " " : piece
        Keyboard.type(insert)
        ghost.removeFirst(min(insert.count, ghost.count))               // the suggestion's own space is the one just typed
        ghostFor += insert
        if typedValid { typed += insert }                               // our own key events do not reach track()
        record?.acceptedWords += 1
        record?.acceptedChars += piece.count
        if ghost.trimmingCharacters(in: .whitespaces).isEmpty { dismiss("used") } else { redraw() }
        scheduleRead(after: 0.06)                                       // move along, or ask what comes next
    }

    private func dismiss(_ how: String) {
        record?.finish(how)
        record = nil
        ghost = ""
        panel.hide()
    }

    private func firstWord(_ g: String) -> String {
        let lead = g.prefix(while: \.isWhitespace)
        return String(lead + g.dropFirst(lead.count).prefix(while: { !$0.isWhitespace }))
    }

    private func trailingWord(_ t: String) -> String {
        String(t.reversed().prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }).reversed())
    }
}
