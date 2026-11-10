// Proofreading: take the selected text (Accessibility, or a copy as a fallback), ask the proofreading policy to fix or rewrite it,
// show the changes in a panel next to the selection, and on Replace paste the result over the selection (the pasteboard is
// restored afterwards, and the app's own undo works).
import AppKit
import SwiftUI

final class ProofreadModel: ObservableObject {
    enum Phase { case working, result, failed }
    @Published var phase = Phase.working
    @Published var mode = "fix"
    @Published var original = ""
    @Published var corrected = ""
    @Published var changes: [[String: String]] = []
    @Published var message = ""
    @Published var showResult = false       // the clean result instead of the marked-up changes
    @Published var width: CGFloat = 460
    @Published var textHeight: CGFloat = 60
    @Published var seconds = 0.0
    @Published var warnings: [String] = []
    var demo = false
    var changed: Bool { corrected != original }
    var edits: Int { changes.filter { $0["op"] != "equal" }.count }
}

struct ProofreadView: View {
    @ObservedObject var model: ProofreadModel
    var replace: () -> Void, copy: () -> Void, cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.mode == "fix" ? "Proofread" : "Rewrite").font(.headline)
                if model.phase == .result {
                    Text(model.changed ? "\(model.edits) change\(model.edits == 1 ? "" : "s") · \(String(format: "%.1f", model.seconds)) s" : "no changes needed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .working { ProgressView().controlSize(.small) }
                if model.phase == .result && model.changed {
                    Picker("", selection: $model.showResult) {
                        Text("Changes").tag(false)
                        Text("Result").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            switch model.phase {
            case .working:
                Text("Asking the on-device model… (\(model.original.count) characters)").foregroundStyle(.secondary)
            case .failed:
                Text(model.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case .result:
                ScrollView {
                    Group {
                        if model.showResult { Text(model.corrected) } else { Text(diffText()) }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)                         // room for the scroll bar
                }
                .scrollIndicators(.visible)
                .frame(height: model.textHeight)
                ForEach(model.warnings, id: \.self) { w in
                    Label(w.prefix(1).uppercased() + w.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            HStack {
                if model.demo { Text("demo: Replace is off").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Copy", action: copy).keyboardShortcut("c", modifiers: .command).disabled(model.phase != .result)
                Button("Replace", action: replace).keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .result || !model.changed || model.demo)
            }
        }
        .padding(14)
        .frame(width: model.width)
    }

    /// The corrected text with what changed marked: removed words struck through in red, new words in green.
    private func diffText() -> AttributedString {
        var out = AttributedString()
        for c in model.changes {
            let a = c["a"] ?? "", b = c["b"] ?? ""
            switch c["op"] {
            case "equal": out += AttributedString(b)
            default:
                if !a.isEmpty {
                    var del = AttributedString(a)
                    del.strikethroughStyle = .single
                    del.foregroundColor = .red
                    out += del
                }
                if !b.isEmpty {
                    var ins = AttributedString(b)
                    ins.foregroundColor = .green
                    ins.font = .body.bold()
                    out += ins
                }
            }
        }
        return out
    }
}

/// A panel that can take the keyboard (Return, Esc) without activating the app, so the app being edited stays frontmost.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Proofreader {
    private let panel: KeyPanel
    private let model = ProofreadModel()
    private var selection: SelectionSnapshot?
    private var targetPid: pid_t = 0, targetBundle = ""
    private var startedAt = CACurrentMediaTime(), answeredAt = CACurrentMediaTime()
    private var task: URLSessionDataTask?
    private var anchor: CGRect?

    init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        let host = NSHostingView(rootView: ProofreadView(model: model, replace: { [weak self] in self?.replace() },
                                                         copy: { [weak self] in self?.copy() }, cancel: { [weak self] in self?.close("cancelled") }))
        host.safeAreaRegions = []                                   // no empty strip where the hidden title bar is
        panel.contentView = host
    }

    var enabled: Bool { Pref.d.bool(forKey: Pref.proofreading) }

    /// Proofread (mode "fix") or rewrite (mode "rewrite") the selection in the frontmost app.
    func run(mode: String) {
        guard enabled else { return }
        if panel.isVisible { close("cancelled") }
        startedAt = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            if let s = SelectionSnapshot.read() {
                DispatchQueue.main.async { self.begin(mode: mode, s.text, s.pid, s.bundle, s.rect, s) }
                return
            }
            // no accessible selection (some web and Electron apps): copy it, then put the pasteboard back
            DispatchQueue.main.async {
                let saved = Clipboard.save()
                let before = NSPasteboard.general.changeCount
                Keyboard.copy()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let text = NSPasteboard.general.changeCount != before ? NSPasteboard.general.string(forType: .string) : nil
                    Clipboard.restore(saved)
                    let app = NSWorkspace.shared.frontmostApplication
                    guard let text, !text.isEmpty else { NSSound.beep(); return }
                    self.begin(mode: mode, text, app?.processIdentifier ?? 0, app?.bundleIdentifier ?? "", nil, nil)
                }
            }
        }
    }

    /// For development: run on a given text, with no target app (Replace is disabled, nothing is logged).
    func demo(text: String, mode: String) {
        if panel.isVisible { close("cancelled") }
        startedAt = CACurrentMediaTime()
        model.demo = true
        begin(mode: mode, text, 0, "", nil, nil)
    }

    private func begin(mode: String, _ text: String, _ pid: pid_t, _ bundle: String, _ rect: CGRect?, _ sel: SelectionSnapshot?) {
        selection = sel
        model.showResult = false
        model.warnings = []
        model.width = text.count > 360 ? 640 : 480
        model.textHeight = 60
        anchor = rect
        targetPid = pid
        targetBundle = bundle
        model.mode = mode
        model.original = text
        model.corrected = ""
        model.changes = []
        model.phase = .working
        place(near: rect)
        task = Services.shared.post("/proofread", ["text": text, "mode": mode], timeout: 120) { [weak self] r, err in
            guard let self, self.panel.isVisible else { return }
            self.answeredAt = CACurrentMediaTime()
            guard let r, r["ok"] as? Bool == true, let out = r["text"] as? String else {
                self.model.message = (r?["error"] as? String) ?? err ?? "no answer"
                self.model.phase = .failed
                return
            }
            self.model.corrected = out
            self.model.changes = (r["changes"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
            self.model.seconds = self.answeredAt - self.startedAt
            self.model.warnings = r["warnings"] as? [String] ?? []
            self.model.textHeight = self.textHeight()
            self.model.phase = .result
            self.place(near: self.anchor)
        }
    }

    private func place(near rect: CGRect?) {
        resize()
        let size = panel.frame.size
        var origin: CGPoint
        if let rect {
            let r = AX.toCocoa(rect)
            origin = CGPoint(x: r.minX, y: r.minY - size.height - 8)
        } else {
            let m = NSEvent.mouseLocation
            origin = CGPoint(x: m.x - size.width / 2, y: m.y - size.height - 16)
        }
        if let vf = (NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main)?.visibleFrame {
            if origin.y < vf.minY, let rect { origin.y = AX.toCocoa(rect).maxY + 8 }
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Height of the longer of the two views (the changes show removed words too), capped at 60% of the screen; beyond that it scrolls.
    private func textHeight() -> CGFloat {
        let marked = model.changes.map { c in c["op"] == "equal" ? (c["b"] ?? "") : (c["a"] ?? "") + (c["b"] ?? "") }.joined()
        let text = marked.count > model.corrected.count ? marked : model.corrected
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)      // bold: inserted words are, so measure generously
        let h = (text as NSString).boundingRect(with: NSSize(width: model.width - 28 - 14, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let screen = (NSScreen.main?.visibleFrame.height ?? 800) * 0.6
        return min(max(ceil(h) + 8, 24), screen)
    }

    private func resize() {
        guard let v = panel.contentView else { return }
        let top = panel.frame.maxY
        let size = v.fittingSize
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func replace() {
        let text = model.corrected
        close("replaced")
        // back to the app being edited, then paste over its (unchanged) selection
        NSRunningApplication(processIdentifier: targetPid)?.activate()
        let saved = Clipboard.save()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Keyboard.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Clipboard.restore(saved) }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.corrected, forType: .string)
        close("copied")
    }

    private func close(_ outcome: String) {
        task?.cancel()
        panel.orderOut(nil)
        if model.demo { model.demo = false; return }
        let changed = model.changes.filter { $0["op"] != "equal" }.count
        let failed = model.phase == .failed
        Metrics.shared.log("proofread", ["app": targetBundle, "mode": model.mode, "outcome": failed ? "failed" : model.phase == .working ? "cancelled" : outcome,
                                         "latency_ms": Int((answeredAt - startedAt) * 1000), "chars_in": model.original.count,
                                         "chars_out": model.corrected.count, "edits": changed])
    }
}
