// InputPredictor: a menu bar app that brings the typing ghost and proofreading to every text field, on top of the local
// services (the policy server and predictd, Apple's on-device model). No Dock icon; its only windows are Settings and Statistics.
import AppKit
import SwiftUI

@main
struct InputPredictorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let tap = KeyTap()
    private let predictor = Predictor()
    private let proofreader = Proofreader()
    private var windows: [String: NSWindow] = [:]
    private var tapRunning = false
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.register()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "InputPredictor")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        tap.onKey = { [weak self] k in self?.key(k) ?? .pass }
        tap.onMouseDown = { [weak self] in self?.predictor.mouseDown() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.predictor.appChanged(pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "")
        }
        Services.shared.onChange = { [weak self] in self?.updateIcon() }
        Services.shared.check()
        startTap(prompt: true)
    }

    func applicationWillTerminate(_ note: Notification) { Metrics.shared.flushKeys() }

    /// The keyboard tap needs the Accessibility permission; until it is granted, check again every 2 s.
    private func startTap(prompt: Bool) {
        if AX.trusted(prompt: prompt), tap.start() {
            tapRunning = true
            permissionTimer?.invalidate()
            updateIcon()
            return
        }
        updateIcon()
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.startTap(prompt: false) }
        }
    }

    private func key(_ k: KeyPress) -> TapDecision {
        // ⌃⌥P proofread, ⌃⌥R rewrite the selection
        if k.control && k.option && !k.command && proofreader.enabled {
            if k.code == 35 { proofreader.run(mode: "fix"); return .consume }
            if k.code == 15 { proofreader.run(mode: "rewrite"); return .consume }
        }
        return predictor.key(k)
    }

    private func updateIcon() {
        let ok = tapRunning && Services.shared.state != .unavailable
        status.button?.appearsDisabled = !ok || !Pref.d.bool(forKey: Pref.predictions)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let predict = NSMenuItem(title: "Predict While Typing", action: #selector(togglePredictions), keyEquivalent: "")
        predict.state = Pref.d.bool(forKey: Pref.predictions) ? .on : .off
        menu.addItem(predict)
        let proof = NSMenuItem(title: "Proofread Selection", action: #selector(proofreadSelection), keyEquivalent: "p")
        proof.keyEquivalentModifierMask = [.control, .option]
        let rewrite = NSMenuItem(title: "Rewrite Selection", action: #selector(rewriteSelection), keyEquivalent: "r")
        rewrite.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(proof)
        menu.addItem(rewrite)
        menu.addItem(.separator())
        let perm = tapRunning ? "Accessibility: granted" : "Accessibility: not granted (click to open Settings)"
        menu.addItem(NSMenuItem(title: perm, action: tapRunning ? nil : #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Services: \(Services.shared.state.rawValue)", action: Services.shared.state == .running ? nil : #selector(startServices), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Statistics…", action: #selector(showStats), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit InputPredictor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func togglePredictions() {
        Pref.d.set(!Pref.d.bool(forKey: Pref.predictions), forKey: Pref.predictions)
        updateIcon()
    }
    @objc private func proofreadSelection() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.proofreader.run(mode: "fix") } }
    @objc private func rewriteSelection() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.proofreader.run(mode: "rewrite") } }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func startServices() { Services.shared.start(force: true) }
    @objc private func showSettings() {
        show("settings", title: "InputPredictor Settings", view: SettingsView(openStats: { [weak self] in self?.showStats() }))
    }
    @objc private func showStats() { show("stats", title: "InputPredictor Statistics", view: StatsView()) }

    private func show<V: View>(_ id: String, title: String, view: V) {
        let w = windows[id] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            windows[id] = w
            return w
        }()
        if id == "stats" { w.contentViewController = NSHostingController(rootView: view) }   // fresh numbers
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: settings and statistics windows

struct SettingsView: View {
    @AppStorage(Pref.predictions) var predictions = true
    @AppStorage(Pref.proofreading) var proofreading = true
    @AppStorage(Pref.minChars) var minChars = 3
    @AppStorage(Pref.position) var position = "below"
    @AppStorage(Pref.chromium) var chromium = true
    @AppStorage(Pref.excluded) var excluded = Pref.defaultExcluded
    @AppStorage(Pref.server) var server = "http://127.0.0.1:47321"
    var openStats: () -> Void

    var body: some View {
        Form {
            Section("Input prediction") {
                Toggle("Predict while typing", isOn: $predictions)
                Picker("Pop-up position", selection: $position) {
                    Text("Below the cursor").tag("below")
                    Text("Next to the cursor").tag("beside")
                }
                Stepper("Start after \(minChars) characters", value: $minChars, in: 1...20)
                Toggle("Better support in Chrome-based browsers (turns on their accessibility mode)", isOn: $chromium)
                Text("Tab inserts the next word, Esc dismisses. Typing the suggestion's next letters keeps the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proofreading") {
                Toggle("Proofread and rewrite the selection", isOn: $proofreading)
                Text("⌃⌥P fixes typos and grammar, ⌃⌥R rewrites more clearly; both keep your meaning. Return replaces the selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never predict in these apps (bundle IDs, one per line)") {
                TextEditor(text: $excluded).font(.system(.caption, design: .monospaced)).frame(height: 110)
            }
            Section("Services") {
                TextField("Policy server", text: $server)
                HStack {
                    Button("Start services") { Services.shared.start(force: true) }
                    Button("Open Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section("Metrics (counts and timings only, never your text)") {
                HStack {
                    Button("Show statistics…", action: openStats)
                    Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([Metrics.shared.url]) }
                    Button("Reset") { Metrics.shared.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

struct StatsView: View {
    let s = MetricsSummary(Metrics.shared.load())

    var body: some View {
        Form {
            Section("Predictions") {
                row("Suggestions shown", "\(s.shown)")
                row("Accepted (at least one word)", s.shown > 0 ? "\(s.accepted) (\(pct(s.accepted, s.shown)))" : "–")
                row("Words accepted", "\(s.acceptedWords)")
                row("Characters inserted by Tab", s.keys > 0 ? "\(s.acceptedChars) (\(pct(s.acceptedChars, s.keys + s.acceptedChars)) of the text)" : "\(s.acceptedChars)")
                row("Characters typed along a suggestion", "\(s.typedAlong)")
                row("Key → pop-up, p50 / p90", ms(MetricsSummary.pct(s.latencies, 50)) + " / " + ms(MetricsSummary.pct(s.latencies, 90)))
                row("Model time, p50", ms(MetricsSummary.pct(s.models, 50)))
                row("Answers with nothing to show / errors", "\(s.empty) / \(s.errors)")
            }
            if !s.perApp.isEmpty {
                Section("By app") {
                    ForEach(s.perApp.sorted { $0.value.shown > $1.value.shown }.prefix(8), id: \.key) { app, v in
                        row(app, "\(v.shown) shown, \(pct(v.accepted, v.shown)) accepted")
                    }
                }
            }
            Section("Proofreading") {
                row("Requests", "\(s.proofreads)")
                row("Replaced / copied / cancelled / failed", "\(s.replaced) / \(s.copied) / \(s.cancelled) / \(s.failed)")
                row("Answer time, p50", ms(MetricsSummary.pct(s.proofLatencies, 50)))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).monospacedDigit().foregroundStyle(.secondary) }
    }
    private func pct(_ a: Int, _ b: Int) -> String { b > 0 ? "\(Int((Double(a) / Double(b) * 100).rounded()))%" : "–" }
    private func ms(_ x: Double?) -> String { x.map { "\(Int($0)) ms" } ?? "–" }
}
